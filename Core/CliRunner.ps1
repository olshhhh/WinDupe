Set-StrictMode -Version Latest

function Invoke-WinDupeCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [string]$ScanPath = '',
        [string]$ProfileName = '',
        [string]$Filter = 'All',
        [double]$MinSizeMB = 0,
        [switch]$AsJson
    )

    $quickFolders = Get-WinDupeQuickFolders

    $targetPath = $ScanPath
    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        switch ($ProfileName.Trim().ToLowerInvariant()) {
            'downloads'  { $targetPath = $quickFolders.Downloads }
            'descargas'  { $targetPath = $quickFolders.Downloads }
            'documents'  { $targetPath = $quickFolders.Documents }
            'documentos' { $targetPath = $quickFolders.Documents }
            'pictures'   { $targetPath = $quickFolders.Pictures }
            'imagenes'   { $targetPath = $quickFolders.Pictures }
            'desktop'    { $targetPath = $quickFolders.Desktop }
            'escritorio' { $targetPath = $quickFolders.Desktop }
            default      { $targetPath = $quickFolders.Downloads }
        }
    }

    $validCategories = @('All', 'Images', 'Videos', 'Documents', 'Audio')
    $resolvedFilter = 'All'
    foreach ($cat in $validCategories) {
        if ([string]::Equals($cat, $Filter, [System.StringComparison]::OrdinalIgnoreCase)) {
            $resolvedFilter = $cat
            break
        }
    }

    $minBytes = if ($MinSizeMB -gt 0) { [long][Math]::Round($MinSizeMB * 1048576.0) } else { [long]1 }

    if (-not $AsJson) {
        Write-Host ''
        Write-Host '========================================================================' -ForegroundColor DarkCyan
        Write-Host '  WinDupe CLI - Motor de 3 Fases (Tamano -> 16 KB -> SHA-256)' -ForegroundColor Cyan
        Write-Host '========================================================================' -ForegroundColor DarkCyan
        Write-Host "  Ruta objetivo : $targetPath" -ForegroundColor Gray
        Write-Host "  Filtro        : $resolvedFilter  |  Tamano min: $(Format-WinDupeBytes -Bytes $minBytes)" -ForegroundColor Gray
        Write-Host '  Modo seguro   : Solo lectura (sin borrado automatico en CLI)' -ForegroundColor DarkGray
        Write-Host ''
    }

    $lastPhase = -1
    $result = Invoke-WinDupeScanSync -BasePath $BasePath -RootPath $targetPath -CategoryKey $resolvedFilter -MinimumSizeBytes $minBytes -OnProgress {
        param($evt)
        if ($AsJson) { return }
        if ($evt.Phase -ne $lastPhase) {
            $lastPhase = $evt.Phase
            Write-Host ("  -> [{0}] {1}" -f $evt.PhaseName, $evt.Message) -ForegroundColor Yellow
        }
    }

    if ($null -eq $result) {
        throw 'El motor de escaneo no devolvio resultados.'
    }

    if ($AsJson) {
        $payload = [ordered]@{
            rootPath                 = $result.RootPath
            filter                   = $resolvedFilter
            minimumSizeBytes         = $minBytes
            totalFilesEnumerated     = $result.TotalFilesEnumerated
            skippedSystemOrProtected = $result.SkippedSystemOrProtected
            skippedCloudPlaceholders = $result.SkippedCloudPlaceholders
            hardLinksSkipped         = $result.HardLinksSkipped
            accessErrors             = $result.AccessErrors
            phase1Candidates         = $result.Phase1Candidates
            phase2Candidates         = $result.Phase2Candidates
            duplicateGroupCount      = $result.DuplicateGroupCount
            totalDuplicateFiles      = $result.TotalDuplicateFiles
            totalReclaimableBytes    = $result.TotalReclaimableBytes
            totalReclaimableHuman    = (Format-WinDupeBytes -Bytes $result.TotalReclaimableBytes)
            elapsedMilliseconds      = $result.ElapsedMilliseconds
            groups                   = @(
                foreach ($grp in $result.Groups) {
                    [ordered]@{
                        groupId          = $grp.GroupId
                        sha256           = $grp.Sha256
                        fileSizeBytes    = $grp.FileSizeBytes
                        fileCount        = $grp.FileCount
                        reclaimableBytes = $grp.ReclaimableBytes
                        files            = @(
                            foreach ($f in $grp.Files) {
                                [ordered]@{
                                    fullPath      = $f.FullPath
                                    lastWriteTime = $f.LastWriteTime.ToString('o')
                                }
                            }
                        )
                    }
                }
            )
        }
        Write-Output ($payload | ConvertTo-Json -Depth 6)
        return
    }

    Write-Host ''
    Write-Host '------------------------ REPORTE DE RESULTADOS -------------------------' -ForegroundColor DarkCyan
    Write-Host ("  Archivos analizados     : {0:N0}" -f $result.TotalFilesEnumerated)
    Write-Host ("  Carpetas omitidas (Seg.): {0:N0}" -f $result.SkippedSystemOrProtected)
    Write-Host ("  Nube / OneDrive omitidos: {0:N0}" -f $result.SkippedCloudPlaceholders)
    Write-Host ("  Hard links NTFS omitidos: {0:N0}" -f $result.HardLinksSkipped)
    Write-Host ("  Candidatos Fase 1 (Size): {0:N0} (en {1:N0} grupos)" -f $result.Phase1Candidates, $result.Phase1SizeGroups)
    Write-Host ("  Candidatos Fase 2 (16KB): {0:N0} (en {1:N0} grupos)" -f $result.Phase2Candidates, $result.Phase2PartialGroups)
    Write-Host ("  Grupos duplicados (SHA) : {0:N0}" -f $result.DuplicateGroupCount) -ForegroundColor White
    Write-Host ("  Archivos duplicados     : {0:N0}" -f $result.TotalDuplicateFiles)
    Write-Host ("  Espacio recuperable     : {0} ({1:N0} bytes)" -f (Format-WinDupeBytes -Bytes $result.TotalReclaimableBytes), $result.TotalReclaimableBytes) -ForegroundColor Green
    Write-Host ("  Tiempo total            : {0:N2} s" -f ($result.ElapsedMilliseconds / 1000.0))
    Write-Host '------------------------------------------------------------------------' -ForegroundColor DarkCyan

    if ($result.DuplicateGroupCount -eq 0) {
        Write-Host '  No se encontraron archivos duplicados en esta ubicacion.' -ForegroundColor Green
        Write-Host ''
        return
    }

    $maxDisplay = [Math]::Min(15, $result.Groups.Count)
    Write-Host ''
    Write-Host "  Top $maxDisplay grupos con mayor espacio recuperable:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $maxDisplay; $i++) {
        $grp = $result.Groups[$i]
        $shortSha = $grp.Sha256.Substring(0, 12)
        $reclaimStr = Format-WinDupeBytes -Bytes $grp.ReclaimableBytes
        $sizeStr = Format-WinDupeBytes -Bytes $grp.FileSizeBytes
        Write-Host ''
        Write-Host ("  [Grupo #{0}] {1} copias | {2} c/u | Recuperable: {3} | SHA256:{4}" -f $grp.GroupId, $grp.FileCount, $sizeStr, $reclaimStr, $shortSha) -ForegroundColor White
        foreach ($file in $grp.Files) {
            Write-Host ("     - ({0}) {1}" -f $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $file.FullPath) -ForegroundColor Gray
        }
    }

    if ($result.Groups.Count -gt $maxDisplay) {
        Write-Host ''
        Write-Host ("  ... y {0} grupos adicionales. Ejecuta sin -Cli para gestionarlos visualmente o usa -Json." -f ($result.Groups.Count - $maxDisplay)) -ForegroundColor DarkGray
    }
    Write-Host ''
}
