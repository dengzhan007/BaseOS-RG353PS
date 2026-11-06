# Pure, injectable device-topology resolver for the RG353PS Mass Storage check.
# No live hardware access in this file: the same code is exercised offline.
# Mapping chain: USB\VID_2207&PID_0006 -> PnP children (USBSTOR) ->
# Win32_DiskDrive -> Win32_DiskDriveToDiskPartition -> Win32_DiskPartition ->
# Win32_LogicalDiskToPartition -> Win32_Volume.

function New-Rg353psMapResult {
    param([bool]$Ok, [string]$Reason, $Disk, $Partitions, $Volume, $Checks)
    return [pscustomobject]@{
        Ok = $Ok; Reason = $Reason; Disk = $Disk
        Partitions = @($Partitions); Volume = $Volume; Checks = @($Checks)
    }
}

function Resolve-Rg353psTarget {
    param(
        [array]$PnpDevices = @(),
        [array]$PnpChildren = @(),
        [array]$Disks = @(),
        [array]$DiskPartitions = @(),
        [array]$Volumes = @()
    )
    $checks = New-Object System.Collections.ArrayList

    # 1. Exactly one composite VID_2207&PID_0006 root. Interface nodes (MI_xx)
    #    are children, not additional roots.
    $roots = @($PnpDevices | Where-Object {
        $_.PNPDeviceID -match '^USB\\VID_2207&PID_0006\\' -and $_.PNPDeviceID -notmatch '&MI_'
    })
    if ($roots.Count -ne 1) {
        return New-Rg353psMapResult $false ('expected exactly one VID_2207&PID_0006 root, found ' + $roots.Count) $null @() $null $checks
    }
    $root = $roots[0]
    [void]$checks.Add('unique_pnp_root')

    # 2. Explicit PnP parent -> child relation (DEVPKEY_Device_Children).
    #    No children means the device identity cannot be established.
    $kids = @($PnpChildren | Where-Object { $_.Parent -eq $root.PNPDeviceID } | ForEach-Object { $_.Child })
    if ($kids.Count -eq 0) {
        return New-Rg353psMapResult $false 'no PnP child for the target USB device; identity cannot be established' $null @() $null $checks
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
        return New-Rg353psMapResult $false ('child-to-disk mapping is not unique: ' + $unique.Count + ' candidates') $null @() $null $checks
    }
    $disk = $unique[0]
    if ($disk.PNPDeviceID -notmatch 'USBSTOR' -and $disk.InterfaceType -ne 'USB') {
        return New-Rg353psMapResult $false 'mapped disk is not a USB/USBSTOR disk' $null @() $null $checks
    }
    [void]$checks.Add('unique_usb_disk')

    # 4. Consider ONLY partitions owned by that disk.
    $parts = @($DiskPartitions | Where-Object { $_.DiskDeviceID -eq $disk.DeviceID })
    if ($parts.Count -eq 0) {
        return New-Rg353psMapResult $false 'no partition is associated with the mapped disk' $null @() $null $checks
    }
    [void]$checks.Add('disk_partitions_present')

    # 5. Inspect EVERY partition, including ones without a drive letter.
    #    A RAW/unknown filesystem is an anomaly even when Windows assigned no
    #    letter, and is a hard stop before any volume is opened.
    $raw = @($parts | Where-Object {
        [string]::IsNullOrEmpty($_.FileSystem) -or $_.FileSystem -match 'RAW|Unknown|未知'
    })
    if ($raw.Count -gt 0) {
        return New-Rg353psMapResult $false ('RAW/unknown filesystem on ' + $raw.Count + ' partition(s); stopping before volume access') $disk $parts $null $checks
    }
    $noLetter = @($parts | Where-Object { [string]::IsNullOrEmpty($_.DriveLetter) })
    [void]$checks.Add('no_driveletter_partitions=' + $noLetter.Count)

    # 6. Exactly one accessible exFAT/FAT32 volume on THAT disk.
    $usable = @($parts | Where-Object {
        -not [string]::IsNullOrEmpty($_.DriveLetter) -and $_.FileSystem -match '^(exFAT|FAT32)$'
    })
    if ($usable.Count -ne 1) {
        return New-Rg353psMapResult $false ('expected exactly one accessible exFAT/FAT32 volume on the target disk, found ' + $usable.Count) $disk $parts $null $checks
    }
    $vols = @($Volumes | Where-Object { $_.DriveLetter -eq $usable[0].DriveLetter })
    if ($vols.Count -ne 1) {
        return New-Rg353psMapResult $false 'volume metadata for the target partition is not unique' $disk $parts $null $checks
    }
    [void]$checks.Add('unique_target_volume')

    return New-Rg353psMapResult $true 'unique PnP -> USBSTOR -> disk -> partition -> volume mapping' $disk $parts $vols[0] $checks
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
