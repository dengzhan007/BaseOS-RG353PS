# RG353PS Mass Storage mode - Windows host side READ-ONLY verification.
#
# Run AFTER the operator has manually entered USB Mass Storage mode.
# Target selection is a STRICT PnP -> USBSTOR -> Win32_DiskDrive mapping. Two
# ownership paths are supported:
#   * partitioned: WMI disk -> partition -> logical disk -> volume
#   * superfloppy: Win32_Volume GUID -> read-only IOCTL_STORAGE_GET_DEVICE_NUMBER
#                  -> DeviceNumber == the confirmed PHYSICALDRIVE index
# The script never scans arbitrary USB disks, never guesses a volume by its
# filesystem, and never opens any file before ownership is proven.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\check-rg353ps-mass-storage.ps1
#
[CmdletBinding()]
param(
    [string]$RunId = '20261106-131355-4a3405',
    [int]$ProbeRetries = 3,
    [int]$ProbeIntervalSeconds = 5,
    [string]$TopologyMockPath = ''
)

$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Module = Join-Path $ScriptDir 'Rg353psDeviceMap.ps1'
if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
    Write-Host 'FAIL: Rg353psDeviceMap.ps1 is missing next to this script.' -ForegroundColor Red
    exit 1
}
. $Module

$ReportJson = Join-Path $ScriptDir 'mass-storage-host-report.json'
$ReportMd = Join-Path $ScriptDir 'mass-storage-host-report.md'
$StartedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$Checks = New-Object System.Collections.ArrayList
$Failures = New-Object System.Collections.ArrayList
$Evidence = [ordered]@{}

function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $entry = [ordered]@{ name = $Name; status = $(if ($Ok) { 'PASS' } else { 'FAIL' }); detail = $Detail }
    [void]$Checks.Add($entry)
    if (-not $Ok) { [void]$Failures.Add(($Name + ': ' + $Detail)) }
}

function Write-Reports {
    param([int]$ExitCode)
    $allPass = ($Failures.Count -eq 0)
    $report = [ordered]@{
        tool = 'rg353ps-mass-storage-readonly-check'
        run_id = $RunId
        started_utc = $StartedUtc
        finished_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        mode = 'USB Mass Storage (VID_2207&PID_0006)'
        read_only = $true
        device_selection = 'strict PnP parent/child + WMI disk/partition/volume, or volume GUID -> PHYSICALDRIVE via read-only IOCTL_STORAGE_GET_DEVICE_NUMBER'
        evidence = $Evidence
        checks = @($Checks)
        failures = @($Failures)
        pass = $allPass
    }
    $json = $report | ConvertTo-Json -Depth 10
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ReportJson, $json, $enc)
    $md = New-Object System.Collections.ArrayList
    [void]$md.Add('# RG353PS Mass Storage host read-only report')
    [void]$md.Add('')
    [void]$md.Add('- Run ID: `' + $RunId + '`')
    [void]$md.Add('- Overall: ' + $(if ($allPass) { '**PASS**' } else { '**FAIL**' }))
    [void]$md.Add('- Device selection: strict PnP/WMI mapping + IOCTL volume ownership; no fallback scanning')
    if ($Evidence.Contains('diagnostics')) {
        $d = $Evidence['diagnostics']
        [void]$md.Add('- Mapping path: `' + [string]$d['path'] + '`')
        [void]$md.Add('- PHYSICALDRIVE index: ' + $(if ($null -eq $d['target_disk_index']) { 'n/a' } else { [string]$d['target_disk_index'] }))
        [void]$md.Add('- IOCTL volume records: ' + @($d['ioctl_map']).Count + '; matched: ' + @($d['ioctl_matched_volumes']).Count + '; unresolved: ' + @($d['unresolved_ioctl_volumes']).Count)
        [void]$md.Add('- Partition associations: ' + @($d['partition_associations']).Count)
    }
    [void]$md.Add('')
    [void]$md.Add('| Check | Status | Detail |')
    [void]$md.Add('| --- | --- | --- |')
    foreach ($c in $Checks) {
        [void]$md.Add('| ' + $c.name + ' | ' + $c.status + ' | ' + ($c.detail -replace '\|', '/') + ' |')
    }
    [void]$md.Add('')
    if ($Failures.Count -gt 0) {
        [void]$md.Add('## Failure reasons')
        [void]$md.Add('')
        foreach ($f in $Failures) { [void]$md.Add('- ' + $f) }
    }
    [void]$md.Add('')
    [void]$md.Add('> Read-only observation. Ambiguous, RAW or unowned volumes are')
    [void]$md.Add('> never opened; a format prompt is an immediate hard stop.')
    [System.IO.File]::WriteAllText($ReportMd, (($md -join "`r`n") + "`r`n"), $enc)
}

