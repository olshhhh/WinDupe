[CmdletBinding()]
param(
    [string]$RepoOwner = 'olshhhh',
    [string]$RepoName = 'WinDupe',
    [string]$Branch = 'main',
    [string]$BaseUrl = '',
    [switch]$Cli,
    [string]$Profile = '',
    [string]$Path = '',
    [string]$Filter = 'All',
    [double]$MinSizeMB = 0,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
}
catch {
    # En algunos entornos restringidos por GPO puede no ser modificable a nivel proceso
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Lista estrictamente sincronizada con los archivos indispensables para el runtime en Windows
$manifestFiles = @(
    'WinDupe.ps1',
    'Core/WinDupeEngine.cs',
    'Core/Guardrails.ps1',
    'Core/RecycleAudit.ps1',
    'Core/ScannerService.ps1',
    'Core/CliRunner.ps1',
    'UI/MainWindow.xaml',
    'Data/FileCategories.json'
)

$psExecutable = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($psExecutable)) {
    $psExecutable = 'powershell.exe'
}

# WinDupe esta disenado para ejecutarse SIN elevacion UAC.
# Solo garantizamos STA cuando se abre la interfaz WPF y el hilo actual no es STA.
if ((-not $Cli) -and ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA)) {
    $esc = {
        param([string]$v)
        return "'" + ($v -replace "'", "''") + "'"
    }

    $resolvedSourceUrl = if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"
    }
    else {
        $BaseUrl.TrimEnd('\', '/')
    }

    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath) -and (Test-Path -LiteralPath $PSCommandPath)) {
        $relaunchArgs = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-STA',
            '-File', $PSCommandPath,
            '-RepoOwner', $RepoOwner,
            '-RepoName', $RepoName,
            '-Branch', $Branch
        )
        if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) { $relaunchArgs += @('-BaseUrl', $BaseUrl) }
        if (-not [string]::IsNullOrWhiteSpace($Profile)) { $relaunchArgs += @('-Profile', $Profile) }
        if (-not [string]::IsNullOrWhiteSpace($Path))    { $relaunchArgs += @('-Path', $Path) }
        if (-not [string]::IsNullOrWhiteSpace($Filter))  { $relaunchArgs += @('-Filter', $Filter) }
        if ($MinSizeMB -gt 0)                             { $relaunchArgs += @('-MinSizeMB', $MinSizeMB.ToString([System.Globalization.CultureInfo]::InvariantCulture)) }
        $procSta = Start-Process -FilePath $psExecutable -ArgumentList $relaunchArgs -Wait -PassThru
        exit $procSta.ExitCode
    }
    elseif ((-not ($resolvedSourceUrl -match '^https?://')) -and (Test-Path -LiteralPath (Join-Path $resolvedSourceUrl 'bootstrap.ps1'))) {
        $localBootstrap = Join-Path $resolvedSourceUrl 'bootstrap.ps1'
        $relaunchArgs = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-STA',
            '-File', $localBootstrap,
            '-RepoOwner', $RepoOwner,
            '-RepoName', $RepoName,
            '-Branch', $Branch,
            '-BaseUrl', $resolvedSourceUrl
        )
        if (-not [string]::IsNullOrWhiteSpace($Profile)) { $relaunchArgs += @('-Profile', $Profile) }
        if (-not [string]::IsNullOrWhiteSpace($Path))    { $relaunchArgs += @('-Path', $Path) }
        if (-not [string]::IsNullOrWhiteSpace($Filter))  { $relaunchArgs += @('-Filter', $Filter) }
        if ($MinSizeMB -gt 0)                             { $relaunchArgs += @('-MinSizeMB', $MinSizeMB.ToString([System.Globalization.CultureInfo]::InvariantCulture)) }
        $procSta = Start-Process -FilePath $psExecutable -ArgumentList $relaunchArgs -Wait -PassThru
        exit $procSta.ExitCode
    }
    else {
        $minSizeArg = if ($MinSizeMB -gt 0) { "-MinSizeMB $($MinSizeMB.ToString([System.Globalization.CultureInfo]::InvariantCulture))" } else { '' }
        $relaunchScript = @"
& ([scriptblock]::Create((Invoke-RestMethod -Uri $(& $esc "$resolvedSourceUrl/bootstrap.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())")))) -RepoOwner $(& $esc $RepoOwner) -RepoName $(& $esc $RepoName) -Branch $(& $esc $Branch) -BaseUrl $(& $esc $BaseUrl) -Profile $(& $esc $Profile) -Path $(& $esc $Path) -Filter $(& $esc $Filter) $minSizeArg
"@
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($relaunchScript))
        $procSta = Start-Process -FilePath $psExecutable -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-EncodedCommand', $encoded) -Wait -PassThru
        exit $procSta.ExitCode
    }
}

$volatileRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("WinDupe_" + [guid]::NewGuid().ToString('N'))

