# RG353PS Mass Storage - Windows host READ-ONLY long-run stability check.
#
# Run AFTER the operator has manually entered USB Mass Storage mode and the
# one-shot read-only check has passed. This script only observes:
#
#   * every PollIntervalSeconds (default 10 s) it re-runs the SAME strict
#     identity chain as check-rg353ps-mass-storage.ps1, by dot-sourcing
#     Rg353psDeviceMap.ps1:
#       USB\VID_2207&PID_0006 (unique root) -> PnP child (USBSTOR)
#       -> Win32_DiskDrive (exactly one) -> partition chain, or
#       -> Win32_Volume GUID -> read-only IOCTL_STORAGE_GET_DEVICE_NUMBER
#     It never scans other USB disks and never guesses a volume by filesystem.
#   * every HashIntervalMinutes (default 5 min) it re-reads the 128 MiB test
#     file and re-verifies its size and SHA-256 against the device manifest.
#
# The run stops at the FIRST anomaly (device gone, volume gone, mapping changed
# or now ambiguous, RAW filesystem, read failure, format prompt) and keeps the
# raw evidence in the reports. It never writes to the device, never formats,
# never repairs, never changes a drive letter and never disconnects anything.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\check-rg353ps-mass-storage-stability.ps1
#
[CmdletBinding()]
param(
    [string]$RunId = '20261106-131355-4a3405',
    [double]$DurationMinutes = 30,
    [int]$PollIntervalSeconds = 10,
    [int]$HashIntervalMinutes = 5,
    [int]$InitialWaitSeconds = 60,
    [string]$TestFileRelPath = '',
    [string]$ExpectedSha256 = '',
    [long]$ExpectedSize = -1,
    [string]$OutDir = '',
    [string]$ReportBaseName = 'mass-storage-stability-report'
)

$ErrorActionPreference = 'Continue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# $PSScriptRoot is not reliable inside a param() default under -File on
# Windows PowerShell 5.1, so resolve the default output directory here.
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = $ScriptDir }
$Module = Join-Path $ScriptDir 'Rg353psDeviceMap.ps1'
if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
    Write-Host 'FAIL: Rg353psDeviceMap.ps1 is missing next to this script.' -ForegroundColor Red
    exit 1
}
. $Module

function Get-Rg353psStabilityFormatPrompt {
    # ASCII-only source: the Chinese word for "format" is composed from code
    # points so this file stays byte-clean for Windows PowerShell 5.1, which
    # reads .ps1 files as ANSI unless they carry a BOM.
    $cnFormat = [string]([char]0x683C) + [string]([char]0x5F0F) + [string]([char]0x5316)
    $pattern = 'format|You need to format|' + $cnFormat
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowTitle -match $pattern
    })
}

function Get-Rg353psStabilityFingerprint {
    # Only fields that must stay identical for the whole run. Free space is
    # deliberately excluded: it can change without any identity change.
    param($Map)

    $diskIndex = $null
    if ($Map.Diagnostics -is [System.Collections.IDictionary]) {
        if ($Map.Diagnostics.Contains('target_disk_index')) {
            $diskIndex = $Map.Diagnostics['target_disk_index']
        }
    }
    $disk = $Map.Disk
    $vol = $Map.Volume
    return [ordered]@{
        path            = [string]$Map.Path
        disk_device_id  = [string]$disk.DeviceID
        disk_index      = $(if ($null -eq $diskIndex) { '' } else { [string]$diskIndex })
        volume_device_id = [string]$vol.DeviceID
        drive_letter    = [string]$vol.DriveLetter
        filesystem      = [string]$vol.FileSystem
        capacity        = [string]$vol.Capacity
    }
}

