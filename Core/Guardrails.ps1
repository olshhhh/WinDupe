Set-StrictMode -Version Latest

function Get-WinDupeCategoriesConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $jsonPath = Join-Path $BasePath 'Data\FileCategories.json'
    if (-not (Test-Path -LiteralPath $jsonPath)) {
        throw "No se encontro el archivo de configuracion de categorias: $jsonPath"
    }

    $raw = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
}

function Get-WinDupeQuickFolders {
    [CmdletBinding()]
    param()

    $downloadsPath = $null
    try {
        $shellFoldersKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        if (Test-Path -LiteralPath $shellFoldersKey) {
            $props = Get-ItemProperty -LiteralPath $shellFoldersKey -ErrorAction SilentlyContinue
            if ($null -ne $props -and ($props.PSObject.Properties.Name -contains '{374DE290-123F-4565-9164-39C4925E467B}')) {
                $rawDownloads = $props.'{374DE290-123F-4565-9164-39C4925E467B}'
                if (-not [string]::IsNullOrWhiteSpace($rawDownloads)) {
                    $downloadsPath = [Environment]::ExpandEnvironmentVariables($rawDownloads)
                }
            }
        }
    }
    catch {
        $downloadsPath = $null
    }

    if ([string]::IsNullOrWhiteSpace($downloadsPath)) {
        $downloadsPath = Join-Path $env:USERPROFILE 'Downloads'
    }

    $documentsPath = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($documentsPath)) {
        $documentsPath = Join-Path $env:USERPROFILE 'Documents'
    }

    $picturesPath = [Environment]::GetFolderPath('MyPictures')
    if ([string]::IsNullOrWhiteSpace($picturesPath)) {
        $picturesPath = Join-Path $env:USERPROFILE 'Pictures'
    }

    $desktopPath = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktopPath)) {
        $desktopPath = Join-Path $env:USERPROFILE 'Desktop'
    }

    return [pscustomobject]@{
        Downloads = $downloadsPath
        Documents = $documentsPath
        Pictures  = $picturesPath
        Desktop   = $desktopPath
    }
}

function Get-WinDupeProtectedPrefixes {
    [CmdletBinding()]
    param()

    $candidates = New-Object System.Collections.Generic.List[string]

    $envVars = @(
        $env:SystemRoot,
        $env:windir,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramW6432,
        $env:ProgramData
    )

    foreach ($p in $envVars) {
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            $candidates.Add($p.TrimEnd('\', '/'))
        }
    }

    $specialFolders = @(
        [Environment+SpecialFolder]::Windows,
        [Environment+SpecialFolder]::System,
        [Environment+SpecialFolder]::SystemX86,
        [Environment+SpecialFolder]::ProgramFiles,
        [Environment+SpecialFolder]::ProgramFilesX86,
        [Environment+SpecialFolder]::CommonProgramFiles,
        [Environment+SpecialFolder]::CommonProgramFilesX86,
        [Environment+SpecialFolder]::CommonApplicationData
    )

    foreach ($sf in $specialFolders) {
        try {
            $resolved = [Environment]::GetFolderPath($sf)
            if (-not [string]::IsNullOrWhiteSpace($resolved)) {
                $candidates.Add($resolved.TrimEnd('\', '/'))
            }
        }
        catch {
            # Ignorar si no aplica en la arquitectura actual
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:SystemDrive)) {
        $sysDrive = $env:SystemDrive.TrimEnd('\', '/')
        $candidates.Add("$sysDrive\Windows")
        $candidates.Add("$sysDrive\Program Files")
        $candidates.Add("$sysDrive\Program Files (x86)")
        $candidates.Add("$sysDrive\ProgramData")
        $candidates.Add("$sysDrive\System Volume Information")
        $candidates.Add("$sysDrive\`$Recycle.Bin")
        $candidates.Add("$sysDrive\Recovery")
    }

    $unique = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($item)) {
            try {
                $full = [System.IO.Path]::GetFullPath($item).TrimEnd('\', '/')
                [void]$unique.Add($full)
            }
            catch {
                [void]$unique.Add($item)
            }
        }
    }

    return @($unique)
}

function Test-WinDupeScanPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string[]]$BlockedFolderNames = @('$recycle.bin', 'system volume information', 'windows', 'winsxs', 'recovery')
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{
            IsValid = $false
            NormalizedPath = ''
            Reason = 'Debes seleccionar una carpeta valida para escanear.'
        }
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    $normalized = ''
    try {
        $normalized = [System.IO.Path]::GetFullPath($expanded)
    }
    catch {
        return [pscustomobject]@{
            IsValid = $false
            NormalizedPath = $expanded
            Reason = "La ruta '$expanded' no tiene un formato valido."
        }
    }

    if (-not (Test-Path -LiteralPath $normalized -PathType Container)) {
        return [pscustomobject]@{
            IsValid = $false
            NormalizedPath = $normalized
            Reason = "La carpeta no existe o no es accesible: $normalized"
        }
    }

    $trimmedNorm = $normalized.TrimEnd('\', '/')
    $protectedPrefixes = Get-WinDupeProtectedPrefixes

    foreach ($prefix in $protectedPrefixes) {
        if ([string]::Equals($trimmedNorm, $prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            $trimmedNorm.StartsWith(($prefix + '\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                IsValid = $false
                NormalizedPath = $normalized
                Reason = "Bloqueado por seguridad (Guardrail): no esta permitido escanear carpetas del sistema o de programas ($prefix)."
            }
        }
    }

    $dirInfo = New-Object System.IO.DirectoryInfo($normalized)
    $attrs = $dirInfo.Attributes
    $isRootDrive = ($dirInfo.Parent -eq $null)

    if (-not $isRootDrive) {
        if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject]@{
                IsValid = $false
                NormalizedPath = $normalized
                Reason = 'Bloqueado por seguridad (Guardrail): no se escanean enlaces simbolicos o puntos de union directamente.'
            }
        }

        if ((($attrs -band [System.IO.FileAttributes]::Hidden) -ne 0) -or
            (($attrs -band [System.IO.FileAttributes]::System) -ne 0)) {
            return [pscustomobject]@{
                IsValid = $false
                NormalizedPath = $normalized
                Reason = 'Bloqueado por seguridad (Guardrail): prohibido escanear carpetas ocultas o marcadas como de sistema.'
            }
        }
    }

    $current = $dirInfo
    while ($null -ne $current) {
        if ($null -ne $current.Parent) {
            $segName = $current.Name.ToLowerInvariant()
            if ($BlockedFolderNames -contains $segName) {
                return [pscustomobject]@{
                    IsValid = $false
                    NormalizedPath = $normalized
                    Reason = "Bloqueado por seguridad (Guardrail): la ruta contiene la carpeta protegida '$($current.Name)'."
                }
            }
        }
        $current = $current.Parent
    }

    return [pscustomobject]@{
        IsValid = $true
        NormalizedPath = $normalized
        Reason = ''
    }
}

function Format-WinDupeBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [long]$Bytes
    )

    if ($Bytes -lt 1024) {
        return "$Bytes B"
    }
    elseif ($Bytes -lt 1048576) {
        return ('{0:N1} KB' -f ($Bytes / 1024.0))
    }
    elseif ($Bytes -lt 1073741824) {
        return ('{0:N2} MB' -f ($Bytes / 1048576.0))
    }
    else {
        return ('{0:N2} GB' -f ($Bytes / 1073741824.0))
    }
}
