# Offline tests for the RG353PS Mass Storage stability check. No hardware,
# no disk and no volume is contacted. Only pure functions, temp files under
# the system temp directory and the report writer are exercised.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\test-rg353ps-mass-storage-stability.ps1
#
$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StabilityScript = Join-Path $ScriptDir 'check-rg353ps-mass-storage-stability.ps1'
. $StabilityScript

$Results = New-Object System.Collections.ArrayList
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rg353ps-stability-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
$TempDrive = Split-Path -Qualifier $TempRoot

function Add-Result {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    [void]$Results.Add([ordered]@{ name = $Name; pass = [bool]$Ok; detail = $Detail })
    $label = $(if ($Ok) { 'PASS' } else { 'FAIL' })
    Write-Host (('{0,-5} {1}' -f $label, $Name))
    if (-not $Ok) { Write-Host ('       ' + $Detail) -ForegroundColor Red }
}

$USB_ROOT = 'USB\VID_2207&PID_0006\BASEOS-RG353PS'
$USB_STOR = 'USBSTOR\Disk&Ven_BaseOS&Prod_RG353PS&Rev_1.00\BASEOS-RG353PS&0'
$TARGET_DISK = '\\.\PHYSICALDRIVE3'
$TARGET_GUID = '\\?\Volume{4508079a-d83f-11f1-9794-c8a3e85ae46c}'
$DATASET = Join-Path $TempRoot ('baseos-mtp-test-20261106-131355-4a3405')
New-Item -ItemType Directory -Path $DATASET -Force | Out-Null
$TESTFILE = Join-Path $DATASET 'large-128m.bin'
[System.IO.File]::WriteAllBytes($TESTFILE, (New-Object byte[] 4096))

function New-StabilityTopology {
    param([int]$DiskIndex = 3, [string]$Drive = $TempDrive, [string]$Guid = $TARGET_GUID,
          [string]$FileSystem = 'exFAT', [switch]$Partitioned, [switch]$Raw, [int]$RootCount = 1)
    $pnp = New-Object System.Collections.ArrayList
    [void]$pnp.Add([pscustomobject]@{ PNPDeviceID = $USB_ROOT; Name = 'RG353PS USB Storage'; PNPClass = 'USB'; Status = 'OK' })
    for ($i = 2; $i -le $RootCount; $i++) {
        [void]$pnp.Add([pscustomobject]@{ PNPDeviceID = ('USB\VID_2207&PID_0006\SECOND' + $i); Name = 'RG353PS'; PNPClass = 'USB'; Status = 'OK' })
    }
    $t = [ordered]@{
        PnpDevices = @($pnp)
        PnpChildren = @([pscustomobject]@{ Parent = $USB_ROOT; Child = $USB_STOR })
        Disks = @([pscustomobject]@{
            DeviceID = ('\\.\PHYSICALDRIVE' + $DiskIndex); PNPDeviceID = $USB_STOR
            InterfaceType = 'USB'; Index = $DiskIndex; Model = 'RG353PS'; Size = 14188608000
        })
        DiskPartitions = @()
        Volumes = @([pscustomobject]@{ DeviceID = $Guid; DriveLetter = $Drive; FileSystem = $FileSystem; Capacity = 14190346240 })
        IoctlVolumes = @([pscustomobject]@{
            VolumeGuidPath = $Guid; DeviceNumber = $DiskIndex; PartitionNumber = 0; DeviceType = 7
            IoctlOk = $true; Error = ''; DriveLetter = $Drive; FileSystem = $FileSystem
        })
    }
    if ($Partitioned) {
        $t.DiskPartitions = @([pscustomobject]@{
            DiskDeviceID = ('\\.\PHYSICALDRIVE' + $DiskIndex); DeviceID = 'Disk #3, Partition #0'
            DriveLetter = $Drive; FileSystem = $(if ($Raw) { 'RAW' } else { 'exFAT' }); Size = 14188608000; Type = 'Installable File System'
        })
    }
    return $t
}

