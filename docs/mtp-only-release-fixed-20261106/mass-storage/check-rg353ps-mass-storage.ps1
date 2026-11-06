# RG353PS Mass Storage mode - Windows host side READ-ONLY verification.
#
# Preparation only. Run this AFTER the operator has manually entered USB Mass
# Storage mode on the handheld. This script performs metadata reads and file
# hashing only; it never initialises, formats, repairs, mounts, renames,
# changes drive letters, writes to the device, or deletes anything.
# It does not use SSH (the MTP-only Release image has no SSH).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\check-rg353ps-mass-storage.ps1
#
[CmdletBinding()]
param(
    [string]$RunId = '20261106-131355-4a3405',
    [int]$ProbeRetries = 3,
    [int]$ProbeIntervalSeconds = 5
)

$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
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

# A Windows format prompt means the volume was not recognised. Stop at once
# rather than letting any further enumeration touch an unreadable volume.
function Get-FormatPrompt {
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowTitle -match 'format|格式化|You need to format'
    })
}

function Write-Reports {
    param([int]$ExitCode)
    $allPass = ($Failures.Count -eq 0)
    $report = [ordered]@{
        tool = 'rg353ps-mass-storage-readonly-check'
        run_id = $RunId
        started_utc = $StartedUtc
        finished_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        mode = 'USB Mass Storage (PID_0006)'
        read_only = $true
        evidence = $Evidence
        checks = @($Checks)
        failures = @($Failures)
        pass = $allPass
    }
    $json = $report | ConvertTo-Json -Depth 8
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ReportJson, $json, $enc)

    $md = New-Object System.Collections.ArrayList
    [void]$md.Add('# RG353PS Mass Storage host read-only report')
    [void]$md.Add('')
    [void]$md.Add('- Run ID: `' + $RunId + '`')
    [void]$md.Add('- Started: ' + $StartedUtc)
    [void]$md.Add('- Overall: ' + $(if ($allPass) { '**PASS**' } else { '**FAIL**' }))
    [void]$md.Add('- Read-only: no device write, no format, no repair, no drive-letter change, no SSH')
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
    [void]$md.Add('> Host-side read-only observation. If a format prompt appeared,')
    [void]$md.Add('> the script stopped without touching the volume.')
    [System.IO.File]::WriteAllText($ReportMd, (($md -join "`r`n") + "`r`n"), $enc)
}

Write-Host '== RG353PS Mass Storage read-only check ==' -ForegroundColor Cyan
Write-Host ('Run ID: ' + $RunId)

# ---- Finite wait for PID_0006 ------------------------------------------------
$pnp = @()
$seen = $false
for ($i = 1; $i -le $ProbeRetries; $i++) {
    $prompt = Get-FormatPrompt
    if ($prompt.Count -gt 0) {
        Add-Check 'no_format_prompt' $false 'Windows format prompt detected; stopping immediately'
        Write-Reports 1
        Write-Host 'STOP: a Windows format prompt is open. Nothing was touched.' -ForegroundColor Red
        exit 1
    }
    $pnp = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match 'VID_2207' } |
        Select-Object Name, PNPDeviceID, PNPClass, Status)
    $pid6 = @($pnp | Where-Object { $_.PNPDeviceID -match 'VID_2207&PID_0006' })
    if ($pid6.Count -gt 0) { $seen = $true; break }
    Write-Host ('Probe ' + $i + '/' + $ProbeRetries + ': PID_0006 not present yet.')
    if ($i -lt $ProbeRetries) { Start-Sleep -Seconds $ProbeIntervalSeconds }
}
Add-Check 'no_format_prompt' $true 'no Windows format prompt detected'
$Evidence['vid2207_devices'] = @($pnp)

$pid6 = @($pnp | Where-Object { $_.PNPDeviceID -match 'VID_2207&PID_0006' })
$pid9 = @($pnp | Where-Object { $_.PNPDeviceID -match 'VID_2207&PID_0009' })
$wpd = @($pnp | Where-Object { $_.PNPClass -eq 'WPD' -or $_.Name -match 'RG353PS' })
Add-Check 'pid_0006_present' ($pid6.Count -gt 0) ('VID_2207&PID_0006 matches=' + $pid6.Count)
Add-Check 'mtp_pid_0009_absent' ($pid9.Count -eq 0) ('PID_0009 matches=' + $pid9.Count)
Add-Check 'wpd_mtp_absent' ($wpd.Count -eq 0) ('WPD RG353PS entries=' + $wpd.Count)

if (-not $seen) {
    Add-Check 'device_ready' $false 'PID_0006 did not appear within the finite probe window; see vid2207_devices'
    Write-Reports 1
    Write-Host 'FAIL: device is not in Mass Storage mode (or not connected).' -ForegroundColor Red
    foreach ($p in $pnp) { Write-Host ('  ' + $p.Name + ' | ' + $p.PNPClass + ' | ' + $p.PNPDeviceID) }
    exit 1
}
Add-Check 'device_ready' $true 'PID_0006 device present'

# ---- Disk / partition / volume metadata (read-only) -------------------------
$disks = @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
    Where-Object { $_.PNPDeviceID -match 'VID_2207' -or $_.InterfaceType -eq 'USB' } |
    Select-Object Index, Model, InterfaceType, PNPDeviceID, Size, Partitions)
$Evidence['usb_disks'] = @($disks)
Add-Check 'usb_disk_detected' ($disks.Count -gt 0) ('candidate USB disks=' + $disks.Count)

$volumes = @(Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue |
    Where-Object { $_.DriveLetter } |
    Select-Object DriveLetter, FileSystem, Label, Capacity, FreeSpace, DeviceID)
$Evidence['volumes'] = @($volumes)

$rawVolumes = @($volumes | Where-Object { [string]::IsNullOrEmpty($_.FileSystem) })
if ($rawVolumes.Count -gt 0) {
    Add-Check 'no_unrecognised_volume' $false 'a volume has no filesystem - Windows may offer to format it; stopping'
    Write-Reports 1
    Write-Host 'STOP: a volume without a filesystem was detected.' -ForegroundColor Red
    exit 1
}
Add-Check 'no_unrecognised_volume' $true 'no RAW/unformatted volume'

$exfat = @($volumes | Where-Object { $_.FileSystem -match 'exFAT|FAT32' })
Add-Check 'exfat_volume_visible' ($exfat.Count -gt 0) ('exFAT/FAT32 volumes=' + $exfat.Count)
$Evidence['candidate_volumes'] = @($exfat)

# ---- Locate the existing 7-file dataset and verify (read-only) ---------------
$datasetDir = ''
foreach ($v in $exfat) {
    $candidate = ($v.DriveLetter.TrimEnd('\') + '\baseos-mtp-test-' + $RunId)
    if (Test-Path -LiteralPath $candidate -PathType Container) { $datasetDir = $candidate; break }
}
Add-Check 'dataset_dir_found' ($datasetDir -ne '') ('looked for baseos-mtp-test-' + $RunId)
$Evidence['dataset_dir'] = $datasetDir
if ($datasetDir -eq '') {
    Write-Reports 1
    Write-Host 'FAIL: dataset directory not found on any exFAT volume.' -ForegroundColor Red
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
Write-Host 'PASS: Mass Storage enumeration and read-only dataset integrity verified.' -ForegroundColor Green
exit 0