function Get-FormatPrompt {
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowTitle -match 'format|格式化|You need to format'
    })
}

Write-Host '== RG353PS Mass Storage read-only check ==' -ForegroundColor Cyan
Write-Host ('Run ID: ' + $RunId)

# Format-prompt detection is only ONE layer. The structural safeguards are the
# strict device mapping, the RAW/unknown filesystem checks and the exact
# IOCTL volume ownership proof; those stop before any volume is accessed.
$prompt = Get-FormatPrompt
if ($prompt.Count -gt 0) {
    Add-Check 'no_format_prompt' $false 'Windows format prompt detected; stopping immediately'
    Write-Reports 1
    Write-Host 'STOP: a format prompt is open. Nothing was touched.' -ForegroundColor Red
    exit 1
}
Add-Check 'no_format_prompt' $true 'no Windows format prompt detected (additional guard)'

# ---- Finite wait for the target PnP identity ---------------------------------
$pnp = @()
$seen = $false
for ($i = 1; $i -le $ProbeRetries; $i++) {
    $pnp = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match 'VID_2207' } |
        Select-Object Name, PNPDeviceID, PNPClass, Status)
    $roots = @($pnp | Where-Object {
        $_.PNPDeviceID -match '^USB\\VID_2207&PID_0006\\' -and $_.PNPDeviceID -notmatch '&MI_'
    })
    if ($roots.Count -eq 1) { $seen = $true; break }
    Write-Host ('Probe ' + $i + '/' + $ProbeRetries + ': unique PID_0006 root not present.')
    if ($i -lt $ProbeRetries) { Start-Sleep -Seconds $ProbeIntervalSeconds }
}
$Evidence['vid2207_devices'] = @($pnp)
Add-Check 'pid_0006_root_unique' $seen ('unique VID_2207&PID_0006 roots=' + @($pnp | Where-Object {
    $_.PNPDeviceID -match '^USB\\VID_2207&PID_0006\\' -and $_.PNPDeviceID -notmatch '&MI_'
}).Count)

$pid9 = @($pnp | Where-Object { $_.PNPDeviceID -match 'VID_2207&PID_0009' })
$wpd = @($pnp | Where-Object { $_.PNPClass -eq 'WPD' -or $_.Name -match 'RG353PS' })
Add-Check 'mtp_pid_0009_absent' ($pid9.Count -eq 0) ('PID_0009 matches=' + $pid9.Count)
Add-Check 'wpd_mtp_absent' ($wpd.Count -eq 0) ('WPD RG353PS entries=' + $wpd.Count)
if (-not $seen) {
    Add-Check 'device_ready' $false 'unique PID_0006 identity did not appear within the finite probe window'
    Write-Reports 1
    Write-Host 'FAIL: device is not in Mass Storage mode (or not connected).' -ForegroundColor Red
    foreach ($p in $pnp) { Write-Host ('  ' + $p.Name + ' | ' + $p.PNPClass + ' | ' + $p.PNPDeviceID) }
    exit 1
}
Add-Check 'device_ready' $true 'unique PID_0006 identity present'