function Compare-Rg353psStabilityIdentity {
    # Returns one entry per changed field; empty array means identity is stable.
    param($Baseline, $Current)

    $changes = New-Object System.Collections.ArrayList
    if ($null -eq $Baseline) { return @() }
    foreach ($key in $Baseline.Keys) {
        $before = [string]$Baseline[$key]
        $after = ''
        if ($Current.Contains($key)) { $after = [string]$Current[$key] }
        if ($before -ne $after) {
            [void]$changes.Add([ordered]@{
                field  = [string]$key
                before = $before
                after  = $after
            })
        }
    }
    return @($changes)
}

function Get-Rg353psStabilityReasonKind {
    # Maps a resolver reason string to a short, reportable anomaly kind.
    param([string]$Reason)

    if ($Reason -match 'expected exactly one VID_2207&PID_0006 root, found (\d+)') {
        if ([int]$Matches[1] -eq 0) { return 'device_absent' }
        return 'device_duplicated'
    }
    if ($Reason -match 'no PnP child for the target USB device') { return 'child_missing' }
    if ($Reason -match 'child-to-disk mapping is not unique') { return 'disk_mapping_ambiguous' }
    if ($Reason -match 'mapped disk is not a USB/USBSTOR disk') { return 'disk_not_usb' }
    if ($Reason -match 'cannot determine the PHYSICALDRIVE number') { return 'disk_index_unknown' }
    if ($Reason -match 'IOCTL could not resolve') { return 'ioctl_unresolved' }
    if ($Reason -match 'expected exactly one volume GUID mapped to PHYSICALDRIVE') { return 'ioctl_not_unique' }
    if ($Reason -match 'RAW/unknown filesystem') { return 'filesystem_raw' }
    if ($Reason -match 'expected exactly one accessible exFAT/FAT32 volume') { return 'volume_not_unique' }
    if ($Reason -match 'volume metadata for the IOCTL-mapped GUID is not unique') { return 'volume_metadata_ambiguous' }
    if ($Reason -match 'volume metadata for the target partition is not unique') { return 'volume_metadata_ambiguous' }
    if ($Reason -match 'target volume filesystem is') { return 'filesystem_unexpected' }
    if ($Reason -match 'has no drive letter') { return 'no_drive_letter' }
    return 'mapping_failed'
}

function Test-Rg353psStabilityPresence {
    # Metadata-only existence checks on the already proven volume. Nothing is
    # opened for writing; Test-Path / Get-Item only.
    param([string]$Drive, [string]$DatasetDir, [string]$FileName)

    $volumePresent = $false
    $datasetPresent = $false
    $filePresent = $false
    $fileSize = $null
    $filePath = ''

    if (-not [string]::IsNullOrEmpty($Drive)) {
        $root = $Drive.TrimEnd('\') + '\'
        try { $volumePresent = [bool](Test-Path -LiteralPath $root) } catch { $volumePresent = $false }
    }
    if (-not [string]::IsNullOrEmpty($DatasetDir)) {
        try { $datasetPresent = [bool](Test-Path -LiteralPath $DatasetDir -PathType Container) } catch { $datasetPresent = $false }
        if (-not [string]::IsNullOrEmpty($FileName)) {
            $filePath = Join-Path $DatasetDir $FileName
            try { $filePresent = [bool](Test-Path -LiteralPath $filePath -PathType Leaf) } catch { $filePresent = $false }
            if ($filePresent) {
                try { $fileSize = (Get-Item -LiteralPath $filePath -ErrorAction Stop).Length } catch { $fileSize = $null }
            }
        }
    }
    return [ordered]@{
        volume_present  = $volumePresent
        dataset_present = $datasetPresent
        file_path       = $filePath
        file_present    = $filePresent
        file_size       = $fileSize
    }
}

function Get-Rg353psStabilityHashCheck {
    # Read-only re-read of one file. No caching, no writes, no repair.
    param([string]$Path, [long]$ExpectedSize, [string]$ExpectedSha256)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $actualSize = $null
    $actualSha = ''
    $ok = $false
    $errorText = ''
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $actualSize = [long]$item.Length
        $actualSha = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
        $sizeOk = ($ExpectedSize -lt 0) -or ($actualSize -eq $ExpectedSize)
        $shaOk = [string]::IsNullOrEmpty($ExpectedSha256) -or ($actualSha -eq $ExpectedSha256.ToLower())
        $ok = ($sizeOk -and $shaOk)
        if (-not $sizeOk) { $errorText = 'size mismatch' }
        elseif (-not $shaOk) { $errorText = 'SHA-256 mismatch' }
    }
    catch {
        $errorText = $_.Exception.Message
    }
    $sw.Stop()
    return [ordered]@{
        utc               = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        path              = $Path
        expected_size     = $ExpectedSize
        actual_size       = $actualSize
        expected_sha256   = $ExpectedSha256
        actual_sha256     = $actualSha
        ok                = $ok
        duration_ms       = [int]$sw.ElapsedMilliseconds
        error             = $errorText
    }
}

