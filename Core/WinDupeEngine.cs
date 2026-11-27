using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace WinDupe.Core
{
    public sealed class DuplicateRowViewModel : INotifyPropertyChanged
    {
        private bool _isSelected;
        private string _statusLabel;
        private string _statusColor;

        public event PropertyChangedEventHandler PropertyChanged;

        public int GroupId { get; set; }
        public string GroupHeaderKey { get; set; }
        public string FullPath { get; set; }
        public string FileName { get; set; }
        public string DirectoryName { get; set; }
        public string Extension { get; set; }
        public long SizeBytes { get; set; }
        public string SizeHuman { get; set; }
        public DateTime LastWriteTime { get; set; }
        public string LastWriteTimeStr { get; set; }
        public DateTime CreationTime { get; set; }
        public string CreationTimeStr { get; set; }
        public string Sha256 { get; set; }
        public string ShortSha { get; set; }
        public bool IsPreviewableImage { get; set; }

        public bool IsSelected
        {
            get { return _isSelected; }
            set
            {
                if (_isSelected != value)
                {
                    _isSelected = value;
                    OnPropertyChanged("IsSelected");
                    UpdateStatusPresentation();
                }
            }
        }

        public string StatusLabel
        {
            get { return _statusLabel; }
            private set
            {
                if (_statusLabel != value)
                {
                    _statusLabel = value;
                    OnPropertyChanged("StatusLabel");
                }
            }
        }

        public string StatusColor
        {
            get { return _statusColor; }
            private set
            {
                if (_statusColor != value)
                {
                    _statusColor = value;
                    OnPropertyChanged("StatusColor");
                }
            }
        }

        public DuplicateRowViewModel()
        {
            _statusLabel = "CONSERVAR";
            _statusColor = "#10B981";
        }

        private void UpdateStatusPresentation()
        {
            if (_isSelected)
            {
                StatusLabel = "PAPELERA";
                StatusColor = "#F87171";
            }
            else
            {
                StatusLabel = "CONSERVAR";
                StatusColor = "#10B981";
            }
        }

        private void OnPropertyChanged(string propertyName)
        {
            PropertyChangedEventHandler handler = PropertyChanged;
            if (handler != null)
            {
                handler(this, new PropertyChangedEventArgs(propertyName));
            }
        }
    }

    public sealed class ScanController
    {
        private volatile bool _cancelRequested;

        public void RequestCancel()
        {
            _cancelRequested = true;
        }

        public bool IsCancelled
        {
            get { return _cancelRequested; }
        }
    }

    public sealed class ScanOptions
    {
        public string RootPath { get; set; }
        public string[] AllowedExtensions { get; set; }
        public long MinimumSizeBytes { get; set; }
        public string[] BlockedPrefixes { get; set; }
        public string[] BlockedFolderNames { get; set; }
        public bool SkipHiddenAndSystem { get; set; }
        public bool SkipCloudPlaceholders { get; set; }

        public ScanOptions()
        {
            MinimumSizeBytes = 1;
            SkipHiddenAndSystem = true;
            SkipCloudPlaceholders = true;
            AllowedExtensions = new string[0];
            BlockedPrefixes = new string[0];
            BlockedFolderNames = new string[0];
        }
    }

    public sealed class ScanProgressEvent
    {
        public int Phase { get; set; }
        public string PhaseName { get; set; }
        public string Message { get; set; }
        public long FilesScanned { get; set; }
        public long CandidatesCount { get; set; }
        public long CompletedSteps { get; set; }
        public long TotalSteps { get; set; }
        public double Percent { get; set; }
    }

    public sealed class DuplicateFileEntry
    {
        public string FullPath { get; set; }
        public string FileName { get; set; }
        public string DirectoryName { get; set; }
        public string Extension { get; set; }
        public long SizeBytes { get; set; }
        public DateTime LastWriteTime { get; set; }
        public DateTime CreationTime { get; set; }
        public string PartialHash { get; set; }
        public string FullHash { get; set; }
    }

    public sealed class DuplicateGroup
    {
        public int GroupId { get; set; }
        public string Sha256 { get; set; }
        public long FileSizeBytes { get; set; }
        public int FileCount { get; set; }
        public long ReclaimableBytes { get; set; }
        public List<DuplicateFileEntry> Files { get; set; }

        public DuplicateGroup()
        {
            Files = new List<DuplicateFileEntry>();
        }
    }

    public sealed class ScanResult
    {
        public string RootPath { get; set; }
        public long TotalFilesEnumerated { get; set; }
        public long SkippedSystemOrProtected { get; set; }
        public long SkippedCloudPlaceholders { get; set; }
        public long HardLinksSkipped { get; set; }
        public long AccessErrors { get; set; }
        public int Phase1SizeGroups { get; set; }
        public long Phase1Candidates { get; set; }
        public int Phase2PartialGroups { get; set; }
        public long Phase2Candidates { get; set; }
        public int DuplicateGroupCount { get; set; }
        public long TotalDuplicateFiles { get; set; }
        public long TotalReclaimableBytes { get; set; }
        public long ElapsedMilliseconds { get; set; }
        public bool WasCancelled { get; set; }
        public List<DuplicateGroup> Groups { get; set; }

        public ScanResult()
        {
            Groups = new List<DuplicateGroup>();
        }
    }

    internal sealed class FileCandidate
    {
        public string FullPath;
        public string FileName;
        public string DirectoryName;
        public string Extension;
        public long SizeBytes;
        public DateTime LastWriteTime;
        public DateTime CreationTime;
        public string PartialHash;
        public string FullHash;
        public bool IsFullHashKnown;
        public string NtfsFileKey;
    }

    internal static class NtfsNative
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct FILETIME
        {
            public uint dwLowDateTime;
            public uint dwHighDateTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct BY_HANDLE_FILE_INFORMATION
        {
            public uint FileAttributes;
            public FILETIME CreationTime;
            public FILETIME LastAccessTime;
            public FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetFileInformationByHandle(
            SafeFileHandle hFile,
            out BY_HANDLE_FILE_INFORMATION lpFileInformation);

        public static string TryGetUniqueInodeKey(SafeFileHandle handle)
        {
            if (handle == null || handle.IsInvalid)
            {
                return null;
            }

            BY_HANDLE_FILE_INFORMATION info;
            if (!GetFileInformationByHandle(handle, out info))
            {
                return null;
            }

            if (info.NumberOfLinks <= 1)
            {
                return null;
            }

            return info.VolumeSerialNumber.ToString("x8") + ":" +
                   info.FileIndexHigh.ToString("x8") + info.FileIndexLow.ToString("x8");
        }
    }

    public static class DuplicateScanner
    {
        private const int PartialBufferBytes = 16384; // 16 KB
        private const int FullBufferBytes = 131072;   // 128 KB
        private const int AttrOffline = 0x1000;
        private const int AttrRecallOnOpen = 0x00040000;
        private const int AttrRecallOnDataAccess = 0x00400000;

        public static ScanResult Scan(
            ScanOptions options,
            ScanController controller,
            ConcurrentQueue<ScanProgressEvent> progressQueue)
        {
            if (options == null || string.IsNullOrEmpty(options.RootPath))
            {
                throw new ArgumentException("RootPath cannot be empty.");
            }

            Stopwatch stopwatch = Stopwatch.StartNew();
            ScanResult result = new ScanResult();
            result.RootPath = Path.GetFullPath(options.RootPath);

            HashSet<string> allowedExt = BuildLowerSet(options.AllowedExtensions);
            HashSet<string> blockedNames = BuildLowerSet(options.BlockedFolderNames);
            string[] normalizedBlockedPrefixes = NormalizePrefixes(options.BlockedPrefixes);

            // =========================================================================
            // FASE 0 & 1: Enumeracion segura + Agrupacion rapida por tamano en bytes
            // =========================================================================
            EmitProgress(progressQueue, 1, "Fase 1/3: Tamano en bytes", "Explorando carpetas y agrupando por tamano exacto...", 0, 0, 0, 0, 5.0);

            Dictionary<long, List<FileCandidate>> sizeBuckets = new Dictionary<long, List<FileCandidate>>();
            Stack<string> pendingDirs = new Stack<string>();
            pendingDirs.Push(result.RootPath);

            long filesEnumerated = 0;
            long skippedProtected = 0;
            long skippedCloud = 0;
            long accessErrors = 0;
            long lastReportTicks = stopwatch.ElapsedMilliseconds;

            while (pendingDirs.Count > 0)
            {
                if (controller != null && controller.IsCancelled)
                {
                    result.WasCancelled = true;
                    break;
                }

                string currentDir = pendingDirs.Pop();
                if (IsBlockedDirectory(currentDir, normalizedBlockedPrefixes, blockedNames))
                {
                    skippedProtected++;
                    continue;
                }

                string[] subDirs = null;
                try
                {
                    subDirs = Directory.GetDirectories(currentDir);
                }
                catch
                {
                    accessErrors++;
                }

                if (subDirs != null)
                {
                    for (int i = 0; i < subDirs.Length; i++)
                    {
                        string subDir = subDirs[i];
                        try
                        {
                            DirectoryInfo di = new DirectoryInfo(subDir);
                            FileAttributes attrs = di.Attributes;

                            if ((attrs & FileAttributes.ReparsePoint) != 0)
                            {
                                skippedProtected++;
                                continue;
                            }

                            if (options.SkipHiddenAndSystem &&
                                (((attrs & FileAttributes.Hidden) != 0) || ((attrs & FileAttributes.System) != 0)))
                            {
                                skippedProtected++;
                                continue;
                            }

                            if (IsBlockedDirectory(subDir, normalizedBlockedPrefixes, blockedNames))
                            {
                                skippedProtected++;
                                continue;
                            }

                            pendingDirs.Push(subDir);
                        }
                        catch
                        {
                            accessErrors++;
                        }
                    }
                }

                string[] files = null;
                try
                {
                    files = Directory.GetFiles(currentDir);
                }
                catch
                {
                    accessErrors++;
                }

                if (files != null)
                {
                    for (int i = 0; i < files.Length; i++)
                    {
                        if (controller != null && controller.IsCancelled)
                        {
                            result.WasCancelled = true;
                            break;
                        }

                        string filePath = files[i];
                        try
                        {
                            FileInfo fi = new FileInfo(filePath);
                            FileAttributes fAttrs = fi.Attributes;
                            int rawAttrs = (int)fAttrs;

                            if ((fAttrs & FileAttributes.ReparsePoint) != 0)
                            {
                                skippedProtected++;
                                continue;
                            }

                            if (options.SkipCloudPlaceholders &&
                                ((rawAttrs & AttrOffline) != 0 ||
                                 (rawAttrs & AttrRecallOnOpen) != 0 ||
                                 (rawAttrs & AttrRecallOnDataAccess) != 0))
                            {
                                skippedCloud++;
                                continue;
                            }

                            if (options.SkipHiddenAndSystem &&
                                (((fAttrs & FileAttributes.Hidden) != 0) || ((fAttrs & FileAttributes.System) != 0)))
                            {
                                skippedProtected++;
                                continue;
                            }

                            string ext = (fi.Extension ?? string.Empty).ToLowerInvariant();
                            if (allowedExt.Count > 0 && !allowedExt.Contains(ext))
                            {
                                continue;
                            }

                            long size = fi.Length;
                            filesEnumerated++;

                            if (size < options.MinimumSizeBytes)
                            {
                                continue;
                            }

                            List<FileCandidate> bucket;
                            if (!sizeBuckets.TryGetValue(size, out bucket))
                            {
                                bucket = new List<FileCandidate>();
                                sizeBuckets[size] = bucket;
                            }

                            FileCandidate candidate = new FileCandidate();
                            candidate.FullPath = fi.FullName;
                            candidate.FileName = fi.Name;
                            candidate.DirectoryName = fi.DirectoryName ?? string.Empty;
                            candidate.Extension = ext;
                            candidate.SizeBytes = size;
                            candidate.LastWriteTime = fi.LastWriteTime;
                            candidate.CreationTime = fi.CreationTime;
                            bucket.Add(candidate);
                        }
                        catch
                        {
                            accessErrors++;
                        }
                    }
                }

                long nowMs = stopwatch.ElapsedMilliseconds;
                if (nowMs - lastReportTicks >= 120)
                {
                    lastReportTicks = nowMs;
                    EmitProgress(
                        progressQueue,
                        1,
                        "Fase 1/3: Tamano en bytes",
                        string.Format("Analizando archivos ({0:N0} encontrados)...", filesEnumerated),
                        filesEnumerated,
                        0,
                        0,
                        0,
                        15.0);
                }
            }

            result.TotalFilesEnumerated = filesEnumerated;
            result.SkippedSystemOrProtected = skippedProtected;
            result.SkippedCloudPlaceholders = skippedCloud;
            result.AccessErrors = accessErrors;

            if (result.WasCancelled)
            {
                stopwatch.Stop();
                result.ElapsedMilliseconds = stopwatch.ElapsedMilliseconds;
                EmitProgress(progressQueue, -1, "Cancelado", "Escaneo cancelado por el usuario.", filesEnumerated, 0, 0, 0, 0);
                return result;
            }

            // Descartar archivos con tamano unico al instante
            List<List<FileCandidate>> phase1Groups = new List<List<FileCandidate>>();
            long phase1CandidateCount = 0;
            foreach (KeyValuePair<long, List<FileCandidate>> kv in sizeBuckets)
            {
                if (kv.Value.Count >= 2)
                {
                    phase1Groups.Add(kv.Value);
                    phase1CandidateCount += kv.Value.Count;
                }
            }
            sizeBuckets.Clear();

            result.Phase1SizeGroups = phase1Groups.Count;
            result.Phase1Candidates = phase1CandidateCount;

            if (phase1CandidateCount == 0)
            {
                stopwatch.Stop();
                result.ElapsedMilliseconds = stopwatch.ElapsedMilliseconds;
                EmitProgress(progressQueue, 4, "Completado", "No se encontraron candidatos con tamano coincidente.", filesEnumerated, 0, 1, 1, 100.0);
                return result;
            }

            // =========================================================================
            // FASE 2: Hash parcial de los primeros 16 KB + filtro de Hard Links NTFS
            // =========================================================================
            EmitProgress(
                progressQueue,
                2,
                "Fase 2/3: Hash parcial (16 KB)",
                string.Format("Verificando primeros 16 KB de {0:N0} candidatos...", phase1CandidateCount),
                filesEnumerated,
                phase1CandidateCount,
                0,
                phase1CandidateCount,
                25.0);

            Dictionary<string, List<FileCandidate>> partialBuckets = new Dictionary<string, List<FileCandidate>>(StringComparer.Ordinal);
            HashSet<string> seenHardLinkInodes = new HashSet<string>(StringComparer.Ordinal);
            long phase2Processed = 0;
            byte[] partialBuffer = new byte[PartialBufferBytes];

            using (SHA256 sha = SHA256.Create())
            {
                for (int g = 0; g < phase1Groups.Count; g++)
                {
                    if (controller != null && controller.IsCancelled)
                    {
                        result.WasCancelled = true;
                        break;
                    }

                    List<FileCandidate> group = phase1Groups[g];
                    for (int i = 0; i < group.Count; i++)
                    {
                        if (controller != null && controller.IsCancelled)
                        {
                            result.WasCancelled = true;
                            break;
                        }

                        FileCandidate item = group[i];
                        phase2Processed++;

                        try
                        {
                            string inodeKey;
                            string pHash = ComputePartialSha256AndInode(item.FullPath, sha, partialBuffer, out inodeKey);
                            if (!string.IsNullOrEmpty(inodeKey))
                            {
                                item.NtfsFileKey = inodeKey;
                                if (!seenHardLinkInodes.Add(inodeKey))
                                {
                                    result.HardLinksSkipped++;
                                    continue;
                                }
                            }

                            if (pHash != null)
                            {
                                item.PartialHash = pHash;
                                if (item.SizeBytes <= PartialBufferBytes)
                                {
                                    item.FullHash = pHash;
                                    item.IsFullHashKnown = true;
                                }

                                string key = item.SizeBytes.ToString() + ":" + pHash;
                                List<FileCandidate> pBucket;
                                if (!partialBuckets.TryGetValue(key, out pBucket))
                                {
                                    pBucket = new List<FileCandidate>();
                                    partialBuckets[key] = pBucket;
                                }
                                pBucket.Add(item);
                            }
                        }
                        catch
                        {
                            result.AccessErrors++;
                        }

                        long nowMs = stopwatch.ElapsedMilliseconds;
                        if (nowMs - lastReportTicks >= 100 || phase2Processed == phase1CandidateCount)
                        {
                            lastReportTicks = nowMs;
                            double pct = 25.0 + ((double)phase2Processed / (double)phase1CandidateCount) * 35.0;
                            EmitProgress(
                                progressQueue,
                                2,
                                "Fase 2/3: Hash parcial (16 KB)",
                                string.Format("Hash parcial {0:N0} / {1:N0} candidatos...", phase2Processed, phase1CandidateCount),
                                filesEnumerated,
                                phase1CandidateCount,
                                phase2Processed,
                                phase1CandidateCount,
                                pct);
                        }
                    }
                }
            }

            if (result.WasCancelled)
            {
                stopwatch.Stop();
                result.ElapsedMilliseconds = stopwatch.ElapsedMilliseconds;
                EmitProgress(progressQueue, -1, "Cancelado", "Escaneo cancelado durante la Fase 2.", filesEnumerated, phase1CandidateCount, phase2Processed, phase1CandidateCount, 0);
                return result;
            }

            List<List<FileCandidate>> phase2Groups = new List<List<FileCandidate>>();
            long phase2CandidateCount = 0;
            foreach (KeyValuePair<string, List<FileCandidate>> kv in partialBuckets)
            {
                if (kv.Value.Count >= 2)
                {
                    phase2Groups.Add(kv.Value);
                    phase2CandidateCount += kv.Value.Count;
                }
            }
            partialBuckets.Clear();
            seenHardLinkInodes.Clear();

            result.Phase2PartialGroups = phase2Groups.Count;
            result.Phase2Candidates = phase2CandidateCount;

            if (phase2CandidateCount == 0)
            {
                stopwatch.Stop();
                result.ElapsedMilliseconds = stopwatch.ElapsedMilliseconds;
                EmitProgress(progressQueue, 4, "Completado", "Todos los candidatos fueron descartados en Fase 2 (sin duplicados reales).", filesEnumerated, 0, 1, 1, 100.0);
                return result;
            }

            // =========================================================================
            // FASE 3: Hash SHA-256 completo solo sobre los candidatos reales
            // =========================================================================
            EmitProgress(
                progressQueue,
                3,
                "Fase 3/3: SHA-256 completo",
                string.Format("Calculando SHA-256 completo para {0:N0} candidatos reales...", phase2CandidateCount),
                filesEnumerated,
                phase2CandidateCount,
                0,
                phase2CandidateCount,
                60.0);

            Dictionary<string, List<FileCandidate>> fullBuckets = new Dictionary<string, List<FileCandidate>>(StringComparer.Ordinal);
            long phase3Processed = 0;
            byte[] fullBuffer = new byte[FullBufferBytes];

            using (SHA256 shaFull = SHA256.Create())
            {
                for (int g = 0; g < phase2Groups.Count; g++)
                {
                    if (controller != null && controller.IsCancelled)
                    {
                        result.WasCancelled = true;
                        break;
                    }

                    List<FileCandidate> group = phase2Groups[g];
                    for (int i = 0; i < group.Count; i++)
                    {
                        if (controller != null && controller.IsCancelled)
                        {
                            result.WasCancelled = true;
                            break;
                        }

                        FileCandidate item = group[i];
                        phase3Processed++;

                        try
                        {
                            string fHash = item.IsFullHashKnown
                                ? item.FullHash
                                : ComputeFullSha256(item.FullPath, shaFull, fullBuffer, controller);

                            if (fHash != null)
                            {
                                item.FullHash = fHash;
                                string key = item.SizeBytes.ToString() + ":" + fHash;
                                List<FileCandidate> fBucket;
                                if (!fullBuckets.TryGetValue(key, out fBucket))
                                {
                                    fBucket = new List<FileCandidate>();
                                    fullBuckets[key] = fBucket;
                                }
                                fBucket.Add(item);
                            }
                        }
                        catch
                        {
                            result.AccessErrors++;
                        }

                        long nowMs = stopwatch.ElapsedMilliseconds;
                        if (nowMs - lastReportTicks >= 100 || phase3Processed == phase2CandidateCount)
                        {
                            lastReportTicks = nowMs;
                            double pct = 60.0 + ((double)phase3Processed / (double)phase2CandidateCount) * 38.0;
                            EmitProgress(
                                progressQueue,
                                3,
                                "Fase 3/3: SHA-256 completo",
                                string.Format("SHA-256 completo {0:N0} / {1:N0}: {2}", phase3Processed, phase2CandidateCount, item.FileName),
                                filesEnumerated,
                                phase2CandidateCount,
                                phase3Processed,
                                phase2CandidateCount,
                                pct);
                        }
                    }
                }
            }

            if (result.WasCancelled)
            {
                stopwatch.Stop();
                result.ElapsedMilliseconds = stopwatch.ElapsedMilliseconds;
                EmitProgress(progressQueue, -1, "Cancelado", "Escaneo cancelado durante la Fase 3.", filesEnumerated, phase2CandidateCount, phase3Processed, phase2CandidateCount, 0);
                return result;
            }

            // Construir grupos finales ordenados por espacio recuperable descendente
            List<DuplicateGroup> finalGroups = new List<DuplicateGroup>();
            long totalDuplicateFiles = 0;
            long totalReclaimable = 0;

            foreach (KeyValuePair<string, List<FileCandidate>> kv in fullBuckets)
            {
                if (kv.Value.Count >= 2)
                {
                    List<FileCandidate> list = kv.Value;
                    list.Sort(delegate(FileCandidate a, FileCandidate b)
                    {
                        int cmp = a.LastWriteTime.CompareTo(b.LastWriteTime);
                        if (cmp != 0) return cmp;
                        return string.Compare(a.FullPath, b.FullPath, StringComparison.OrdinalIgnoreCase);
                    });

                    DuplicateGroup grp = new DuplicateGroup();
                    grp.Sha256 = list[0].FullHash;
                    grp.FileSizeBytes = list[0].SizeBytes;
                    grp.FileCount = list.Count;
                    grp.ReclaimableBytes = list[0].SizeBytes * (list.Count - 1);

                    for (int i = 0; i < list.Count; i++)
                    {
                        FileCandidate fc = list[i];
                        DuplicateFileEntry entry = new DuplicateFileEntry();
                        entry.FullPath = fc.FullPath;
                        entry.FileName = fc.FileName;
                        entry.DirectoryName = fc.DirectoryName;
                        entry.Extension = fc.Extension;
                        entry.SizeBytes = fc.SizeBytes;
                        entry.LastWriteTime = fc.LastWriteTime;
                        entry.CreationTime = fc.CreationTime;
                        entry.PartialHash = fc.PartialHash;
                        entry.FullHash = fc.FullHash;
                        grp.Files.Add(entry);
                    }

                    finalGroups.Add(grp);
                    totalDuplicateFiles += grp.FileCount;
                    totalReclaimable += grp.ReclaimableBytes;
                }
            }

            finalGroups.Sort(delegate(DuplicateGroup a, DuplicateGroup b)
            {
                return b.ReclaimableBytes.CompareTo(a.ReclaimableBytes);
            });

            for (int i = 0; i < finalGroups.Count; i++)
            {
                finalGroups[i].GroupId = i + 1;
            }

            result.Groups = finalGroups;
            result.DuplicateGroupCount = finalGroups.Count;
            result.TotalDuplicateFiles = totalDuplicateFiles;
            result.TotalReclaimableBytes = totalReclaimable;

            stopwatch.Stop();
            result.ElapsedMilliseconds = stopwatch.ElapsedMilliseconds;

            EmitProgress(
                progressQueue,
                4,
                "Completado",
                string.Format("Listo: {0:N0} grupos duplicados encontrados.", finalGroups.Count),
                filesEnumerated,
                phase2CandidateCount,
                phase3Processed,
                phase2CandidateCount,
                100.0);

            return result;
        }

        private static string ComputePartialSha256AndInode(string path, SHA256 sha, byte[] buffer, out string inodeKey)
        {
            inodeKey = null;
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                try
                {
                    inodeKey = NtfsNative.TryGetUniqueInodeKey(fs.SafeFileHandle);
                }
                catch
                {
                    inodeKey = null;
                }

                int totalRead = 0;
                while (totalRead < buffer.Length)
                {
                    int read = fs.Read(buffer, totalRead, buffer.Length - totalRead);
                    if (read <= 0) break;
                    totalRead += read;
                }
                byte[] hash = sha.ComputeHash(buffer, 0, totalRead);
                return ToHex(hash);
            }
        }

        private static string ComputeFullSha256(string path, SHA256 sha, byte[] buffer, ScanController controller)
        {
            sha.Initialize();
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, buffer.Length))
            {
                int bytesRead;
                while ((bytesRead = fs.Read(buffer, 0, buffer.Length)) > 0)
                {
                    if (controller != null && controller.IsCancelled)
                    {
                        return null;
                    }
                    sha.TransformBlock(buffer, 0, bytesRead, null, 0);
                }
                sha.TransformFinalBlock(new byte[0], 0, 0);
                return ToHex(sha.Hash);
            }
        }

        private static string ToHex(byte[] bytes)
        {
            StringBuilder sb = new StringBuilder(bytes.Length * 2);
            for (int i = 0; i < bytes.Length; i++)
            {
                sb.Append(bytes[i].ToString("x2"));
            }
            return sb.ToString();
        }

        private static HashSet<string> BuildLowerSet(string[] items)
        {
            HashSet<string> set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (items != null)
            {
                for (int i = 0; i < items.Length; i++)
                {
                    if (!string.IsNullOrEmpty(items[i]))
                    {
                        set.Add(items[i].Trim().ToLowerInvariant());
                    }
                }
            }
            return set;
        }

        private static string[] NormalizePrefixes(string[] prefixes)
        {
            if (prefixes == null || prefixes.Length == 0)
            {
                return new string[0];
            }

            List<string> list = new List<string>();
            for (int i = 0; i < prefixes.Length; i++)
            {
                if (!string.IsNullOrEmpty(prefixes[i]))
                {
                    string norm = Path.GetFullPath(prefixes[i]).TrimEnd('\\', '/');
                    list.Add(norm);
                }
            }
            return list.ToArray();
        }

        private static bool IsBlockedDirectory(string dirPath, string[] blockedPrefixes, HashSet<string> blockedFolderNames)
        {
            string normalized = Path.GetFullPath(dirPath).TrimEnd('\\', '/');
            for (int i = 0; i < blockedPrefixes.Length; i++)
            {
                string prefix = blockedPrefixes[i];
                if (string.Equals(normalized, prefix, StringComparison.OrdinalIgnoreCase) ||
                    normalized.StartsWith(prefix + "\\", StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            string folderName = Path.GetFileName(normalized);
            if (!string.IsNullOrEmpty(folderName) && blockedFolderNames.Contains(folderName))
            {
                return true;
            }

            return false;
        }

        private static void EmitProgress(
            ConcurrentQueue<ScanProgressEvent> queue,
            int phase,
            string phaseName,
            string message,
            long filesScanned,
            long candidatesCount,
            long completedSteps,
            long totalSteps,
            double percent)
        {
            if (queue == null) return;

            ScanProgressEvent evt = new ScanProgressEvent();
            evt.Phase = phase;
            evt.PhaseName = phaseName;
            evt.Message = message;
            evt.FilesScanned = filesScanned;
            evt.CandidatesCount = candidatesCount;
            evt.CompletedSteps = completedSteps;
            evt.TotalSteps = totalSteps;
            evt.Percent = percent;
            queue.Enqueue(evt);
        }
    }
}