# ---- Strict topology mapping (no fallback to scanning all USB disks) --------
if ($TopologyMockPath) {
    $mock = Get-Content -LiteralPath $TopologyMockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $topo = [pscustomobject]@{
        PnpDevices = @($mock.PnpDevices); PnpChildren = @($mock.PnpChildren)
        Disks = @($mock.Disks); DiskPartitions = @($mock.DiskPartitions)
        Volumes = @($mock.Volumes)
    }
    $ioctlMap = @($mock.IoctlVolumes)
    $Evidence['topology_source'] = 'offline mock'
    $Evidence['ioctl_source'] = 'offline mock'
} else {
    $topo = Get-Rg353psLiveTopology
    $Evidence['topology_source'] = 'live CIM/PnP'
    try {
        $ioctlMap = @(Get-Rg353psIoctlVolumeMap -Volumes $topo.Volumes)
        $Evidence['ioctl_source'] = 'live read-only IOCTL_STORAGE_GET_DEVICE_NUMBER'
    } catch {
        $ioctlMap = @()
        $Evidence['ioctl_source'] = 'IOCTL collection failed: ' + $_.Exception.Message
        Add-Check 'ioctl_collection' $false ('read-only volume mapping unavailable: ' + $_.Exception.Message)
        Write-Reports 1
        Write-Host 'FAIL: cannot establish volume ownership; no file was read.' -ForegroundColor Red
        exit 1
    }
}

$Evidence['ioctl_candidate_count'] = @($ioctlMap).Count
$map = Resolve-Rg353psTarget -PnpDevices $topo.PnpDevices -PnpChildren $topo.PnpChildren `
    -Disks $topo.Disks -DiskPartitions $topo.DiskPartitions -Volumes $topo.Volumes `
    -IoctlVolumes $ioctlMap

$Evidence['mapping'] = [ordered]@{
    ok = $map.Ok; reason = $map.Reason; path = $map.Path
    checks = @($map.Checks)
    disk = $map.Disk; volume = $map.Volume
    all_partitions = @($map.Partitions)
}
$Evidence['diagnostics'] = $map.Diagnostics
Add-Check 'strict_device_mapping' $map.Ok ('[' + $map.Path + '] ' + $map.Reason)
if (-not $map.Ok) {
    Write-Reports 1
    Write-Host ('FAIL: ' + $map.Reason) -ForegroundColor Red
    exit 1
}
Add-Check 'topology_inspected' $true ('path=' + $map.Path + '; partitions=' + @($map.Partitions).Count + '; ioctl_records=' + @($map.Diagnostics['ioctl_map']).Count)
Add-Check 'no_raw_or_unknown_filesystem' $true ('all inspected partitions/volumes on path ' + $map.Path + ' have a known filesystem')
if ($map.Path -eq 'superfloppy') {
    $mv = @($map.Diagnostics['ioctl_matched_volumes'])
    Add-Check 'volume_ownership_confirmed' $true ('volume GUID ' + [string]$mv[0].VolumeGuidPath + ' -> PHYSICALDRIVE' + [string]$map.Diagnostics['target_disk_index'] + ' via IOCTL')
}

# ---- Use ONLY the uniquely mapped volume ------------------------------------
$drive = [string]$map.Volume.DriveLetter
if ([string]::IsNullOrEmpty($drive)) {
    Add-Check 'target_volume_has_drive_letter' $false 'mapped volume has no drive letter'
    Write-Reports 1
    exit 1
}
Add-Check 'target_volume_has_drive_letter' $true ('volume=' + $drive)
Add-Check 'exfat_volume_visible' ($map.Volume.FileSystem -match '^(exFAT|FAT32)$') ('filesystem=' + $map.Volume.FileSystem)