function Test-Rg353psStabilitySample {
    # One observation: strict mapping, presence on the proven volume, and
    # identity drift against the baseline. Returns the sample row plus at most
    # one anomaly; the caller stops on the first anomaly.
    param(
        [array]$Topology,
        [array]$IoctlMap,
        $Baseline,
        [string]$DatasetDir,
        [string]$FileName,
        [int]$Index,
        [string]$Utc,
        [double]$ElapsedSeconds
    )

    $sample = [ordered]@{
        index            = $Index
        utc              = $Utc
        elapsed_seconds  = [math]::Round($ElapsedSeconds, 1)
        pid_0006_roots   = 0
        mapping_ok       = $false
        mapping_reason   = ''
        path             = ''
        disk             = ''
        disk_index       = ''
        volume_guid      = ''
        drive            = ''
        filesystem       = ''
        volume_present   = $false
        dataset_present  = $false
        file_present     = $false
        file_size        = $null
        ok               = $false
    }

    $sample.pid_0006_roots = @($Topology.PnpDevices | Where-Object {
        $_.PNPDeviceID -match '^USB\\VID_2207&PID_0006\\' -and $_.PNPDeviceID -notmatch '&MI_'
    }).Count

    $map = Resolve-Rg353psTarget -PnpDevices $Topology.PnpDevices `
        -PnpChildren $Topology.PnpChildren -Disks $Topology.Disks `
        -DiskPartitions $Topology.DiskPartitions -Volumes $Topology.Volumes `
        -IoctlVolumes $IoctlMap

    $sample.mapping_ok = [bool]$map.Ok
    $sample.mapping_reason = [string]$map.Reason
    $sample.path = [string]$map.Path

    $fp = $null
    if ($map.Ok) {
        $fp = Get-Rg353psStabilityFingerprint -Map $map
        $sample.disk = $fp.disk_device_id
        $sample.disk_index = $fp.disk_index
        $sample.volume_guid = $fp.volume_device_id
        $sample.drive = $fp.drive_letter
        $sample.filesystem = $fp.filesystem

        $presence = Test-Rg353psStabilityPresence -Drive $fp.drive_letter `
            -DatasetDir $DatasetDir -FileName $FileName
        $sample.volume_present = [bool]$presence.volume_present
        $sample.dataset_present = [bool]$presence.dataset_present
        $sample.file_present = [bool]$presence.file_present
        $sample.file_size = $presence.file_size
    }

    $anomaly = $null
    if (-not $map.Ok) {
        $anomaly = [ordered]@{
            utc = $Utc; kind = (Get-Rg353psStabilityReasonKind -Reason ([string]$map.Reason))
            detail = [string]$map.Reason; sample_index = $Index
        }
    }
    elseif (-not $sample.volume_present) {
        $anomaly = [ordered]@{
            utc = $Utc; kind = 'volume_missing'
            detail = ('mapped volume ' + $sample.drive + ' is no longer present')
            sample_index = $Index
        }
    }
    elseif (-not $sample.dataset_present) {
        $anomaly = [ordered]@{
            utc = $Utc; kind = 'dataset_missing'
            detail = ('dataset directory disappeared: ' + $DatasetDir)
            sample_index = $Index
        }
    }
    elseif (-not $sample.file_present) {
        $anomaly = [ordered]@{
            utc = $Utc; kind = 'file_missing'
            detail = ('test file disappeared: ' + (Join-Path $DatasetDir $FileName))
            sample_index = $Index
        }
    }
    elseif ($null -ne $Baseline) {
        $changes = @(Compare-Rg353psStabilityIdentity -Baseline $Baseline -Current $fp)
        if ($changes.Count -gt 0) {
            $parts = @($changes | ForEach-Object { $_.field + ': ' + $_.before + ' -> ' + $_.after })
            $anomaly = [ordered]@{
                utc = $Utc; kind = 'mapping_changed'
                detail = ($parts -join '; '); sample_index = $Index
            }
        }
    }

    $sample.ok = ($null -eq $anomaly)
    return [pscustomobject]@{
        Sample = $sample
        Baseline = $fp
        Anomaly = $anomaly
    }
}

