[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BasePath,

    [switch]$Cli,

    [string]$Profile = '',

    [string]$Path = '',

    [string]$Filter = 'All',

    [double]$MinSizeMB = 0,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedBase = [System.IO.Path]::GetFullPath($BasePath)
. (Join-Path $resolvedBase 'Core\Guardrails.ps1')
. (Join-Path $resolvedBase 'Core\RecycleAudit.ps1')
. (Join-Path $resolvedBase 'Core\ScannerService.ps1')
. (Join-Path $resolvedBase 'Core\CliRunner.ps1')

function Start-WinDupeGui {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppBasePath,

        [string]$InitialProfile = '',
        [string]$InitialPath = '',
        [string]$InitialFilter = 'All',
        [double]$InitialMinSizeMB = 0
    )

    if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
        throw 'La interfaz grafica WPF requiere modo STA. Usa bootstrap.ps1 para iniciar WinDupe.'
    }

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms

    Initialize-WinDupeEngine -BasePath $AppBasePath

    $categoriesConfig = Get-WinDupeCategoriesConfig -BasePath $AppBasePath
    $previewableExts = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $categoriesConfig.previewableImageExtensions) {
        foreach ($ext in $categoriesConfig.previewableImageExtensions) {
            [void]$previewableExts.Add([string]$ext)
        }
    }

    $xamlPath = Join-Path $AppBasePath 'UI\MainWindow.xaml'
    $xamlContent = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
    $window = [System.Windows.Markup.XamlReader]::Parse($xamlContent)

    $ctrl = @{
        BtnOpenLogs             = $window.FindName('BtnOpenLogs')
        BtnDownloads            = $window.FindName('BtnDownloads')
        BtnDocuments            = $window.FindName('BtnDocuments')
        BtnPictures             = $window.FindName('BtnPictures')
        BtnBrowse               = $window.FindName('BtnBrowse')
        TxtScanPath             = $window.FindName('TxtScanPath')
        FilterAll               = $window.FindName('FilterAll')
        FilterImages            = $window.FindName('FilterImages')
        FilterVideos            = $window.FindName('FilterVideos')
        FilterDocuments         = $window.FindName('FilterDocuments')
        FilterAudio             = $window.FindName('FilterAudio')
        CmbMinSize              = $window.FindName('CmbMinSize')
        BtnScan                 = $window.FindName('BtnScan')
        TxtKpiScanned           = $window.FindName('TxtKpiScanned')
        TxtKpiFunnel            = $window.FindName('TxtKpiFunnel')
        TxtKpiGroups            = $window.FindName('TxtKpiGroups')
        TxtKpiFiles             = $window.FindName('TxtKpiFiles')
        TxtKpiSelected          = $window.FindName('TxtKpiSelected')
        TxtKpiSelectedBytes     = $window.FindName('TxtKpiSelectedBytes')
        TxtKpiReclaimable       = $window.FindName('TxtKpiReclaimable')
        TxtKpiElapsed           = $window.FindName('TxtKpiElapsed')
        TxtPhaseStatus          = $window.FindName('TxtPhaseStatus')
        TxtProgressPct          = $window.FindName('TxtProgressPct')
        ProgressScan            = $window.FindName('ProgressScan')
        BtnKeepOldest           = $window.FindName('BtnKeepOldest')
        BtnKeepNewest           = $window.FindName('BtnKeepNewest')
        BtnAutoSelect           = $window.FindName('BtnAutoSelect')
        BtnClearSelection       = $window.FindName('BtnClearSelection')
        TxtSearchFilter         = $window.FindName('TxtSearchFilter')
        TxtSearchPlaceholder    = $window.FindName('TxtSearchPlaceholder')
        BtnClearSearch          = $window.FindName('BtnClearSearch')
        BtnSendToRecycle        = $window.FindName('BtnSendToRecycle')
        TxtEmptyListHint        = $window.FindName('TxtEmptyListHint')
        LstDuplicates           = $window.FindName('LstDuplicates')
        MenuMarkFolderDuplicates= $window.FindName('MenuMarkFolderDuplicates')
        MenuKeepThis            = $window.FindName('MenuKeepThis')
        MenuOpenFolder          = $window.FindName('MenuOpenFolder')
        TxtPreviewEmpty         = $window.FindName('TxtPreviewEmpty')
        PanelPreviewContent     = $window.FindName('PanelPreviewContent')
        ImgPreview              = $window.FindName('ImgPreview')
        PanelNonImagePreview    = $window.FindName('PanelNonImagePreview')
        TxtPreviewExt           = $window.FindName('TxtPreviewExt')
        TxtInspectorName        = $window.FindName('TxtInspectorName')
        TxtInspectorPath        = $window.FindName('TxtInspectorPath')
        TxtInspectorSize        = $window.FindName('TxtInspectorSize')
        TxtInspectorAction      = $window.FindName('TxtInspectorAction')
        TxtInspectorModified    = $window.FindName('TxtInspectorModified')
        TxtInspectorCreated     = $window.FindName('TxtInspectorCreated')
        TxtInspectorHash        = $window.FindName('TxtInspectorHash')
        BtnMarkFolderDuplicates = $window.FindName('BtnMarkFolderDuplicates')
        BtnOpenLocation         = $window.FindName('BtnOpenLocation')
        BtnCopyHash             = $window.FindName('BtnCopyHash')
        TxtGuardrailNotice      = $window.FindName('TxtGuardrailNotice')
        TxtFooterAudit          = $window.FindName('TxtFooterAudit')
    }

    $quickFolders = Get-WinDupeQuickFolders
    $defaultPath = $quickFolders.Downloads
    if (-not [string]::IsNullOrWhiteSpace($InitialPath)) {
        $defaultPath = $InitialPath
    }
    elseif (-not [string]::IsNullOrWhiteSpace($InitialProfile)) {
        switch ($InitialProfile.Trim().ToLowerInvariant()) {
            'downloads'  { $defaultPath = $quickFolders.Downloads }
            'descargas'  { $defaultPath = $quickFolders.Downloads }
            'documents'  { $defaultPath = $quickFolders.Documents }
            'documentos' { $defaultPath = $quickFolders.Documents }
            'pictures'   { $defaultPath = $quickFolders.Pictures }
            'imagenes'   { $defaultPath = $quickFolders.Pictures }
            'desktop'    { $defaultPath = $quickFolders.Desktop }
            'escritorio' { $defaultPath = $quickFolders.Desktop }
        }
    }
    $ctrl.TxtScanPath.Text = $defaultPath

    switch ($InitialFilter.Trim().ToLowerInvariant()) {
        'images'    { $ctrl.FilterImages.IsChecked = $true }
        'videos'    { $ctrl.FilterVideos.IsChecked = $true }
        'documents' { $ctrl.FilterDocuments.IsChecked = $true }
        'audio'     { $ctrl.FilterAudio.IsChecked = $true }
        default     { $ctrl.FilterAll.IsChecked = $true }
    }

    if ($InitialMinSizeMB -ge 100) { $ctrl.CmbMinSize.SelectedIndex = 4 }
    elseif ($InitialMinSizeMB -ge 10) { $ctrl.CmbMinSize.SelectedIndex = 3 }
    elseif ($InitialMinSizeMB -ge 1) { $ctrl.CmbMinSize.SelectedIndex = 2 }
    elseif ($InitialMinSizeMB -gt 0) { $ctrl.CmbMinSize.SelectedIndex = 1 }

    $state = [pscustomobject]@{
        BasePath       = $AppBasePath
        IsScanning     = $false
        ScanHandle     = $null
        PollTimer      = $null
        ViewRows       = (New-Object 'System.Collections.ObjectModel.ObservableCollection[WinDupe.Core.DuplicateRowViewModel]')
        CollectionView = $null
        LastScanResult = $null
        ActiveRow      = $null
        SearchQuery    = ''
    }

    $collectionView = New-Object System.Windows.Data.ListCollectionView($state.ViewRows)
    $collectionView.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription('GroupHeaderKey')))
    $collectionView.Filter = [System.Predicate[object]]{
        param($obj)
        if ([string]::IsNullOrWhiteSpace($state.SearchQuery)) {
            return $true
        }
        $row = [WinDupe.Core.DuplicateRowViewModel]$obj
        $q = $state.SearchQuery
        return ($row.FileName.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
               ($row.DirectoryName.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    $state.CollectionView = $collectionView
    $ctrl.LstDuplicates.ItemsSource = $collectionView

    $brushKeep = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#10B981')
    $brushKeep.Freeze()
    $brushDelete = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#F87171')
    $brushDelete.Freeze()
    $brushScanIdle = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#0284C7')
    $brushScanIdle.Freeze()
    $brushScanBusy = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#DC2626')
    $brushScanBusy.Freeze()

    $getSelectedCategory = {
        if ($ctrl.FilterImages.IsChecked -eq $true)    { return 'Images' }
        if ($ctrl.FilterVideos.IsChecked -eq $true)    { return 'Videos' }
        if ($ctrl.FilterDocuments.IsChecked -eq $true) { return 'Documents' }
        if ($ctrl.FilterAudio.IsChecked -eq $true)     { return 'Audio' }
        return 'All'
    }

    $getMinSizeBytes = {
        $selectedItem = $ctrl.CmbMinSize.SelectedItem
        if ($null -ne $selectedItem -and $null -ne $selectedItem.Tag) {
            return [long]$selectedItem.Tag
        }
        return [long]1
    }

    $updateInspector = {
        param($row)
        $state.ActiveRow = $row
        if ($null -eq $row) {
            $ctrl.TxtPreviewEmpty.Visibility = [System.Windows.Visibility]::Visible
            $ctrl.PanelPreviewContent.Visibility = [System.Windows.Visibility]::Collapsed
            $ctrl.ImgPreview.Source = $null
            return
        }

        $ctrl.TxtPreviewEmpty.Visibility = [System.Windows.Visibility]::Collapsed
        $ctrl.PanelPreviewContent.Visibility = [System.Windows.Visibility]::Visible

        $ctrl.TxtInspectorName.Text = $row.FileName
        $ctrl.TxtInspectorPath.Text = $row.FullPath
        $ctrl.TxtInspectorSize.Text = "$($row.SizeHuman) ($('{0:N0}' -f $row.SizeBytes) bytes)"
        $ctrl.TxtInspectorModified.Text = $row.LastWriteTimeStr
        $ctrl.TxtInspectorCreated.Text = $row.CreationTimeStr
        $ctrl.TxtInspectorHash.Text = $row.Sha256

        if ($row.IsSelected) {
            $ctrl.TxtInspectorAction.Text = 'Enviar a Papelera'
            $ctrl.TxtInspectorAction.Foreground = $brushDelete
        }
        else {
            $ctrl.TxtInspectorAction.Text = 'Conservar copia'
            $ctrl.TxtInspectorAction.Foreground = $brushKeep
        }

        $ctrl.ImgPreview.Source = $null
        if ($row.IsPreviewableImage -and (Test-Path -LiteralPath $row.FullPath -PathType Leaf) -and $row.SizeBytes -le 26214400) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($row.FullPath)
                $ms = New-Object System.IO.MemoryStream(,$bytes)
                $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
                $bmp.BeginInit()
                $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bmp.DecodePixelWidth = 360
                $bmp.StreamSource = $ms
                $bmp.EndInit()
                $bmp.Freeze()
                $ms.Dispose()

                $ctrl.ImgPreview.Source = $bmp
                $ctrl.ImgPreview.Visibility = [System.Windows.Visibility]::Visible
                $ctrl.PanelNonImagePreview.Visibility = [System.Windows.Visibility]::Collapsed
            }
            catch {
                $ctrl.ImgPreview.Visibility = [System.Windows.Visibility]::Collapsed
                $ctrl.PanelNonImagePreview.Visibility = [System.Windows.Visibility]::Visible
                $ctrl.TxtPreviewExt.Text = if ([string]::IsNullOrWhiteSpace($row.Extension)) { 'ARCHIVO' } else { $row.Extension.ToUpperInvariant() }
            }
        }
        else {
            $ctrl.ImgPreview.Visibility = [System.Windows.Visibility]::Collapsed
            $ctrl.PanelNonImagePreview.Visibility = [System.Windows.Visibility]::Visible
            $ctrl.TxtPreviewExt.Text = if ([string]::IsNullOrWhiteSpace($row.Extension)) { 'ARCHIVO' } else { $row.Extension.ToUpperInvariant() }
        }
    }

    $refreshSelectionKpis = {
        $selectedCount = 0
        $selectedBytes = [long]0
        $groupIds = New-Object System.Collections.Generic.HashSet[int]
        $totalReclaim = [long]0

        $byGroup = @{}
        foreach ($r in $state.ViewRows) {
            [void]$groupIds.Add($r.GroupId)
            if (-not $byGroup.ContainsKey($r.GroupId)) {
                $byGroup[$r.GroupId] = New-Object System.Collections.Generic.List[object]
            }
            $byGroup[$r.GroupId].Add($r)

            if ($r.IsSelected) {
                $selectedCount++
                $selectedBytes += $r.SizeBytes
            }
        }

        foreach ($gKey in $byGroup.Keys) {
            $gList = $byGroup[$gKey]
            if ($gList.Count -gt 1) {
                $totalReclaim += ($gList[0].SizeBytes * ($gList.Count - 1))
            }
        }

        $ctrl.TxtKpiGroups.Text = ('{0:N0}' -f $groupIds.Count)
        $ctrl.TxtKpiFiles.Text = ('{0:N0} archivos en grupos' -f $state.ViewRows.Count)
        $ctrl.TxtKpiSelected.Text = ('{0:N0}' -f $selectedCount)
        $ctrl.TxtKpiSelectedBytes.Text = "$(Format-WinDupeBytes -Bytes $selectedBytes) por liberar"
        $ctrl.TxtKpiReclaimable.Text = Format-WinDupeBytes -Bytes $totalReclaim
        $ctrl.BtnSendToRecycle.Content = "Enviar a Papelera ($selectedCount)"
        $ctrl.BtnSendToRecycle.IsEnabled = (-not $state.IsScanning) -and ($selectedCount -gt 0)

        $hasRows = ($state.ViewRows.Count -gt 0) -and (-not $state.IsScanning)
        $ctrl.BtnKeepOldest.IsEnabled = $hasRows
        $ctrl.BtnKeepNewest.IsEnabled = $hasRows
        $ctrl.BtnAutoSelect.IsEnabled = $hasRows
        $ctrl.BtnClearSelection.IsEnabled = $hasRows

        if ($null -ne $state.ActiveRow) {
            if ($state.ActiveRow.IsSelected) {
                $ctrl.TxtInspectorAction.Text = 'Enviar a Papelera'
                $ctrl.TxtInspectorAction.Foreground = $brushDelete
            }
            else {
                $ctrl.TxtInspectorAction.Text = 'Conservar copia'
                $ctrl.TxtInspectorAction.Foreground = $brushKeep
            }
        }
    }

    # Seleccion O(n) de un solo recorrido sin sobrecarga de pipeline Sort-Object
    $applySmartSelection = {
        param([string]$Mode)

        $byGroup = @{}
        foreach ($r in $state.ViewRows) {
            if (-not $byGroup.ContainsKey($r.GroupId)) {
                $byGroup[$r.GroupId] = New-Object System.Collections.Generic.List[WinDupe.Core.DuplicateRowViewModel]
            }
            $byGroup[$r.GroupId].Add($r)
        }

        foreach ($gKey in $byGroup.Keys) {
            $items = $byGroup[$gKey]
            if ($Mode -eq 'Clear') {
                foreach ($item in $items) {
                    $item.IsSelected = $false
                }
                continue
            }

            $keepItem = $items[0]
            for ($idx = 1; $idx -lt $items.Count; $idx++) {
                $cand = $items[$idx]
                if ($Mode -eq 'Oldest') {
                    if ($cand.LastWriteTime -lt $keepItem.LastWriteTime -or
                        ($cand.LastWriteTime -eq $keepItem.LastWriteTime -and $cand.FullPath.Length -lt $keepItem.FullPath.Length)) {
                        $keepItem = $cand
                    }
                }
                elseif ($Mode -eq 'Newest') {
                    if ($cand.LastWriteTime -gt $keepItem.LastWriteTime -or
                        ($cand.LastWriteTime -eq $keepItem.LastWriteTime -and $cand.FullPath.Length -lt $keepItem.FullPath.Length)) {
                        $keepItem = $cand
                    }
                }
                elseif ($Mode -eq 'Auto') {
                    if ($cand.FullPath.Length -lt $keepItem.FullPath.Length -or
                        ($cand.FullPath.Length -eq $keepItem.FullPath.Length -and $cand.LastWriteTime -lt $keepItem.LastWriteTime)) {
                        $keepItem = $cand
                    }
                }
            }

            foreach ($item in $items) {
                $item.IsSelected = ($item.FullPath -ne $keepItem.FullPath)
            }
        }

        & $refreshSelectionKpis
    }

    $markDuplicatesInFolder = {
        param([string]$TargetFolder)
        if ([string]::IsNullOrWhiteSpace($TargetFolder)) { return }

        $byGroup = @{}
        foreach ($r in $state.ViewRows) {
            if (-not $byGroup.ContainsKey($r.GroupId)) {
                $byGroup[$r.GroupId] = New-Object System.Collections.Generic.List[WinDupe.Core.DuplicateRowViewModel]
            }
            $byGroup[$r.GroupId].Add($r)
        }

        $marked = 0
        foreach ($gKey in $byGroup.Keys) {
            $items = $byGroup[$gKey]
            $hasInside = $false
            $hasOutside = $false
            foreach ($item in $items) {
                if ([string]::Equals($item.DirectoryName, $TargetFolder, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $hasInside = $true
                }
                else {
                    $hasOutside = $true
                }
            }

            if (-not $hasInside) { continue }

            if ($hasOutside) {
                foreach ($item in $items) {
                    if ([string]::Equals($item.DirectoryName, $TargetFolder, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $item.IsSelected = $true
                        $marked++
                    }
                }
            }
            else {
                # Todas las copias estan en la misma carpeta: conservar al menos la mas antigua
                $keep = $items[0]
                for ($idx = 1; $idx -lt $items.Count; $idx++) {
                    if ($items[$idx].LastWriteTime -lt $keep.LastWriteTime) {
                        $keep = $items[$idx]
                    }
                }
                foreach ($item in $items) {
                    if ($item.FullPath -ne $keep.FullPath) {
                        $item.IsSelected = $true
                        $marked++
                    }
                    else {
                        $item.IsSelected = $false
                    }
                }
            }
        }

        & $refreshSelectionKpis
        $ctrl.TxtFooterAudit.Text = "Carpeta marcada: $marked copia(s) seleccionadas en '$TargetFolder' (conservando originales)."
    }

    $setScanningUiState = {
        param([bool]$Scanning)
        $state.IsScanning = $Scanning
        $ctrl.BtnDownloads.IsEnabled = -not $Scanning
        $ctrl.BtnDocuments.IsEnabled = -not $Scanning
        $ctrl.BtnPictures.IsEnabled = -not $Scanning
        $ctrl.BtnBrowse.IsEnabled = -not $Scanning
        $ctrl.TxtScanPath.IsEnabled = -not $Scanning
        $ctrl.FilterAll.IsEnabled = -not $Scanning
        $ctrl.FilterImages.IsEnabled = -not $Scanning
        $ctrl.FilterVideos.IsEnabled = -not $Scanning
        $ctrl.FilterDocuments.IsEnabled = -not $Scanning
        $ctrl.FilterAudio.IsEnabled = -not $Scanning
        $ctrl.CmbMinSize.IsEnabled = -not $Scanning

        if ($Scanning) {
            $ctrl.BtnScan.Content = 'Cancelar escaneo'
            $ctrl.BtnScan.Background = $brushScanBusy
        }
        else {
            $ctrl.BtnScan.Content = 'Escanear duplicados'
            $ctrl.BtnScan.Background = $brushScanIdle
        }
        & $refreshSelectionKpis
    }

    $populateScanResults = {
        param($result)
        $state.LastScanResult = $result
        $state.ViewRows.Clear()
        & $updateInspector $null

        if ($null -eq $result) {
            return
        }

        $ctrl.TxtKpiScanned.Text = ('{0:N0}' -f $result.TotalFilesEnumerated)
        $ctrl.TxtKpiFunnel.Text = ("F1: {0:N0} -> F2: {1:N0} -> F3: {2:N0}" -f $result.Phase1Candidates, $result.Phase2Candidates, $result.TotalDuplicateFiles)
        $ctrl.TxtKpiElapsed.Text = ("Tiempo: {0:N2} s" -f ($result.ElapsedMilliseconds / 1000.0))
        $ctrl.TxtGuardrailNotice.Text = ("Guardrails: {0:N0} prot./ocultas | {1:N0} nube OneDrive | {2:N0} hard links NTFS omitidos." -f $result.SkippedSystemOrProtected, $result.SkippedCloudPlaceholders, $result.HardLinksSkipped)

        if ($result.WasCancelled) {
            $ctrl.TxtPhaseStatus.Text = 'Escaneo cancelado por el usuario.'
            $ctrl.TxtProgressPct.Text = '0%'
            $ctrl.ProgressScan.Value = 0
            $ctrl.LstDuplicates.Visibility = [System.Windows.Visibility]::Collapsed
            $ctrl.TxtEmptyListHint.Visibility = [System.Windows.Visibility]::Visible
            $ctrl.TxtEmptyListHint.Text = 'Escaneo cancelado. Puedes iniciar uno nuevo cuando quieras.'
            & $refreshSelectionKpis
            return
        }

        foreach ($grp in $result.Groups) {
            $shortSha = if ($grp.Sha256.Length -ge 12) { $grp.Sha256.Substring(0, 12) } else { $grp.Sha256 }
            $header = "Grupo #$($grp.GroupId)  ·  $($grp.FileCount) copias  ·  $(Format-WinDupeBytes -Bytes $grp.FileSizeBytes) c/u  ·  Recuperable: $(Format-WinDupeBytes -Bytes $grp.ReclaimableBytes)  ·  SHA-256: $shortSha"

            foreach ($f in $grp.Files) {
                $vm = New-Object WinDupe.Core.DuplicateRowViewModel
                $vm.GroupId = $grp.GroupId
                $vm.GroupHeaderKey = $header
                $vm.FullPath = $f.FullPath
                $vm.FileName = $f.FileName
                $vm.DirectoryName = $f.DirectoryName
                $vm.Extension = $f.Extension
                $vm.SizeBytes = $f.SizeBytes
                $vm.SizeHuman = Format-WinDupeBytes -Bytes $f.SizeBytes
                $vm.LastWriteTime = $f.LastWriteTime
                $vm.LastWriteTimeStr = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                $vm.CreationTime = $f.CreationTime
                $vm.CreationTimeStr = $f.CreationTime.ToString('yyyy-MM-dd HH:mm')
                $vm.Sha256 = $f.FullHash
                $vm.ShortSha = $shortSha
                $vm.IsPreviewableImage = $previewableExts.Contains($f.Extension)
                $vm.IsSelected = $false
                $state.ViewRows.Add($vm)
            }
        }

        if ($state.ViewRows.Count -gt 0) {
            $ctrl.TxtEmptyListHint.Visibility = [System.Windows.Visibility]::Collapsed
            $ctrl.LstDuplicates.Visibility = [System.Windows.Visibility]::Visible
            & $applySmartSelection 'Oldest'
        }
        else {
            $ctrl.LstDuplicates.Visibility = [System.Windows.Visibility]::Collapsed
            $ctrl.TxtEmptyListHint.Visibility = [System.Windows.Visibility]::Visible
            $ctrl.TxtEmptyListHint.Text = 'Excelente: no se encontraron archivos duplicados con los filtros seleccionados.'
            & $refreshSelectionKpis
        }

        $ctrl.ProgressScan.Value = 100
        $ctrl.TxtProgressPct.Text = '100%'
        $ctrl.TxtPhaseStatus.Text = "Completado: $($result.DuplicateGroupCount) grupos duplicados detectados ($(Format-WinDupeBytes -Bytes $result.TotalReclaimableBytes) recuperables)."
    }

    $startOrCancelScan = {
        if ($state.IsScanning) {
            if ($null -ne $state.ScanHandle) {
                $state.ScanHandle.Controller.RequestCancel()
                $ctrl.TxtPhaseStatus.Text = 'Cancelando escaneo en curso...'
            }
            return
        }

        $targetPath = $ctrl.TxtScanPath.Text
        $category = & $getSelectedCategory
        $minSizeBytes = & $getMinSizeBytes

        $guard = Test-WinDupeScanPath -Path $targetPath -BlockedFolderNames @($categoriesConfig.blockedFolderNames)
        if (-not $guard.IsValid) {
            [System.Windows.MessageBox]::Show(
                $window,
                $guard.Reason,
                'WinDupe — Ruta bloqueada por Guardrail',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            ) | Out-Null
            return
        }

        $ctrl.TxtScanPath.Text = $guard.NormalizedPath
        $state.ViewRows.Clear()
        & $updateInspector $null
        $ctrl.LstDuplicates.Visibility = [System.Windows.Visibility]::Collapsed
        $ctrl.TxtEmptyListHint.Visibility = [System.Windows.Visibility]::Visible
        $ctrl.TxtEmptyListHint.Text = 'Escaneando en segundo plano (3 fases)...'
        $ctrl.ProgressScan.Value = 3
        $ctrl.TxtProgressPct.Text = '3%'
        $ctrl.TxtPhaseStatus.Text = 'Iniciando motor C# de 3 fases...'
        $ctrl.TxtKpiScanned.Text = '0'
        $ctrl.TxtKpiFunnel.Text = 'Preparando...'
        $ctrl.TxtKpiElapsed.Text = 'En curso...'

        try {
            $handle = Start-WinDupeScanAsync -BasePath $state.BasePath -RootPath $guard.NormalizedPath -CategoryKey $category -MinimumSizeBytes $minSizeBytes
            $state.ScanHandle = $handle
            & $setScanningUiState $true

            $timer = New-Object System.Windows.Threading.DispatcherTimer
            $timer.Interval = [TimeSpan]::FromMilliseconds(60)
            $timer.Add_Tick({
                $h = $state.ScanHandle
                if ($null -eq $h) {
                    $timer.Stop()
                    return
                }

                $evt = $null
                while ($h.ProgressQueue.TryDequeue([ref]$evt)) {
                    $ctrl.TxtPhaseStatus.Text = "[$($evt.PhaseName)] $($evt.Message)"
                    $pctInt = [int][Math]::Round($evt.Percent)
                    $ctrl.ProgressScan.Value = $pctInt
                    $ctrl.TxtProgressPct.Text = "$pctInt%"
                    if ($evt.FilesScanned -gt 0) {
                        $ctrl.TxtKpiScanned.Text = ('{0:N0}' -f $evt.FilesScanned)
                    }
                }

                if ($h.AsyncResult.IsCompleted) {
                    $timer.Stop()
                    $state.PollTimer = $null

                    $scanRes = $null
                    $scanErr = $null
                    try {
                        $output = $h.PowerShell.EndInvoke($h.AsyncResult)
                        if ($h.PowerShell.Streams.Error.Count -gt 0) {
                            $scanErr = $h.PowerShell.Streams.Error[0].Exception
                        }
                        elseif ($output.Count -gt 0) {
                            $scanRes = $output[0]
                        }
                    }
                    catch {
                        $scanErr = $_.Exception
                    }
                    finally {
                        $h.PowerShell.Dispose()
                        $h.RunspacePool.Close()
                        $h.RunspacePool.Dispose()
                        $state.ScanHandle = $null
                    }

                    & $setScanningUiState $false

                    if ($null -ne $scanErr) {
                        $errPath = Write-WinDupeErrorLog -Exception $scanErr -Context 'BackgroundScan'
                        $ctrl.TxtPhaseStatus.Text = "Error en el escaneo: $($scanErr.Message)"
                        [System.Windows.MessageBox]::Show(
                            $window,
                            "Ocurrio un error durante el escaneo:`n$($scanErr.Message)`n`nLog guardado en: $errPath",
                            'WinDupe — Error',
                            [System.Windows.MessageBoxButton]::OK,
                            [System.Windows.MessageBoxImage]::Error
                        ) | Out-Null
                    }
                    else {
                        & $populateScanResults $scanRes
                    }
                }
            })
            $state.PollTimer = $timer
            $timer.Start()
        }
        catch {
            $errPath = Write-WinDupeErrorLog -Exception $_.Exception -Context 'StartScan'
            & $setScanningUiState $false
            [System.Windows.MessageBox]::Show(
                $window,
                "No se pudo iniciar el escaneo:`n$($_.Exception.Message)`n`nLog: $errPath",
                'WinDupe — Error al iniciar',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            ) | Out-Null
        }
    }

    # Eventos de seleccion rapida de carpetas
    $ctrl.BtnDownloads.Add_Click({ $ctrl.TxtScanPath.Text = $quickFolders.Downloads })
    $ctrl.BtnDocuments.Add_Click({ $ctrl.TxtScanPath.Text = $quickFolders.Documents })
    $ctrl.BtnPictures.Add_Click({ $ctrl.TxtScanPath.Text = $quickFolders.Pictures })
    $ctrl.BtnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Selecciona la carpeta que deseas analizar en busca de duplicados'
        $dlg.ShowNewFolderButton = $false
        if (Test-Path -LiteralPath $ctrl.TxtScanPath.Text -PathType Container) {
            $dlg.SelectedPath = $ctrl.TxtScanPath.Text
        }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $ctrl.TxtScanPath.Text = $dlg.SelectedPath
        }
        $dlg.Dispose()
    })

    $ctrl.BtnOpenLogs.Add_Click({
        $logsDir = Get-WinDupeLogsDirectory
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$logsDir`""
    })

    $ctrl.BtnScan.Add_Click($startOrCancelScan)

    # Atajos de teclado F5 (Escanear) y Escape (Cancelar)
    $window.Add_KeyDown({
        param($sender, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::F5 -and (-not $state.IsScanning)) {
            & $startOrCancelScan
            $e.Handled = $true
        }
        elseif ($e.Key -eq [System.Windows.Input.Key]::Escape -and $state.IsScanning) {
            & $startOrCancelScan
            $e.Handled = $true
        }
    })

    # Busqueda en tiempo real
    $ctrl.TxtSearchFilter.Add_TextChanged({
        $txt = $ctrl.TxtSearchFilter.Text
        $state.SearchQuery = if ($null -eq $txt) { '' } else { $txt.Trim() }
        $hasText = -not [string]::IsNullOrEmpty($state.SearchQuery)
        $ctrl.TxtSearchPlaceholder.Visibility = if ($hasText) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
        $ctrl.BtnClearSearch.Visibility = if ($hasText) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        $state.CollectionView.Refresh()
    })

    $ctrl.BtnClearSearch.Add_Click({
        $ctrl.TxtSearchFilter.Text = ''
    })

    # Seleccion inteligente
    $ctrl.BtnKeepOldest.Add_Click({ & $applySmartSelection 'Oldest' })
    $ctrl.BtnKeepNewest.Add_Click({ & $applySmartSelection 'Newest' })
    $ctrl.BtnAutoSelect.Add_Click({ & $applySmartSelection 'Auto' })
    $ctrl.BtnClearSelection.Add_Click({ & $applySmartSelection 'Clear' })

    $ctrl.LstDuplicates.AddHandler(
        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [System.Windows.RoutedEventHandler]{
            param($sender, $e)
            if ($e.OriginalSource -is [System.Windows.Controls.CheckBox]) {
                & $refreshSelectionKpis
            }
        }
    )

    $ctrl.LstDuplicates.Add_SelectionChanged({
        $selectedItem = $ctrl.LstDuplicates.SelectedItem
        & $updateInspector $selectedItem
    })

    # Menu contextual & acciones de carpeta
    $ctrl.MenuMarkFolderDuplicates.Add_Click({
        if ($null -ne $state.ActiveRow) {
            & $markDuplicatesInFolder $state.ActiveRow.DirectoryName
        }
    })
    $ctrl.MenuKeepThis.Add_Click({
        if ($null -ne $state.ActiveRow) {
            $state.ActiveRow.IsSelected = $false
            & $refreshSelectionKpis
        }
    })
    $ctrl.MenuOpenFolder.Add_Click({
        if ($null -ne $state.ActiveRow -and (Test-Path -LiteralPath $state.ActiveRow.FullPath -PathType Leaf)) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$($state.ActiveRow.FullPath)`""
        }
    })

    $ctrl.BtnMarkFolderDuplicates.Add_Click({
        if ($null -ne $state.ActiveRow) {
            & $markDuplicatesInFolder $state.ActiveRow.DirectoryName
        }
    })

    $ctrl.BtnOpenLocation.Add_Click({
        if ($null -ne $state.ActiveRow -and (Test-Path -LiteralPath $state.ActiveRow.FullPath -PathType Leaf)) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$($state.ActiveRow.FullPath)`""
        }
    })

    $ctrl.BtnCopyHash.Add_Click({
        if ($null -ne $state.ActiveRow -and -not [string]::IsNullOrWhiteSpace($state.ActiveRow.Sha256)) {
            [System.Windows.Clipboard]::SetText($state.ActiveRow.Sha256)
            $ctrl.TxtFooterAudit.Text = 'Hash SHA-256 copiado al portapapeles.'
        }
    })

    $ctrl.BtnSendToRecycle.Add_Click({
        $selectedRows = @($state.ViewRows | Where-Object { $_.IsSelected })
        if ($selectedRows.Count -eq 0) {
            return
        }

        $fullGroupsCount = 0
        $byGroup = @{}
        foreach ($r in $state.ViewRows) {
            if (-not $byGroup.ContainsKey($r.GroupId)) {
                $byGroup[$r.GroupId] = New-Object System.Collections.Generic.List[object]
            }
            $byGroup[$r.GroupId].Add($r)
        }
        foreach ($gKey in $byGroup.Keys) {
            $allChecked = $true
            foreach ($item in $byGroup[$gKey]) {
                if (-not $item.IsSelected) {
                    $allChecked = $false
                    break
                }
            }
            if ($allChecked) {
                $fullGroupsCount++
            }
        }

        $totalBytesToRecycle = [long]0
        foreach ($s in $selectedRows) {
            $totalBytesToRecycle += $s.SizeBytes
        }

        $confirmMsg = "Se enviaran $($selectedRows.Count) archivo(s) ($(Format-WinDupeBytes -Bytes $totalBytesToRecycle)) a la Papelera de Reciclaje de Windows.`nPodras restaurarlos desde la Papelera si lo necesitas."
        if ($fullGroupsCount -gt 0) {
            $confirmMsg += "`n`nADVERTENCIA: En $fullGroupsCount grupo(s) seleccionaste TODAS las copias sin conservar ningun original."
        }

        $answer = [System.Windows.MessageBox]::Show(
            $window,
            $confirmMsg,
            'Confirmar envio seguro a Papelera',
            [System.Windows.MessageBoxButton]::YesNo,
            $(if ($fullGroupsCount -gt 0) { [System.Windows.MessageBoxImage]::Warning } else { [System.Windows.MessageBoxImage]::Question })
        )

        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
            return
        }

        $ctrl.ImgPreview.Source = $null

        $recycleResult = Invoke-WinDupeRecycleFiles -Items $selectedRows
        $deletedSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($dp in $recycleResult.DeletedPaths) {
            [void]$deletedSet.Add($dp)
        }

        for ($i = $state.ViewRows.Count - 1; $i -ge 0; $i--) {
            if ($deletedSet.Contains($state.ViewRows[$i].FullPath)) {
                $state.ViewRows.RemoveAt($i)
            }
        }

        $remainingByGroup = @{}
        foreach ($r in $state.ViewRows) {
            if (-not $remainingByGroup.ContainsKey($r.GroupId)) {
                $remainingByGroup[$r.GroupId] = 0
            }
            $remainingByGroup[$r.GroupId]++
        }
        for ($i = $state.ViewRows.Count - 1; $i -ge 0; $i--) {
            if ($remainingByGroup[$state.ViewRows[$i].GroupId] -lt 2) {
                $state.ViewRows.RemoveAt($i)
            }
        }

        & $updateInspector $null
        & $refreshSelectionKpis

        if ($state.ViewRows.Count -eq 0) {
            $ctrl.LstDuplicates.Visibility = [System.Windows.Visibility]::Collapsed
            $ctrl.TxtEmptyListHint.Visibility = [System.Windows.Visibility]::Visible
            $ctrl.TxtEmptyListHint.Text = 'Limpieza completada: todos los duplicados seleccionados fueron enviados a la Papelera.'
        }

        $freedHuman = Format-WinDupeBytes -Bytes $recycleResult.ReclaimedBytes
        $ctrl.TxtFooterAudit.Text = "Auditoria: $($recycleResult.DeletedCount) enviados a Papelera ($freedHuman liberados)."

        $summaryMsg = "Archivos enviados a Papelera: $($recycleResult.DeletedCount)`nEspacio recuperado: $freedHuman`nRegistro de auditoria: $($recycleResult.LogsDirectory)\audit_history.log"
        if ($recycleResult.FailedItems.Count -gt 0) {
            $summaryMsg += "`n`nNo se pudieron mover $($recycleResult.FailedItems.Count) archivo(s) (revisa el log de auditoria)."
        }

        [System.Windows.MessageBox]::Show(
            $window,
            $summaryMsg,
            'WinDupe — Limpieza completada',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
    })

    $window.Add_Closing({
        if ($null -ne $state.PollTimer) {
            $state.PollTimer.Stop()
        }
        if ($null -ne $state.ScanHandle) {
            try {
                $state.ScanHandle.Controller.RequestCancel()
                $state.ScanHandle.PowerShell.Stop()
                $state.ScanHandle.PowerShell.Dispose()
                $state.ScanHandle.RunspacePool.Close()
                $state.ScanHandle.RunspacePool.Dispose()
            }
            catch {
                # Limpieza silenciosa al cerrar
            }
        }
    })

    [void]$window.ShowDialog()
}

try {
    if ($Cli) {
        Invoke-WinDupeCli -BasePath $resolvedBase -ScanPath $Path -ProfileName $Profile -Filter $Filter -MinSizeMB $MinSizeMB -AsJson:$Json
    }
    else {
        Start-WinDupeGui -AppBasePath $resolvedBase -InitialProfile $Profile -InitialPath $Path -InitialFilter $Filter -InitialMinSizeMB $MinSizeMB
    }
}
catch {
    $errPath = Write-WinDupeErrorLog -Exception $_.Exception -Context ($(if ($Cli) { 'CLI' } else { 'GUI' }))
    if ($Cli) {
        Write-Error ("WinDupe Error: {0}`nDetalle guardado en: {1}" -f $_.Exception.Message, $errPath)
        exit 1
    }
    else {
        try {
            Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
            [System.Windows.MessageBox]::Show(
                "Error critico en WinDupe:`n$($_.Exception.Message)`n`nLog de diagnostico: $errPath",
                'WinDupe — Error Critico',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            ) | Out-Null
        }
        catch {
            Write-Error $_.Exception.Message
        }
        exit 1
    }
}
