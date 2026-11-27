Set-StrictMode -Version Latest

function Get-WinDupeLogsDirectory {
    [CmdletBinding()]
    param()

    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = $env:LOCALAPPDATA
    }

    $logsDir = Join-Path $localAppData 'WinDupe\Logs'
    if (-not (Test-Path -LiteralPath $logsDir)) {
        [void](New-Item -Path $logsDir -ItemType Directory -Force)
    }

    return $logsDir
}

function Write-WinDupeErrorLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception,

        [string]$Context = 'General'
    )

    try {
        $logsDir = Get-WinDupeLogsDirectory
        $errorLogPath = Join-Path $logsDir 'last_error.log'

        $osVersion = 'Desconocido'
        try {
            $osCim = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($null -ne $osCim) {
                $osVersion = "$($osCim.Caption) ($($osCim.Version)) Build $($osCim.BuildNumber)"
            }
        }
        catch {
            $osVersion = [Environment]::OSVersion.VersionString
        }

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('====================================================================')
        [void]$sb.AppendLine("Timestamp   : $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffK')")
        [void]$sb.AppendLine("Context     : $Context")
        [void]$sb.AppendLine("PowerShell  : $($PSVersionTable.PSVersion)")
        [void]$sb.AppendLine("OS          : $osVersion")
        [void]$sb.AppendLine("User        : $env:USERNAME")
        [void]$sb.AppendLine("Type        : $($Exception.GetType().FullName)")
        [void]$sb.AppendLine("Message     : $($Exception.Message)")
        [void]$sb.AppendLine('StackTrace  :')
        [void]$sb.AppendLine($Exception.StackTrace)

        $inner = $Exception.InnerException
        while ($null -ne $inner) {
            [void]$sb.AppendLine('--- InnerException ---')
            [void]$sb.AppendLine("Type        : $($inner.GetType().FullName)")
            [void]$sb.AppendLine("Message     : $($inner.Message)")
            [void]$sb.AppendLine($inner.StackTrace)
            $inner = $inner.InnerException
        }
        [void]$sb.AppendLine('====================================================================')

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($errorLogPath, $sb.ToString(), $utf8NoBom)
        return $errorLogPath
    }
    catch {
        return ''
    }
}

function Write-WinDupeAuditEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [long]$SizeBytes,

        [string]$Sha256 = '',

        [Parameter(Mandatory = $true)]
        [ValidateSet('SentToRecycleBin', 'Cancelled', 'Failed', 'Blocked')]
        [string]$Action,

        [string]$ErrorMessage = ''
    )

    $logsDir = Get-WinDupeLogsDirectory
    $jsonlPath = Join-Path $logsDir 'deleted_audit.jsonl'
    $textLogPath = Join-Path $logsDir 'audit_history.log'

    $timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffK'
    $entry = [ordered]@{
        timestamp    = $timestamp
        action       = $Action
        filePath     = $FilePath
        sizeBytes    = $SizeBytes
        sha256       = $Sha256
        user         = $env:USERNAME
        errorMessage = $ErrorMessage
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $jsonLine = ($entry | ConvertTo-Json -Compress) + [Environment]::NewLine
    [System.IO.File]::AppendAllText($jsonlPath, $jsonLine, $utf8NoBom)

    $humanLine = "[$timestamp] [$Action] ($SizeBytes bytes) $FilePath"
    if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
        $shortHash = if ($Sha256.Length -ge 12) { $Sha256.Substring(0, 12) } else { $Sha256 }
        $humanLine += " [SHA256:$shortHash]"
    }
    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        $humanLine += " -> Error: $ErrorMessage"
    }
    $humanLine += [Environment]::NewLine
    [System.IO.File]::AppendAllText($textLogPath, $humanLine, $utf8NoBom)
}

function Invoke-WinDupeRecycleFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items
    )

    Add-Type -AssemblyName Microsoft.VisualBasic

    $deletedCount = 0
    $reclaimedBytes = [long]0
    $failedItems = New-Object System.Collections.Generic.List[object]
    $deletedPaths = New-Object System.Collections.Generic.List[string]
    $cancelled = $false

    foreach ($item in $Items) {
        $filePath = [string]$item.FullPath
        $sizeBytes = [long]$item.SizeBytes
        $sha256 = if ($null -ne $item.Sha256) { [string]$item.Sha256 } else { '' }

        $parentDir = Split-Path -Path $filePath -Parent
        $guardCheck = Test-WinDupeScanPath -Path $parentDir
        if (-not $guardCheck.IsValid) {
            Write-WinDupeAuditEntry -FilePath $filePath -SizeBytes $sizeBytes -Sha256 $sha256 -Action 'Blocked' -ErrorMessage $guardCheck.Reason
            $failedItems.Add([pscustomobject]@{
                FullPath = $filePath
                Reason   = $guardCheck.Reason
            })
            continue
        }

        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            $reason = 'El archivo ya no existe en disco.'
            Write-WinDupeAuditEntry -FilePath $filePath -SizeBytes $sizeBytes -Sha256 $sha256 -Action 'Failed' -ErrorMessage $reason
            $failedItems.Add([pscustomobject]@{
                FullPath = $filePath
                Reason   = $reason
            })
            continue
        }

        try {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $filePath,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException
            )

            $deletedCount++
            $reclaimedBytes += $sizeBytes
            $deletedPaths.Add($filePath)
            Write-WinDupeAuditEntry -FilePath $filePath -SizeBytes $sizeBytes -Sha256 $sha256 -Action 'SentToRecycleBin'
        }
        catch [System.OperationCanceledException] {
            Write-WinDupeAuditEntry -FilePath $filePath -SizeBytes $sizeBytes -Sha256 $sha256 -Action 'Cancelled' -ErrorMessage 'Cancelado por el usuario en el dialogo de Windows.'
            $cancelled = $true
            break
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-WinDupeAuditEntry -FilePath $filePath -SizeBytes $sizeBytes -Sha256 $sha256 -Action 'Failed' -ErrorMessage $errMsg
            $failedItems.Add([pscustomobject]@{
                FullPath = $filePath
                Reason   = $errMsg
            })
        }
    }

    return [pscustomobject]@{
        DeletedCount   = $deletedCount
        ReclaimedBytes = $reclaimedBytes
        DeletedPaths   = @($deletedPaths)
        FailedItems    = @($failedItems)
        WasCancelled   = $cancelled
        LogsDirectory  = (Get-WinDupeLogsDirectory)
    }
}