function Get-Rg353psStabilityManifestTarget {
    # Resolves the 128 MiB test file and its expected size/SHA-256 from the
    # device-produced manifest. No guessing: without a manifest entry the
    # caller must supply -ExpectedSha256 explicitly or the run aborts.
    param([string]$DatasetDir, [string]$RelPath, [long]$ExpectedSizeParam, [string]$ExpectedShaParam)

    $result = [ordered]@{
        file_name   = ''
        rel_path    = ''
        expected_size = $ExpectedSizeParam
        expected_sha256 = $ExpectedShaParam
        source      = 'parameters'
        manifest    = ''
    }
    $manifestPath = Join-Path $DatasetDir 'baseos-mtp-test-manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $result.manifest = $manifestPath
        $man = $null
        try { $man = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { $man = $null }
        if ($null -ne $man) {
            $entry = $null
            if (-not [string]::IsNullOrEmpty($RelPath)) {
                $entry = @($man.files | Where-Object { $_.relpath -eq $RelPath } | Select-Object -First 1)
            }
            if ($null -eq $entry -or @($entry).Count -eq 0) {
                $entry = @($man.files | Where-Object { $_.relpath -match 'large-128m' } | Select-Object -First 1)
            }
            if (@($entry).Count -gt 0) {
                $e = @($entry)[0]
                $result.rel_path = [string]$e.relpath
                $result.file_name = Split-Path -Leaf ([string]$e.relpath)
                $result.expected_size = [long]$e.size
                $result.expected_sha256 = [string]$e.sha256
                $result.source = 'device manifest'
            }
        }
    }
    if ([string]::IsNullOrEmpty($result.file_name)) {
        if ([string]::IsNullOrEmpty($RelPath)) { $result.file_name = 'large-128m.bin' }
        else { $result.file_name = Split-Path -Leaf $RelPath }
    }
    return $result
}