function Get-StabilityMap($t) {
    return Resolve-Rg353psTarget -PnpDevices @($t.PnpDevices) -PnpChildren @($t.PnpChildren) `
        -Disks @($t.Disks) -DiskPartitions @($t.DiskPartitions) -Volumes @($t.Volumes) `
        -IoctlVolumes @($t.IoctlVolumes)
}

function Invoke-Sample {
    param($Topology, $Baseline, [string]$DatasetDir = $DATASET, [string]$FileName = 'large-128m.bin', [int]$Index = 1)
    return Test-Rg353psStabilitySample -Topology $Topology -IoctlMap @($Topology.IoctlVolumes) `
        -Baseline $Baseline -DatasetDir $DatasetDir -FileName $FileName `
        -Index $Index -Utc '2026-11-06T15:20:00Z' -ElapsedSeconds 10
}

# ---- 1. Identity fingerprint and drift detection ----------------------------
$t1 = New-StabilityTopology
$map1 = Get-StabilityMap $t1
$fp1 = Get-Rg353psStabilityFingerprint -Map $map1
$fp1b = Get-Rg353psStabilityFingerprint -Map $map1
$changes0 = @(Compare-Rg353psStabilityIdentity -Baseline $fp1 -Current $fp1b)
Add-Result 'fingerprint is stable for the same mapping' ($map1.Ok -and $changes0.Count -eq 0) ('mapping_ok=' + $map1.Ok + '; changes=' + $changes0.Count)

$t2 = New-StabilityTopology -DiskIndex 4
$map2 = Get-StabilityMap $t2
$fp2 = Get-Rg353psStabilityFingerprint -Map $map2
$chIdx = @(Compare-Rg353psStabilityIdentity -Baseline $fp1 -Current $fp2)
$hasIdx = @($chIdx | Where-Object { $_.field -eq 'disk_index' }).Count -eq 1
Add-Result 'disk index change is detected' ($fp2.disk_index -eq '4' -and $hasIdx) ('changes=' + (@($chIdx | ForEach-Object { $_.field }) -join ','))

$t3 = New-StabilityTopology -Guid '\\?\Volume{changed-guid}'
$fp3 = Get-Rg353psStabilityFingerprint -Map (Get-StabilityMap $t3)
$chGuid = @(Compare-Rg353psStabilityIdentity -Baseline $fp1 -Current $fp3)
Add-Result 'volume GUID change is detected' (@($chGuid | Where-Object { $_.field -eq 'volume_device_id' }).Count -eq 1) ('changes=' + (@($chGuid | ForEach-Object { $_.field }) -join ','))

$t4 = New-StabilityTopology -Partitioned
$map4 = Get-StabilityMap $t4
$fp4 = Get-Rg353psStabilityFingerprint -Map $map4
$chPath = @(Compare-Rg353psStabilityIdentity -Baseline $fp1 -Current $fp4)
Add-Result 'mapping path change (superfloppy -> partitioned) is detected' ($map4.Path -eq 'partitioned' -and @($chPath | Where-Object { $_.field -eq 'path' }).Count -eq 1) ('path=' + $map4.Path + '; changes=' + (@($chPath | ForEach-Object { $_.field }) -join ','))

$t5 = New-StabilityTopology -Drive 'Z:'
$fp5 = Get-Rg353psStabilityFingerprint -Map (Get-StabilityMap $t5)
$chDrive = @(Compare-Rg353psStabilityIdentity -Baseline $fp1 -Current $fp5)
Add-Result 'drive letter change is detected' (@($chDrive | Where-Object { $_.field -eq 'drive_letter' }).Count -eq 1) ('changes=' + (@($chDrive | ForEach-Object { $_.field }) -join ','))

