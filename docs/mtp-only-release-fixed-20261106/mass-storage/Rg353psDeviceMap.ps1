# Pure, injectable device-topology resolver for the RG353PS Mass Storage check.
# No live hardware access is performed by Resolve-Rg353psTarget; the same code
# is exercised offline. The C# IOCTL helper below is only compiled when
# Get-Rg353psIoctlVolumeMap is actually called (a real host run).
#
# Mapping chain:
#   USB\VID_2207&PID_0006 -> PnP children (USBSTOR) -> Win32_DiskDrive
#   -> [partitioned] Win32_DiskDriveToDiskPartition -> Win32_DiskPartition
#                    -> Win32_LogicalDiskToPartition -> Win32_Volume
#   -> [superfloppy] Win32_Volume GUID -> IOCTL_STORAGE_GET_DEVICE_NUMBER
#                    -> DeviceNumber == the confirmed PHYSICALDRIVE index
#
# baseos-usb-storage exposes the mounted partition /dev/mmcblk0pN directly as
# the mass_storage LUN, so Windows may see a partitionless exFAT whole-disk
# volume ("superfloppy"). In that case WMI returns no partition association and
# the volume GUID -> physical drive number IOCTL is the ONLY exact ownership
# proof. We never scan arbitrary USB disks and never guess by filesystem type.