function Write-Rg353psStabilityReports {
    param($State, [string]$OutJson, [string]$OutMd)

    $samples = @($State.samples)
    $anomalies = @($State.anomalies)
    $hashes = @($State.hash_checks)
    $okSamples = @($samples | Where-Object { $_.ok }).Count
    $okHashes = @($hashes | Where-Object { $_.ok }).Count
    $pass = [bool]($State.pass)

    $report = [ordered]@{
        tool = 'rg353ps-mass-storage-stability-readonly'
        run_id = $State.run_id
        started_utc = $State.started_utc
        finished_utc = $State.finished_utc
        mode = 'USB Mass Storage (VID_2207&PID_0006)'
        read_only = $true
        planned_duration_minutes = $State.duration_minutes
        poll_interval_seconds = $State.poll_interval_seconds
        hash_interval_minutes = $State.hash_interval_minutes
        device_selection = 'same strict PnP -> USBSTOR -> PHYSICALDRIVE -> IOCTL volume chain as the one-shot check; no fallback scanning'
        aborted = [bool]$State.aborted
        abort_reason = [string]$State.abort_reason
        summary = [ordered]@{
            samples = $samples.Count
            samples_ok = $okSamples
            hash_checks = $hashes.Count
            hash_checks_ok = $okHashes
            anomalies = $anomalies.Count
            pass = $pass
        }
        baseline = $State.baseline
        expected_file = $State.expected
        anomalies = $anomalies
        hash_checks = $hashes
        samples = $samples
    }

    $enc = New-Object System.Text.UTF8Encoding($false)
    $json = $report | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($OutJson, $json, $enc)

    $md = New-Object System.Collections.ArrayList
    [void]$md.Add('# RG353PS Mass Storage stability report (read-only)')
    [void]$md.Add('')
    [void]$md.Add('- Run ID: `' + $State.run_id + '`')
    [void]$md.Add('- Overall: ' + $(if ($pass) { '**PASS**' } else { '**FAIL**' }))
    [void]$md.Add('- Read-only: yes (no write, no format, no repair, no drive-letter change, no disconnect)')
    [void]$md.Add('- Planned: ' + $State.duration_minutes + ' min, poll every ' + $State.poll_interval_seconds + ' s, SHA-256 every ' + $State.hash_interval_minutes + ' min')
    [void]$md.Add('- Started/Finished (UTC): ' + $State.started_utc + ' / ' + $State.finished_utc)
    [void]$md.Add('- Samples: ' + $samples.Count + ' (' + $okSamples + ' ok); SHA-256 checks: ' + $hashes.Count + ' (' + $okHashes + ' ok)')
    [void]$md.Add('- Anomalies: ' + $anomalies.Count + $(if ($State.aborted) { ' (stopped at the first one)' } else { '' }))
    [void]$md.Add('')
    if ($null -ne $State.baseline) {
        [void]$md.Add('## Baseline identity')
        [void]$md.Add('')
        [void]$md.Add('| Field | Value |')
        [void]$md.Add('| --- | --- |')
        foreach ($k in $State.baseline.Keys) {
            [void]$md.Add('| ' + $k + ' | ' + ([string]$State.baseline[$k] -replace '\|', '/') + ' |')
        }
        [void]$md.Add('')
    }
    if ($null -ne $State.expected) {
        $ex = $State.expected
        [void]$md.Add('## Test file')
        [void]$md.Add('')
        [void]$md.Add('- Path: `' + [string]$ex.file_path + '`')
        [void]$md.Add('- Expected size: ' + [string]$ex.expected_size)
        [void]$md.Add('- Expected SHA-256: `' + [string]$ex.expected_sha256 + '`')
        [void]$md.Add('- Source: ' + [string]$ex.source)
        [void]$md.Add('')
    }
    if ($anomalies.Count -gt 0) {
        [void]$md.Add('## Anomalies')
        [void]$md.Add('')
        [void]$md.Add('| UTC | Kind | Detail | Sample |')
        [void]$md.Add('| --- | --- | --- | --- |')
        foreach ($a in $anomalies) {
            [void]$md.Add('| ' + $a.utc + ' | ' + $a.kind + ' | ' + ([string]$a.detail -replace '\|', '/') + ' | ' + $a.sample_index + ' |')
        }
        [void]$md.Add('')
    }
    if ($hashes.Count -gt 0) {
        [void]$md.Add('## SHA-256 checks')
        [void]$md.Add('')
        [void]$md.Add('| UTC | Size | SHA-256 match | ms | Error |')
        [void]$md.Add('| --- | --- | --- | --- | --- |')
        foreach ($h in $hashes) {
            [void]$md.Add('| ' + $h.utc + ' | ' + [string]$h.actual_size + ' | ' + $(if ($h.ok) { 'yes' } else { 'NO' }) + ' | ' + $h.duration_ms + ' | ' + ([string]$h.error -replace '\|', '/') + ' |')
        }
        [void]$md.Add('')
    }
    [void]$md.Add('## Timeline (first and last samples)')
    [void]$md.Add('')
    [void]$md.Add('| # | UTC | Elapsed s | PID_0006 | Map | Path | Disk idx | Drive | Volume | File | OK |')
    [void]$md.Add('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |')
    $show = New-Object System.Collections.ArrayList
    if ($samples.Count -le 10) {
        foreach ($s in $samples) { [void]$show.Add($s) }
    }
    else {
        foreach ($s in @($samples | Select-Object -First 5)) { [void]$show.Add($s) }
        foreach ($s in @($samples | Select-Object -Last 5)) { [void]$show.Add($s) }
    }
    foreach ($s in $show) {
        [void]$md.Add('| ' + $s.index + ' | ' + $s.utc + ' | ' + $s.elapsed_seconds + ' | ' + $s.pid_0006_roots + ' | ' + $(if ($s.mapping_ok) { 'ok' } else { 'FAIL' }) + ' | ' + $s.path + ' | ' + [string]$s.disk_index + ' | ' + $s.drive + ' | ' + $(if ($s.volume_present) { 'yes' } else { 'NO' }) + ' | ' + $(if ($s.file_present) { 'yes' } else { 'NO' }) + ' | ' + $(if ($s.ok) { 'yes' } else { 'NO' }) + ' |')
    }
    [void]$md.Add('')
    [void]$md.Add('> Full per-poll timeline is in the JSON report. Read-only observation:')
    [void]$md.Add('> no write, no format, no repair, no drive-letter change, no disconnect.')
    [System.IO.File]::WriteAllText($OutMd, (($md -join "`r`n") + "`r`n"), $enc)
}