# ---- 2. Reason classification ----------------------------------------------
$reasonCases = @(
    @('expected exactly one VID_2207&PID_0006 root, found 0', 'device_absent'),
    @('expected exactly one VID_2207&PID_0006 root, found 2', 'device_duplicated'),
    @('no PnP child for the target USB device; identity cannot be established', 'child_missing'),
    @('child-to-disk mapping is not unique: 2 candidates', 'disk_mapping_ambiguous'),
    @('mapped disk is not a USB/USBSTOR disk', 'disk_not_usb'),
    @('RAW/unknown filesystem on 1 partition(s); stopping before volume access', 'filesystem_raw'),
    @('IOCTL could not resolve 1 volume GUID(s); device ownership cannot be confirmed', 'ioctl_unresolved'),
    @('expected exactly one volume GUID mapped to PHYSICALDRIVE3 via IOCTL, found 2', 'ioctl_not_unique'),
    @('IOCTL-mapped superfloppy volume has no drive letter; no file will be read', 'no_drive_letter'),
    @('volume metadata for the IOCTL-mapped GUID is not unique', 'volume_metadata_ambiguous'),
    @('something entirely unexpected', 'mapping_failed')
)
$badReason = 0
foreach ($rc in $reasonCases) {
    $got = Get-Rg353psStabilityReasonKind -Reason $rc[0]
    if ($got -ne $rc[1]) { $badReason++; Write-Host ('       ' + $rc[0] + ' -> ' + $got + ' (expected ' + $rc[1] + ')') -ForegroundColor Red }
}
Add-Result 'resolver reasons map to anomaly kinds' ($badReason -eq 0) ('mismatches=' + $badReason)

# ---- 3. Presence checks -----------------------------------------------------
$p1 = Test-Rg353psStabilityPresence -Drive $TempDrive -DatasetDir $DATASET -FileName 'large-128m.bin'
Add-Result 'presence: volume, dataset and file found' ($p1.volume_present -and $p1.dataset_present -and $p1.file_present -and $p1.file_size -eq 4096) ('size=' + $p1.file_size)

$p2 = Test-Rg353psStabilityPresence -Drive $TempDrive -DatasetDir $DATASET -FileName 'does-not-exist.bin'
Add-Result 'presence: missing file reported, size null' ((-not $p2.file_present) -and ($null -eq $p2.file_size)) ('present=' + $p2.file_present)

$p3 = Test-Rg353psStabilityPresence -Drive $TempDrive -DatasetDir (Join-Path $TempRoot 'no-such-dataset') -FileName 'large-128m.bin'
Add-Result 'presence: missing dataset reported' ((-not $p3.dataset_present) -and (-not $p3.file_present)) ('dataset=' + $p3.dataset_present)

$p4 = Test-Rg353psStabilityPresence -Drive 'ZZ:' -DatasetDir $DATASET -FileName 'large-128m.bin'
Add-Result 'presence: missing volume reported' (-not $p4.volume_present) ('volume=' + $p4.volume_present)

# ---- 4. SHA-256 re-read -----------------------------------------------------
$realSha = (Get-FileHash -LiteralPath $TESTFILE -Algorithm SHA256).Hash.ToLower()
$h1 = Get-Rg353psStabilityHashCheck -Path $TESTFILE -ExpectedSize 4096 -ExpectedSha256 $realSha
Add-Result 'hash check matches size and SHA-256' ($h1.ok -and $h1.actual_sha256 -eq $realSha -and $h1.error -eq '') ('sha=' + $h1.actual_sha256.Substring(0, 8))

$h2 = Get-Rg353psStabilityHashCheck -Path $TESTFILE -ExpectedSize 4096 -ExpectedSha256 ('0' * 64)
Add-Result 'hash mismatch fails with a reason' ((-not $h2.ok) -and ($h2.error -eq 'SHA-256 mismatch')) ('error=' + $h2.error)

$h3 = Get-Rg353psStabilityHashCheck -Path $TESTFILE -ExpectedSize 1024 -ExpectedSha256 $realSha
Add-Result 'size mismatch fails with a reason' ((-not $h3.ok) -and ($h3.error -eq 'size mismatch')) ('error=' + $h3.error)

$h4 = Get-Rg353psStabilityHashCheck -Path (Join-Path $DATASET 'missing.bin') -ExpectedSize 4096 -ExpectedSha256 $realSha
Add-Result 'unreadable file fails without throwing' ((-not $h4.ok) -and (-not [string]::IsNullOrEmpty($h4.error))) ('error=' + $h4.error)