try {
    [void](New-Item -Path $volatileRoot -ItemType Directory -Force)

    $resolvedBaseUrl = if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"
    }
    else {
        $BaseUrl.TrimEnd('\', '/')
    }

    $isLocalSource = (-not ($resolvedBaseUrl -match '^https?://')) -and (Test-Path -LiteralPath $resolvedBaseUrl -PathType Container)
    $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $webClient = $null
    if (-not $isLocalSource) {
        $webClient = New-Object System.Net.WebClient
        $webClient.Encoding = [System.Text.Encoding]::UTF8
    }

    try {
        $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

        foreach ($relPath in $manifestFiles) {
            $winRel = $relPath -replace '/', '\'
            $destPath = Join-Path $volatileRoot $winRel
            $destDir = Split-Path -Path $destPath -Parent
            if (-not (Test-Path -LiteralPath $destDir)) {
                [void](New-Item -Path $destDir -ItemType Directory -Force)
            }

            $ext = [System.IO.Path]::GetExtension($relPath).ToLowerInvariant()
            $isTextAsset = @('.ps1', '.psm1', '.json', '.xaml', '.cs', '.txt', '.md') -contains $ext

            if ($isLocalSource) {
                $localFile = Join-Path $resolvedBaseUrl $winRel
                if (-not (Test-Path -LiteralPath $localFile -PathType Leaf)) {
                    throw "Archivo del manifiesto no encontrado en ruta local: $localFile"
                }
                if ($isTextAsset) {
                    $content = [System.IO.File]::ReadAllText($localFile, [System.Text.Encoding]::UTF8)
                    $targetEnc = if ($ext -in @('.ps1', '.psm1')) { $utf8WithBom } else { $utf8NoBom }
                    [System.IO.File]::WriteAllText($destPath, $content, $targetEnc)
                }
                else {
                    Copy-Item -LiteralPath $localFile -Destination $destPath -Force
                }
            }
            else {
                $remoteUri = "$resolvedBaseUrl/$relPath`?cb=$cacheBust"
                $webClient.Headers['Cache-Control'] = 'no-cache'

                if ($isTextAsset) {
                    $content = $webClient.DownloadString($remoteUri)
                    $targetEnc = if ($ext -in @('.ps1', '.psm1')) { $utf8WithBom } else { $utf8NoBom }
                    [System.IO.File]::WriteAllText($destPath, $content, $targetEnc)
                }
                else {
                    $webClient.DownloadFile($remoteUri, $destPath)
                }
            }
        }
    }
    finally {
        if ($null -ne $webClient) {
            $webClient.Dispose()
        }
    }

    $entryScript = Join-Path $volatileRoot 'WinDupe.ps1'

    if ($Cli) {
        # En modo CLI invocamos directamente para preservar stdout/JSON en pipelines (p. ej. ConvertFrom-Json)
        $cliParams = @{
            BasePath = $volatileRoot
            Cli      = $true
        }
        if (-not [string]::IsNullOrWhiteSpace($Profile)) { $cliParams['Profile'] = $Profile }
        if (-not [string]::IsNullOrWhiteSpace($Path))    { $cliParams['Path'] = $Path }
        if (-not [string]::IsNullOrWhiteSpace($Filter))  { $cliParams['Filter'] = $Filter }
        if ($MinSizeMB -gt 0)                             { $cliParams['MinSizeMB'] = $MinSizeMB }
        if ($Json)                                        { $cliParams['Json'] = $true }
        & $entryScript @cliParams
    }
    else {
        $childArgs = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-STA',
            '-File', $entryScript,
            '-BasePath', $volatileRoot
        )
        if (-not [string]::IsNullOrWhiteSpace($Profile)) { $childArgs += @('-Profile', $Profile) }
        if (-not [string]::IsNullOrWhiteSpace($Path))    { $childArgs += @('-Path', $Path) }
        if (-not [string]::IsNullOrWhiteSpace($Filter))  { $childArgs += @('-Filter', $Filter) }
        if ($MinSizeMB -gt 0)                             { $childArgs += @('-MinSizeMB', $MinSizeMB.ToString([System.Globalization.CultureInfo]::InvariantCulture)) }

        $proc = Start-Process -FilePath $psExecutable -ArgumentList $childArgs -WindowStyle Hidden -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            exit $proc.ExitCode
        }
    }
}
catch {
    $localLogs = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WinDupe\Logs'
    try {
        if (-not (Test-Path -LiteralPath $localLogs)) {
            [void](New-Item -Path $localLogs -ItemType Directory -Force)
        }
        $errFile = Join-Path $localLogs 'last_error.log'
        $errText = "[$(Get-Date -Format 'o')] [bootstrap.ps1] $($_.Exception.Message)`r`n$($_.Exception.StackTrace)`r`n"
        [System.IO.File]::WriteAllText($errFile, $errText, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        # Ignorar fallo al escribir log de emergencia
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $volatileRoot) {
        Remove-Item -LiteralPath $volatileRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