$datasetDir = $drive.TrimEnd('\') + '\baseos-mtp-test-' + $RunId
Add-Check 'dataset_dir_found' (Test-Path -LiteralPath $datasetDir -PathType Container) ('looked only on ' + $drive)
$Evidence['dataset_dir'] = $datasetDir
if (-not (Test-Path -LiteralPath $datasetDir -PathType Container)) {
    Write-Reports 1
    Write-Host 'FAIL: dataset directory not found on the uniquely mapped volume.' -ForegroundColor Red
    exit 1
}

$manifestPath = Join-Path $datasetDir 'baseos-mtp-test-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Add-Check 'manifest_present' $false ('missing ' + $manifestPath)
    Write-Reports 1
    exit 1
}
$man = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
Add-Check 'manifest_present' $true $manifestPath
$Evidence['manifest_origin'] = $man.origin
$Evidence['manifest_created_utc'] = $man.created_utc

$results = New-Object System.Collections.ArrayList
$sizeOk = 0
$hashOk = 0
$bigOk = $false
$unicodeOk = $false
$spaceOk = $false
$nestedOk = $false
foreach ($e in $man.files) {
    $rel = ($e.relpath -replace '/', '\')
    $p = Join-Path $datasetDir $rel
    $exists = Test-Path -LiteralPath $p -PathType Leaf
    $actualSize = 0
    $actualHash = ''
    $thisSize = $false
    $thisHash = $false
    if ($exists) {
        $item = Get-Item -LiteralPath $p
        $actualSize = $item.Length
        $thisSize = ($actualSize -eq [long]$e.size)
        if ($thisSize) {
            $actualHash = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower()
            $thisHash = ($actualHash -eq ([string]$e.sha256).ToLower())
        }
        if ($thisSize -and $e.relpath -match 'large-128m') { $bigOk = $true }
        if ($thisHash -and ($e.relpath -match '[^\x00-\x7F]')) { $unicodeOk = $true }
        if ($thisHash -and $e.relpath -match ' ') { $spaceOk = $true }
        if ($thisHash -and ($e.relpath -split '/').Count -ge 3) { $nestedOk = $true }
    }
    if ($thisSize) { $sizeOk++ }
    if ($thisHash) { $hashOk++ }
    [void]$results.Add([ordered]@{
        path = $e.relpath; expected_size = $e.size; actual_size = $actualSize
        size_ok = $thisSize; sha256_ok = $thisHash
        expected_sha256 = $e.sha256; actual_sha256 = $actualHash
    })
}
$total = @($man.files).Count
$Evidence['file_verification'] = @($results)
Add-Check 'seven_files_listed' ($total -eq 7) ('manifest entries=' + $total)
Add-Check 'all_sizes_match' ($sizeOk -eq $total) ($sizeOk.ToString() + '/' + $total + ' sizes match')
Add-Check 'all_sha256_match' ($hashOk -eq $total) ($hashOk.ToString() + '/' + $total + ' SHA-256 match')
Add-Check 'large_128mib_verified' $bigOk '128 MiB file sized 134217728 and hashed'
Add-Check 'unicode_name_verified' $unicodeOk 'Chinese filename read and hashed'
Add-Check 'space_name_verified' $spaceOk 'filename with spaces read and hashed'
Add-Check 'three_level_dir_verified' $nestedOk 'three-level directory read and hashed'

Write-Reports 0
Write-Host ('Reports: ' + $ReportJson) -ForegroundColor Cyan
Write-Host ('         ' + $ReportMd) -ForegroundColor Cyan
if ($Failures.Count -gt 0) {
    Write-Host ('FAIL (' + $Failures.Count + ' reasons):') -ForegroundColor Red
    foreach ($f in $Failures) { Write-Host ('  - ' + $f) -ForegroundColor Red }
    exit 1
}
Write-Host 'PASS: Mass Storage device identity and read-only dataset integrity verified.' -ForegroundColor Green
exit 0