# ---- 5. Per-sample verdicts -------------------------------------------------
$s1 = Invoke-Sample -Topology $t1 -Baseline $fp1
Add-Result 'sample ok on a stable, uniquely mapped volume' ($s1.Sample.ok -and ($null -eq $s1.Anomaly) -and $s1.Sample.volume_present -and $s1.Sample.file_present) ('ok=' + $s1.Sample.ok)

$s2 = Invoke-Sample -Topology $t2 -Baseline $fp1
Add-Result 'sample stops on mapping drift' ((($null -ne $s2.Anomaly) -and $s2.Anomaly.kind -eq 'mapping_changed')) ('kind=' + $s2.Anomaly.kind)

$tNoRoot = New-StabilityTopology
$tNoRoot.PnpDevices = @()
$s3 = Invoke-Sample -Topology $tNoRoot -Baseline $fp1
Add-Result 'sample reports device_absent when PID_0006 is gone' (($null -ne $s3.Anomaly) -and $s3.Anomaly.kind -eq 'device_absent') ('kind=' + $s3.Anomaly.kind)

$s4 = Invoke-Sample -Topology (New-StabilityTopology -RootCount 2) -Baseline $fp1
Add-Result 'sample reports device_duplicated for two roots' (($null -ne $s4.Anomaly) -and $s4.Anomaly.kind -eq 'device_duplicated') ('kind=' + $s4.Anomaly.kind)

$s5 = Invoke-Sample -Topology (New-StabilityTopology -Partitioned -Raw) -Baseline $fp1
Add-Result 'sample reports filesystem_raw before touching the volume' (($null -ne $s5.Anomaly) -and $s5.Anomaly.kind -eq 'filesystem_raw') ('kind=' + $s5.Anomaly.kind)

$s6 = Invoke-Sample -Topology $t1 -Baseline $fp1 -DatasetDir (Join-Path $TempRoot 'gone-dataset')
Add-Result 'sample reports dataset_missing when the folder disappears' (($null -ne $s6.Anomaly) -and $s6.Anomaly.kind -eq 'dataset_missing') ('kind=' + $s6.Anomaly.kind)

$s7 = Invoke-Sample -Topology $t1 -Baseline $fp1 -FileName 'gone.bin'
Add-Result 'sample reports file_missing when the test file disappears' (($null -ne $s7.Anomaly) -and $s7.Anomaly.kind -eq 'file_missing') ('kind=' + $s7.Anomaly.kind)

# ---- 6. Report writer -------------------------------------------------------
$st = @{
    run_id = '20261106-131355-4a3405'
    started_utc = '2026-11-06T15:20:00Z'
    finished_utc = '2026-11-06T15:50:01Z'
    duration_minutes = 30
    poll_interval_seconds = 10
    hash_interval_minutes = 5
    baseline = $fp1
    expected = [ordered]@{
        file_path = $TESTFILE; file_name = 'large-128m.bin'; rel_path = 'large-128m.bin'
        expected_size = 4096; expected_sha256 = $realSha; source = 'device manifest'; manifest = ''
    }
    samples = @($s1.Sample)
    hash_checks = @($h1)
    anomalies = @()
    aborted = $false
    abort_reason = ''
    pass = $true
}
$j1 = Join-Path $TempRoot 'pass.json'
$m1 = Join-Path $TempRoot 'pass.md'
Write-Rg353psStabilityReports -State $st -OutJson $j1 -OutMd $m1
$jp = $null
try { $jp = Get-Content -LiteralPath $j1 -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $jp = $null }
$mdText = Get-Content -LiteralPath $m1 -Raw -Encoding UTF8
Add-Result 'PASS report is valid JSON with summary and baseline' ($null -ne $jp -and $jp.summary.pass -eq $true -and $jp.summary.samples -eq 1 -and $null -ne $jp.baseline) ('tool=' + $jp.tool)
Add-Result 'PASS report markdown states PASS and read-only scope' (($mdText -match 'Overall: \*\*PASS\*\*') -and ($mdText -match 'Read-only: yes')) 'md checked'