function Invoke-Rg353psStabilityRun {
    $startedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $started = Get-Date
    $endAt = $started.AddMinutes($DurationMinutes)

    Write-Host '== RG353PS Mass Storage stability check (read-only) ==' -ForegroundColor Cyan
    Write-Host ('Run ID: ' + $RunId)
    Write-Host ('Duration: ' + $DurationMinutes + ' min; poll every ' + $PollIntervalSeconds + ' s; SHA-256 every ' + $HashIntervalMinutes + ' min')

    $state = @{
        run_id = $RunId
        started_utc = $startedUtc
        finished_utc = ''
        duration_minutes = $DurationMinutes
        poll_interval_seconds = $PollIntervalSeconds
        hash_interval_minutes = $HashIntervalMinutes
        baseline = $null
        expected = $null
        samples = @()
        hash_checks = @()
        anomalies = @()
        aborted = $false
        abort_reason = ''
        pass = $false
    }
    $jsonPath = Join-Path $OutDir ($ReportBaseName + '.json')
    $mdPath = Join-Path $OutDir ($ReportBaseName + '.md')
    if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }

    $prompt = Get-Rg353psStabilityFormatPrompt
    if ($prompt.Count -gt 0) {
        $state.anomalies = @([ordered]@{ utc = $startedUtc; kind = 'format_prompt'; detail = 'Windows format prompt detected before start; stopped immediately'; sample_index = 0 })
        $state.aborted = $true
        $state.abort_reason = 'format_prompt'
        $state.finished_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Write-Rg353psStabilityReports -State $state -OutJson $jsonPath -OutMd $mdPath
        Write-Host 'STOP: a format prompt is open. Nothing was touched.' -ForegroundColor Red
        return 1
    }

    # ---- Baseline: finite wait for one valid, unique mapping ----------------
    $baselineDeadline = $started.AddSeconds($InitialWaitSeconds)
    $baseline = $null
    $datasetDir = ''
    $expected = $null
    $baselineFailure = ''
    while ($true) {
        $topo = Get-Rg353psLiveTopology
        $ioctl = @(Get-Rg353psIoctlVolumeMap -Volumes $topo.Volumes)
        $map = Resolve-Rg353psTarget -PnpDevices $topo.PnpDevices -PnpChildren $topo.PnpChildren `
            -Disks $topo.Disks -DiskPartitions $topo.DiskPartitions -Volumes $topo.Volumes `
            -IoctlVolumes $ioctl
        if ($map.Ok) {
            $datasetDir = [string]$map.Volume.DriveLetter
            if ([string]::IsNullOrEmpty($datasetDir)) {
                $baselineFailure = 'mapped volume has no drive letter; no file will be read'
                break
            }
            $baseline = Get-Rg353psStabilityFingerprint -Map $map
            $datasetDir = $datasetDir.TrimEnd('\') + '\baseos-mtp-test-' + $RunId
            $t = Get-Rg353psStabilityManifestTarget -DatasetDir $datasetDir `
                -RelPath $TestFileRelPath -ExpectedSizeParam $ExpectedSize -ExpectedShaParam $ExpectedSha256
            if ([string]::IsNullOrEmpty($t.expected_sha256)) {
                $state.anomalies = @([ordered]@{
                    utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                    kind = 'expected_hash_unavailable'
                    detail = 'no device manifest entry and no -ExpectedSha256 supplied; refusing to hash without an expected value'
                    sample_index = 0
                })
                $state.baseline = $baseline
                $state.aborted = $true
                $state.abort_reason = 'expected_hash_unavailable'
                $state.finished_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                Write-Rg353psStabilityReports -State $state -OutJson $jsonPath -OutMd $mdPath
                Write-Host 'FAIL: no expected SHA-256 available; nothing was hashed.' -ForegroundColor Red
                return 1
            }
            $expected = [ordered]@{
                file_path = (Join-Path $datasetDir $t.file_name)
                file_name = $t.file_name
                rel_path = $t.rel_path
                expected_size = $t.expected_size
                expected_sha256 = $t.expected_sha256
                source = $t.source
                manifest = $t.manifest
            }
            break
        }
        if ((Get-Date) -ge $baselineDeadline) { break }
        Start-Sleep -Seconds ([math]::Min(5, [math]::Max(1, $PollIntervalSeconds)))
    }

    if ($null -eq $baseline) {
        $reason = $(if ($baselineFailure) { $baselineFailure } else { [string]$map.Reason })
        $state.anomalies = @([ordered]@{
            utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            kind = (Get-Rg353psStabilityReasonKind -Reason $reason)
            detail = ('no baseline within ' + $InitialWaitSeconds + ' s: ' + $reason)
            sample_index = 0
        })
        $state.aborted = $true
        $state.abort_reason = 'no_baseline'
        $state.finished_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Write-Rg353psStabilityReports -State $state -OutJson $jsonPath -OutMd $mdPath
        Write-Host ('FAIL: ' + $reason) -ForegroundColor Red
        return 1
    }
    $state.baseline = $baseline
    $state.expected = $expected

    # ---- Monitoring window -------------------------------------------------
    $sampleIndex = 0
    $nextHashAt = Get-Date
    $stop = $false
    while (-not $stop) {
        $now = Get-Date
        $utc = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $elapsed = ($now - $started).TotalSeconds
        $sampleIndex++

        $prompt = Get-Rg353psStabilityFormatPrompt
        if ($prompt.Count -gt 0) {
            $state.anomalies += [ordered]@{ utc = $utc; kind = 'format_prompt'; detail = 'Windows format prompt detected; stopped immediately'; sample_index = $sampleIndex }
            $stop = $true
            $state.aborted = $true
            $state.abort_reason = 'format_prompt'
            break
        }

        $topo = $null
        $ioctl = @()
        $collectError = ''
        try {
            $topo = Get-Rg353psLiveTopology
            $ioctl = @(Get-Rg353psIoctlVolumeMap -Volumes $topo.Volumes)
        }
        catch {
            $collectError = $_.Exception.Message
            $topo = $null
        }

        if ($null -eq $topo) {
            $state.anomalies += [ordered]@{ utc = $utc; kind = 'topology_collection_failed'; detail = $collectError; sample_index = $sampleIndex }
            $stop = $true
            $state.aborted = $true
            $state.abort_reason = 'topology_collection_failed'
            break
        }

        $r = Test-Rg353psStabilitySample -Topology $topo -IoctlMap $ioctl `
            -Baseline $baseline -DatasetDir $datasetDir -FileName $expected.file_name `
            -Index $sampleIndex -Utc $utc -ElapsedSeconds $elapsed
        $state.samples += $r.Sample

        if ($null -ne $r.Anomaly) {
            $state.anomalies += $r.Anomaly
            $stop = $true
            $state.aborted = $true
            $state.abort_reason = [string]$r.Anomaly.kind
            break
        }

        # ---- 128 MiB SHA-256 re-read, on its own schedule ------------------
        if ($now -ge $nextHashAt) {
            $h = Get-Rg353psStabilityHashCheck -Path $expected.file_path `
                -ExpectedSize ([long]$expected.expected_size) `
                -ExpectedSha256 ([string]$expected.expected_sha256)
            $h['elapsed_seconds'] = [math]::Round($elapsed, 1)
            $state.hash_checks += $h
            $nextHashAt = $nextHashAt.AddMinutes($HashIntervalMinutes)
            if (-not $h.ok) {
                $state.anomalies += [ordered]@{
                    utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                    kind = 'read_failed'
                    detail = ('SHA-256 verification failed: ' + [string]$h.error + '; path=' + [string]$expected.file_path)
                    sample_index = $sampleIndex
                }
                $stop = $true
                $state.aborted = $true
                $state.abort_reason = 'read_failed'
                break
            }
        }

        if ($now -ge $endAt) { break }

        $sleep = [math]::Min($PollIntervalSeconds, [math]::Max(1, [int]($endAt - (Get-Date)).TotalSeconds))
        Start-Sleep -Seconds $sleep
    }

    $finished = Get-Date
    $state.finished_utc = $finished.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $state.pass = [bool](
        (-not $state.aborted) -and
        ($state.samples.Count -ge 2) -and
        (@($state.anomalies).Count -eq 0) -and
        (@($state.samples | Where-Object { -not $_.ok }).Count -eq 0) -and
        (@($state.hash_checks | Where-Object { -not $_.ok }).Count -eq 0) -and
        (@($state.hash_checks).Count -ge 1) -and
        (($finished - $started).TotalSeconds -ge ($DurationMinutes * 60 * 0.95))
    )

    Write-Rg353psStabilityReports -State $state -OutJson $jsonPath -OutMd $mdPath
    Write-Host ('Samples: ' + $state.samples.Count + '; SHA-256 checks: ' + @($state.hash_checks).Count + '; anomalies: ' + @($state.anomalies).Count)
    Write-Host ('Reports: ' + $jsonPath)
    Write-Host ('         ' + $mdPath)
    if ($state.pass) {
        Write-Host ('PASS: mapping stayed unique and stable for ' + [math]::Round(($finished - $started).TotalSeconds, 1) + ' s; all SHA-256 checks matched.')
        return 0
    }
    Write-Host ('FAIL: aborted=' + $state.aborted + '; reason=' + $state.abort_reason) -ForegroundColor Red
    foreach ($a in @($state.anomalies)) { Write-Host ('  - ' + $a.utc + ' ' + $a.kind + ': ' + $a.detail) -ForegroundColor Red }
    return 1
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-Rg353psStabilityRun)
}
