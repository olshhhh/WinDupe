Set-StrictMode -Version Latest

function Initialize-WinDupeEngine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $alreadyLoaded = ([System.Management.Automation.PSTypeName]'WinDupe.Core.DuplicateScanner').Type
    if ($null -ne $alreadyLoaded) {
        return
    }

    $csPath = Join-Path $BasePath 'Core\WinDupeEngine.cs'
    if (-not (Test-Path -LiteralPath $csPath)) {
        throw "No se encontro el motor C#: $csPath"
    }

    $sourceCode = Get-Content -LiteralPath $csPath -Raw -Encoding UTF8
    Add-Type -TypeDefinition $sourceCode -Language CSharp -ReferencedAssemblies @('System.dll', 'System.Core.dll')
}

function New-WinDupeScanOptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$RootPath,

        [string]$CategoryKey = 'All',

        [long]$MinimumSizeBytes = 1
    )

    $config = Get-WinDupeCategoriesConfig -BasePath $BasePath
    $extensions = @()

    $catProp = $config.categories.PSObject.Properties[$CategoryKey]
    if ($null -ne $catProp -and $null -ne $catProp.Value.extensions) {
        $extensions = @($catProp.Value.extensions | ForEach-Object { [string]$_ })
    }

    $blockedNames = @()
    if ($null -ne $config.blockedFolderNames) {
        $blockedNames = @($config.blockedFolderNames | ForEach-Object { [string]$_ })
    }

    $pathCheck = Test-WinDupeScanPath -Path $RootPath -BlockedFolderNames $blockedNames
    if (-not $pathCheck.IsValid) {
        throw $pathCheck.Reason
    }

    $safeMinSize = if ($MinimumSizeBytes -lt 1) { [long]1 } else { [long]$MinimumSizeBytes }

    $options = New-Object WinDupe.Core.ScanOptions
    $options.RootPath = $pathCheck.NormalizedPath
    $options.AllowedExtensions = [string[]]$extensions
    $options.MinimumSizeBytes = $safeMinSize
    $options.BlockedPrefixes = [string[]](Get-WinDupeProtectedPrefixes)
    $options.BlockedFolderNames = [string[]]$blockedNames
    $options.SkipHiddenAndSystem = $true
    $options.SkipCloudPlaceholders = $true
    return $options
}

function Start-WinDupeScanAsync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$RootPath,

        [string]$CategoryKey = 'All',

        [long]$MinimumSizeBytes = 1
    )

    Initialize-WinDupeEngine -BasePath $BasePath
    $options = New-WinDupeScanOptions -BasePath $BasePath -RootPath $RootPath -CategoryKey $CategoryKey -MinimumSizeBytes $MinimumSizeBytes

    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 2)
    $pool.ApartmentState = [System.Threading.ApartmentState]::MTA
    $pool.Open()

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.RunspacePool = $pool

    $progressQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[WinDupe.Core.ScanProgressEvent]'
    $controller = New-Object WinDupe.Core.ScanController

    $csPath = Join-Path $BasePath 'Core\WinDupeEngine.cs'

    [void]$ps.AddScript({
        param($EngineCsPath, $ScanOpts, $Ctrl, $Queue)
        if ($null -eq ([System.Management.Automation.PSTypeName]'WinDupe.Core.DuplicateScanner').Type) {
            $code = Get-Content -LiteralPath $EngineCsPath -Raw -Encoding UTF8
            Add-Type -TypeDefinition $code -Language CSharp -ReferencedAssemblies @('System.dll', 'System.Core.dll')
        }
        return [WinDupe.Core.DuplicateScanner]::Scan($ScanOpts, $Ctrl, $Queue)
    }).AddArgument($csPath).AddArgument($options).AddArgument($controller).AddArgument($progressQueue)

    $asyncResult = $ps.BeginInvoke()

    return [pscustomobject]@{
        PowerShell    = $ps
        RunspacePool  = $pool
        AsyncResult   = $asyncResult
        ProgressQueue = $progressQueue
        Controller    = $controller
        Options       = $options
    }
}

function Invoke-WinDupeScanSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$RootPath,

        [string]$CategoryKey = 'All',

        [long]$MinimumSizeBytes = 1,

        [scriptblock]$OnProgress
    )

    $handle = Start-WinDupeScanAsync -BasePath $BasePath -RootPath $RootPath -CategoryKey $CategoryKey -MinimumSizeBytes $MinimumSizeBytes
    try {
        while (-not $handle.AsyncResult.IsCompleted) {
            while ($null -ne ($evt = [WinDupe.Core.DuplicateScanner]::TryDequeueProgress($handle.ProgressQueue))) {
                if ($null -ne $OnProgress) {
                    & $OnProgress $evt
                }
            }
            Start-Sleep -Milliseconds 60
        }

        while ($null -ne ($finalEvt = [WinDupe.Core.DuplicateScanner]::TryDequeueProgress($handle.ProgressQueue))) {
            if ($null -ne $OnProgress) {
                & $OnProgress $finalEvt
            }
        }

        $output = $handle.PowerShell.EndInvoke($handle.AsyncResult)
        if ($handle.PowerShell.Streams.Error.Count -gt 0) {
            throw $handle.PowerShell.Streams.Error[0].Exception
        }
        if ($output.Count -gt 0) {
            return $output[0]
        }
        return $null
    }
    finally {
        $handle.PowerShell.Dispose()
        $handle.RunspacePool.Close()
        $handle.RunspacePool.Dispose()
    }
}