$stFail = @{}
foreach ($k in $st.Keys) { $stFail[$k] = $st[$k] }
$stFail.anomalies = @([ordered]@{ utc = '2026-11-06T15:31:00Z'; kind = 'device_absent'; detail = 'expected exactly one VID_2207&PID_0006 root, found 0'; sample_index = 7 })
$stFail.samples = @($s1.Sample, $s3.Sample)
$stFail.aborted = $true
$stFail.abort_reason = 'device_absent'
$stFail.pass = $false
$j2 = Join-Path $TempRoot 'fail.json'
$m2 = Join-Path $TempRoot 'fail.md'
Write-Rg353psStabilityReports -State $stFail -OutJson $j2 -OutMd $m2
$jf = $null
try { $jf = Get-Content -LiteralPath $j2 -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $jf = $null }
$mdFail = Get-Content -LiteralPath $m2 -Raw -Encoding UTF8
Add-Result 'FAIL report keeps the anomaly and abort flag' ($null -ne $jf -and $jf.summary.pass -eq $false -and $jf.aborted -eq $true -and @($jf.anomalies).Count -eq 1 -and $jf.anomalies[0].kind -eq 'device_absent') ('aborted=' + $jf.aborted)
Add-Result 'FAIL report markdown lists the anomaly' (($mdFail -match 'Overall: \*\*FAIL\*\*') -and ($mdFail -match 'device_absent')) 'md checked'

# ---- 7. Static read-only and reuse guards -----------------------------------
$src = Get-Content -LiteralPath $StabilityScript -Raw -Encoding UTF8
$forbidden = @('Format-Volume', 'Initialize-Disk', 'Clear-Disk', 'Set-Partition', 'New-Partition',
    'Remove-Partition', 'Resize-Partition', 'Repair-Volume', 'Optimize-Volume', 'Set-Volume',
    'Set-Disk', 'diskpart', 'Remove-Item', 'Remove-PartitionAccessPath', 'Add-PartitionAccessPath',
    'Restart-Computer', 'Stop-Computer')
$hits = @($forbidden | Where-Object {
    if ($_ -eq 'diskpart') { $src -match '\bdiskpart\b' }
    else { $src -match [regex]::Escape($_) }
})
Add-Result 'no mutating storage cmdlets in the script' ($hits.Count -eq 0) ('hits=' + ($hits -join ','))

$reuses = ($src -match 'Rg353psDeviceMap\.ps1') -and ($src -match 'Resolve-Rg353psTarget') -and ($src -match 'Get-Rg353psIoctlVolumeMap')
Add-Result 'reuses Rg353psDeviceMap.ps1 strict mapping' $reuses 'module + resolver + IOCTL map referenced'

$defaults = ($src -match '\[double\]\$DurationMinutes\s*=\s*30') -and ($src -match '\[int\]\$PollIntervalSeconds\s*=\s*10') -and ($src -match '\[int\]\$HashIntervalMinutes\s*=\s*5')
Add-Result 'defaults are 30 min / 10 s / 5 min' $defaults 'param defaults checked'

# ---- Summary ----------------------------------------------------------------
$passCount = @($Results | Where-Object { $_.pass }).Count
$failCount = $Results.Count - $passCount
$summary = [ordered]@{
    tool = 'rg353ps-mass-storage-stability-offline-tests'
    executed_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    hardware_contacted = $false
    cases = $Results.Count
    pass = $passCount
    fail = $failCount
    results = @($Results)
}
$outDir = $ScriptDir
$outJson = Join-Path $outDir 'stability-offline-test-results.json'
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outJson, ($summary | ConvertTo-Json -Depth 8), $enc)

Write-Host ''
Write-Host ('TOTAL: ' + $passCount + '/' + $Results.Count + ' PASS, ' + $failCount + ' FAIL')
Write-Host ('Results: ' + $outJson)
try { Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
if ($failCount -gt 0) { exit 1 }
exit 0