$script:Rg353psIoctlSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Rg353psStorageIoctl
{
    [StructLayout(LayoutKind.Sequential)]
    public struct STORAGE_DEVICE_NUMBER
    {
        public uint DeviceType;
        public uint DeviceNumber;
        public uint PartitionNumber;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(string lpFileName, uint dwDesiredAccess,
        uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode,
        IntPtr lpInBuffer, uint nInBufferSize, IntPtr lpOutBuffer, uint nOutBufferSize,
        out uint lpBytesReturned, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetVolumeNameForVolumeMountPoint(string lpszVolumeMountPoint,
        StringBuilder lpszVolumeName, uint cchBufferLength);

    private const uint IOCTL_STORAGE_GET_DEVICE_NUMBER = 0x002D1080;

    public static string GuidForDriveLetter(string letter)
    {
        if (string.IsNullOrEmpty(letter)) return "";
        StringBuilder sb = new StringBuilder(512);
        string mp = letter.EndsWith("\\") ? letter : letter + "\\";
        if (!GetVolumeNameForVolumeMountPoint(mp, sb, (uint)sb.Capacity)) return "";
        return sb.ToString();
    }

    // dwDesiredAccess = 0: metadata-only handle, no read/write access requested.
    // share = FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE = 7.
    // OPEN_EXISTING = 3. Only the read-only storage-device-number IOCTL is sent.
    // Returns "DeviceNumber,PartitionNumber,DeviceType" or "" on failure.
    public static string Query(string volumeGuidPath)
    {
        if (string.IsNullOrEmpty(volumeGuidPath)) return "";
        string path = volumeGuidPath.TrimEnd('\\');
        IntPtr h = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h == IntPtr.Zero || h.ToInt64() == -1) return "";
        try
        {
            int sz = Marshal.SizeOf(typeof(STORAGE_DEVICE_NUMBER));
            IntPtr buf = Marshal.AllocHGlobal(sz);
            try
            {
                uint ret = 0;
                bool ok = DeviceIoControl(h, IOCTL_STORAGE_GET_DEVICE_NUMBER,
                    IntPtr.Zero, 0, buf, (uint)sz, out ret, IntPtr.Zero);
                if (!ok || ret < (uint)sz) return "";
                STORAGE_DEVICE_NUMBER n = (STORAGE_DEVICE_NUMBER)Marshal.PtrToStructure(
                    buf, typeof(STORAGE_DEVICE_NUMBER));
                return n.DeviceNumber + "," + n.PartitionNumber + "," + n.DeviceType;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }
        finally { CloseHandle(h); }
    }
}
'@

function New-Rg353psMapResult {
    param([bool]$Ok, [string]$Reason, $Disk, $Partitions, $Volume, $Checks,
          [string]$Path = '', $Diagnostics = $null)
    if ($null -eq $Diagnostics) { $Diagnostics = [ordered]@{} }
    $Diagnostics['path'] = $Path
    $Diagnostics['target_disk'] = $Disk
    $Diagnostics['partition_associations'] = @($Partitions)
    return [pscustomobject]@{
        Ok = $Ok; Reason = $Reason; Disk = $Disk
        Partitions = @($Partitions); Volume = $Volume; Checks = @($Checks)
        Path = $Path; Diagnostics = $Diagnostics
    }
}

function Resolve-Rg353psTarget {
    param(
        [array]$PnpDevices = @(),
        [array]$PnpChildren = @(),
        [array]$Disks = @(),
        [array]$DiskPartitions = @(),
        [array]$Volumes = @(),
        [array]$IoctlVolumes = @()
    )
    $checks = New-Object System.Collections.ArrayList
    $diag = [ordered]@{
        path = 'unknown'
        target_disk = $null
        target_disk_index = $null
        partition_associations = @()
        volumes = @($Volumes)
        ioctl_map = @($IoctlVolumes)
        ioctl_matched_volumes = @()
        unresolved_ioctl_volumes = @()
    }

    # 1. Exactly one composite VID_2207&PID_0006 root. Interface nodes (MI_xx)
    #    are children, not additional roots.
    $roots = @($PnpDevices | Where-Object {
        $_.PNPDeviceID -match '^USB\\VID_2207&PID_0006\\' -and $_.PNPDeviceID -notmatch '&MI_'
    })
    if ($roots.Count -ne 1) {
        return New-Rg353psMapResult $false ('expected exactly one VID_2207&PID_0006 root, found ' + $roots.Count) $null @() $null $checks 'identity_failed' $diag
    }
    $root = $roots[0]
    [void]$checks.Add('unique_pnp_root')

    # 2. Explicit PnP parent -> child relation (DEVPKEY_Device_Children).
    $kids = @($PnpChildren | Where-Object { $_.Parent -eq $root.PNPDeviceID } | ForEach-Object { $_.Child })
    if ($kids.Count -eq 0) {
        return New-Rg353psMapResult $false 'no PnP child for the target USB device; identity cannot be established' $null @() $null $checks 'identity_failed' $diag
    }
    [void]$checks.Add('pnp_children_present')

    # 3. Child instance IDs must resolve to exactly one physical disk.
    #    NEVER fall back to "all USB disks" or "all exFAT volumes".
    $candidates = New-Object System.Collections.ArrayList
    foreach ($k in $kids) {
        foreach ($d in $Disks) {
            if ($d.PNPDeviceID -and ($d.PNPDeviceID -eq $k -or $d.PNPDeviceID.StartsWith($k))) {
                [void]$candidates.Add($d)
            }
        }
    }
    $unique = @($candidates | Sort-Object -Property DeviceID -Unique)
    if ($unique.Count -ne 1) {
        return New-Rg353psMapResult $false ('child-to-disk mapping is not unique: ' + $unique.Count + ' candidates') $null @() $null $checks 'identity_failed' $diag
    }
    $disk = $unique[0]
    if ($disk.PNPDeviceID -notmatch 'USBSTOR' -and $disk.InterfaceType -ne 'USB') {
        return New-Rg353psMapResult $false 'mapped disk is not a USB/USBSTOR disk' $null @() $null $checks 'identity_failed' $diag
    }
    $diag.target_disk = $disk
    [void]$checks.Add('unique_usb_disk')

    # 4. Consider ONLY partitions owned by that disk.
    $parts = @($DiskPartitions | Where-Object { $_.DiskDeviceID -eq $disk.DeviceID })
    $diag.partition_associations = @($parts)

    if ($parts.Count -gt 0) {
        # ---- Partitioned path: original strict WMI association chain --------
        [void]$checks.Add('disk_partitions_present')
        $raw = @($parts | Where-Object {
            [string]::IsNullOrEmpty($_.FileSystem) -or $_.FileSystem -match 'RAW|Unknown|未知'
        })
        if ($raw.Count -gt 0) {
            return New-Rg353psMapResult $false ('RAW/unknown filesystem on ' + $raw.Count + ' partition(s); stopping before volume access') $disk $parts $null $checks 'partitioned' $diag
        }
        $noLetter = @($parts | Where-Object { [string]::IsNullOrEmpty($_.DriveLetter) })
        [void]$checks.Add('no_driveletter_partitions=' + $noLetter.Count)
        $usable = @($parts | Where-Object {
            -not [string]::IsNullOrEmpty($_.DriveLetter) -and $_.FileSystem -match '^(exFAT|FAT32)$'
        })
        if ($usable.Count -ne 1) {
            return New-Rg353psMapResult $false ('expected exactly one accessible exFAT/FAT32 volume on the target disk, found ' + $usable.Count) $disk $parts $null $checks 'partitioned' $diag
        }
        $vols = @($Volumes | Where-Object { $_.DriveLetter -eq $usable[0].DriveLetter })
        if ($vols.Count -ne 1) {
            return New-Rg353psMapResult $false 'volume metadata for the target partition is not unique' $disk $parts $null $checks 'partitioned' $diag
        }
        [void]$checks.Add('unique_target_volume')
        return New-Rg353psMapResult $true 'unique PnP -> USBSTOR -> disk -> partition -> volume mapping' $disk $parts $vols[0] $checks 'partitioned' $diag
    }

    # ---- Superfloppy path: no partition table on the exported LUN -----------
    # Ownership is proven ONLY by IOCTL_STORAGE_GET_DEVICE_NUMBER mapping a
    # volume GUID to this exact physical drive. No filesystem-based guessing.
    $diag.path = 'superfloppy'
    [void]$checks.Add('no_partition_table_superfloppy_path')

    $idx = $null
    if (($disk.PSObject.Properties.Name -contains 'Index') -and $null -ne $disk.Index) {
        try { $idx = [int]$disk.Index } catch { $idx = $null }
    }
    if ($null -eq $idx -and ([string]$disk.DeviceID) -match 'PHYSICALDRIVE(\d+)') {
        $idx = [int]$Matches[1]
    }
    if ($null -eq $idx) {
        return New-Rg353psMapResult $false 'cannot determine the PHYSICALDRIVE number of the confirmed disk; volume ownership cannot be proven' $disk @() $null $checks 'superfloppy' $diag
    }
    $diag.target_disk_index = $idx
    [void]$checks.Add('physicaldrive_index=' + $idx)

    # An unresolved volume GUID could belong to this disk and would break the
    # uniqueness claim. Fail closed; do not try other disks.
    $unresolved = @($IoctlVolumes | Where-Object { -not $_.IoctlOk })
    $diag.unresolved_ioctl_volumes = @($unresolved)
    if ($unresolved.Count -gt 0) {
        return New-Rg353psMapResult $false ('IOCTL could not resolve ' + $unresolved.Count + ' volume GUID(s); device ownership cannot be confirmed') $disk @() $null $checks 'superfloppy' $diag
    }

    # Exact match: DeviceNumber from the volume GUID must equal the confirmed
    # physical drive number. Volumes on any other USB disk are simply not ours.
    $matched = @($IoctlVolumes | Where-Object {
        $_.IoctlOk -and $null -ne $_.DeviceNumber -and ([int]$_.DeviceNumber -eq $idx)
    })
    $diag.ioctl_matched_volumes = @($matched)
    if ($matched.Count -ne 1) {
        return New-Rg353psMapResult $false ('expected exactly one volume GUID mapped to PHYSICALDRIVE' + $idx + ' via IOCTL, found ' + $matched.Count) $disk @() $null $checks 'superfloppy' $diag
    }
    $rec = $matched[0]
    [void]$checks.Add('unique_ioctl_volume_guid')

    # Uniquely identifiable WMI volume metadata for THAT GUID.
    $guid = ([string]$rec.VolumeGuidPath).TrimEnd('\')
    $meta = @($Volumes | Where-Object {
        $_.DeviceID -and ([string]$_.DeviceID).TrimEnd('\') -eq $guid
    })
    if ($meta.Count -eq 0 -and -not [string]::IsNullOrEmpty([string]$rec.DriveLetter)) {
        $meta = @($Volumes | Where-Object {
            $_.DriveLetter -and ([string]$_.DriveLetter) -eq ([string]$rec.DriveLetter)
        })
    }
    if ($meta.Count -ne 1) {
        return New-Rg353psMapResult $false 'WMI volume metadata for the IOCTL-mapped GUID is not unique' $disk @() $null $checks 'superfloppy' $diag
    }
    $vol = $meta[0]

    $fs = [string]$rec.FileSystem
    if ([string]::IsNullOrEmpty($fs)) { $fs = [string]$vol.FileSystem }
    if ([string]::IsNullOrEmpty($fs) -or $fs -match 'RAW|Unknown|未知') {
        return New-Rg353psMapResult $false ('RAW/unknown filesystem on the IOCTL-mapped volume; stopping before file access') $disk @() $null $checks 'superfloppy' $diag
    }
    if ($fs -notmatch '^(exFAT|FAT32)$') {
        return New-Rg353psMapResult $false ('target volume filesystem is ' + $fs + ', expected exFAT/FAT32') $disk @() $null $checks 'superfloppy' $diag
    }

    $drive = [string]$vol.DriveLetter
    if ([string]::IsNullOrEmpty($drive)) { $drive = [string]$rec.DriveLetter }
    if ([string]::IsNullOrEmpty($drive)) {
        return New-Rg353psMapResult $false 'IOCTL-mapped superfloppy volume has no drive letter; no file will be read' $disk @() $null $checks 'superfloppy' $diag
    }
    [void]$checks.Add('unique_superfloppy_volume')

    return New-Rg353psMapResult $true ('unique PnP -> USBSTOR -> PHYSICALDRIVE' + $idx + ' -> IOCTL volume GUID mapping') $disk @() $vol $checks 'superfloppy' $diag
}

function Get-Rg353psIoctlVolumeMap {
    # REAL HOST ONLY. Opens each Win32_Volume GUID with zero desired access and
    # queries IOCTL_STORAGE_GET_DEVICE_NUMBER. Nothing is written, repaired,
    # formatted, mounted or assigned. Offline tests never call this function.
    param([array]$Volumes = @())

    if (-not ('Rg353psStorageIoctl' -as [type])) {
        Add-Type -TypeDefinition $script:Rg353psIoctlSource -Language CSharp -ErrorAction Stop
    }

    $guids = New-Object System.Collections.ArrayList
    foreach ($v in @($Volumes)) {
        $dev = [string]$v.DeviceID
        $g = ''
        if ($dev.StartsWith('\\?\Volume{')) { $g = $dev.TrimEnd('\') }
        if ([string]::IsNullOrEmpty($g) -and $v.DriveLetter) {
            $g = ([string][Rg353psStorageIoctl]::GuidForDriveLetter([string]$v.DriveLetter)).TrimEnd('\')
        }
        if (-not [string]::IsNullOrEmpty($g)) { [void]$guids.Add($g) }
    }

    $records = New-Object System.Collections.ArrayList
    foreach ($g in @($guids | Sort-Object -Unique)) {
        $q = ''
        $err = ''
        try { $q = [string][Rg353psStorageIoctl]::Query($g) }
        catch { $err = $_.Exception.Message }
        $meta = @($Volumes | Where-Object {
            $_.DeviceID -and ([string]$_.DeviceID).TrimEnd('\') -eq $g
        })
        $rec = [ordered]@{
            VolumeGuidPath = $g
            IoctlOk = $false
            DeviceNumber = $null
            PartitionNumber = $null
            DeviceType = $null
            Error = ''
            DriveLetter = $(if ($meta.Count -gt 0) { [string]$meta[0].DriveLetter } else { '' })
            FileSystem = $(if ($meta.Count -gt 0) { [string]$meta[0].FileSystem } else { '' })
            WmiDeviceID = $(if ($meta.Count -gt 0) { [string]$meta[0].DeviceID } else { '' })
            WmiMetadataUnique = ($meta.Count -eq 1)
        }
        if ($q) {
            $bits = $q.Split(',')
            if ($bits.Count -ge 3) {
                $rec.IoctlOk = $true
                $rec.DeviceNumber = [int]$bits[0]
                $rec.PartitionNumber = [int]$bits[1]
                $rec.DeviceType = [int]$bits[2]
            } else {
                $rec.Error = 'malformed IOCTL result'
            }
        } else {
            $rec.Error = $(if ($err) { $err } else { 'IOCTL_STORAGE_GET_DEVICE_NUMBER failed with a zero-access handle' })
        }
        [void]$records.Add([pscustomobject]$rec)
    }
    return @($records)
}

function Get-Rg353psLiveTopology {
    $pnp = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match 'VID_2207' } |
        Select-Object PNPDeviceID, Name, PNPClass, Status)

    $children = New-Object System.Collections.ArrayList
    $roots = @($pnp | Where-Object {
        $_.PNPDeviceID -match '^USB\\VID_2207&PID_0006\\' -and $_.PNPDeviceID -notmatch '&MI_'
    })
    foreach ($r in $roots) {
        try {
            $prop = Get-PnpDeviceProperty -InstanceId $r.PNPDeviceID -KeyName 'DEVPKEY_Device_Children' -ErrorAction Stop
            foreach ($c in @($prop.Data)) {
                [void]$children.Add([pscustomobject]@{ Parent = $r.PNPDeviceID; Child = [string]$c })
            }
        } catch { }
    }

    $disks = @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
        Select-Object DeviceID, PNPDeviceID, Index, Model, InterfaceType, Size)
    $d2p = @(Get-CimInstance Win32_DiskDriveToDiskPartition -ErrorAction SilentlyContinue)
    $parts = @(Get-CimInstance Win32_DiskPartition -ErrorAction SilentlyContinue)
    $l2p = @(Get-CimInstance Win32_LogicalDiskToPartition -ErrorAction SilentlyContinue)
    $vols = @(Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue |
        Select-Object DeviceID, DriveLetter, FileSystem, Capacity, FreeSpace, Label)

    $diskOf = @{}
    foreach ($rel in $d2p) {
        $a = [regex]::Match([string]$rel.Antecedent, 'DeviceID="([^"]+)"').Groups[1].Value
        $b = [regex]::Match([string]$rel.Dependent, 'DeviceID="([^"]+)"').Groups[1].Value
        if ($a -and $b) { $diskOf[$b] = $a }
    }
    $letterOf = @{}
    foreach ($rel in $l2p) {
        $a = [regex]::Match([string]$rel.Antecedent, 'DeviceID="([^"]+)"').Groups[1].Value
        $b = [regex]::Match([string]$rel.Dependent, 'DeviceID="([^"]+)"').Groups[1].Value
        if ($a -and $b) { $letterOf[$a] = $b }
    }

    $diskParts = New-Object System.Collections.ArrayList
    foreach ($p in $parts) {
        $did = ''
        if ($diskOf.ContainsKey($p.DeviceID)) { $did = $diskOf[$p.DeviceID] }
        $dl = ''
        if ($letterOf.ContainsKey($p.DeviceID)) { $dl = $letterOf[$p.DeviceID] }
        $fs = [string]$p.FileSystem
        if ([string]::IsNullOrEmpty($fs) -and $dl) {
            $v = @($vols | Where-Object { $_.DriveLetter -eq $dl } | Select-Object -First 1)
            if ($v.Count -gt 0) { $fs = [string]$v[0].FileSystem }
        }
        [void]$diskParts.Add([pscustomobject]@{
            DiskDeviceID = $did; DeviceID = $p.DeviceID; DriveLetter = $dl
            FileSystem = $fs; Size = $p.Size; Type = $p.Type
        })
    }
    return [pscustomobject]@{
        PnpDevices = @($pnp); PnpChildren = @($children); Disks = @($disks)
        DiskPartitions = @($diskParts); Volumes = @($vols)
    }
}
