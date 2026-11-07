# Offline tests for the RG353PS Mass Storage write-integrity tool.
#
# No hardware is contacted. The only writes go to a throw-away directory under
# the system temp directory, and the resolver is fed injected topology mocks.
# Prepare is never run against a real volume here.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\test-rg353ps-mass-storage-write.ps1
#
$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WriteScript = Join-Path $ScriptDir 'check-rg353ps-mass-storage-write.ps1'
$OutJson = Join-Path $ScriptDir 'write-offline-test-results.json'

$Results = New-Object System.Collections.ArrayList
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rg353ps-write-test-' + [guid]::NewGuid().ToString('N'))
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
$TARGET_GUID = '\\?\Volume{4508079a-d83f-11f1-9794-c8a3e85ae46c}'

. $WriteScript -Phase None -OutDir $TempRoot

function New-WriteTopology {
    param(
        [int]$RootCount = 1,
        [switch]$NoChild,
        [switch]$DuplicateDisk,
        [switch]$Raw,
        [int]$MatchedVolumes = 1,
        [string]$Guid = $TARGET_GUID
    )
    $pnp = New-Object System.Collections.ArrayList
    if ($RootCount -ge 1) {
        [void]$pnp.Add([pscustomobject]@{ PNPDeviceID = $USB_ROOT; Name = 'RG353PS USB Storage'; PNPClass = 'USB'; Status = 'OK' })
    }
    for ($i = 2; $i -le $RootCount; $i++) {
        [void]$pnp.Add([pscustomobject]@{ PNPDeviceID = ('USB\VID_2207&PID_0006\SECOND' + $i); Name = 'RG353PS'; PNPClass = 'USB'; Status = 'OK' })
    }
    $children = @()
    if (-not $NoChild) { $children = @([pscustomobject]@{ Parent = $USB_ROOT; Child = $USB_STOR }) }
    $disks = New-Object System.Collections.ArrayList
    [void]$disks.Add([pscustomobject]@{
        DeviceID = '\\.\PHYSICALDRIVE3'; PNPDeviceID = $USB_STOR; InterfaceType = 'USB'
        Index = 3; Model = 'Linux File-Stor Gadget'; Size = 14188608000
    })
    if ($DuplicateDisk) {
        [void]$disks.Add([pscustomobject]@{
            DeviceID = '\\.\PHYSICALDRIVE4'; PNPDeviceID = $USB_STOR; InterfaceType = 'USB'
            Index = 4; Model = 'Linux File-Stor Gadget'; Size = 14188608000
        })
    }
    $fs = $(if ($Raw) { 'RAW' } else { 'exFAT' })
    $ioctl = New-Object System.Collections.ArrayList
    for ($i = 1; $i -le [math]::Max(1, $MatchedVolumes); $i++) {
        $g = $(if ($i -eq 1) { $Guid } else { '\\?\Volume{11111111-2222-3333-4444-555555555555}' })
        [void]$ioctl.Add([pscustomobject]@{
            VolumeGuidPath = $g; DeviceNumber = 3; PartitionNumber = 0; DeviceType = 7
            IoctlOk = $true; Error = ''; DriveLetter = $TempDrive; FileSystem = $fs
        })
    }
    return [ordered]@{
        PnpDevices = @($pnp)
        PnpChildren = @($children)
        Disks = @($disks)
        DiskPartitions = @()
        Volumes = @([pscustomobject]@{ DeviceID = $Guid; DriveLetter = $TempDrive; FileSystem = $fs; Capacity = 14190346240; FreeSpace = 12000000000 })
        IoctlVolumes = @($ioctl)
    }
}

function Write-MockTopology {
    param([string]$Name, $Topology)
    $path = Join-Path $TempRoot ($Name + '.json')
    [System.IO.File]::WriteAllText($path, ($Topology | ConvertTo-Json -Depth 10),
        (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Invoke-WriteTool {
    param([string[]]$Arguments)
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $WriteScript @Arguments 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
}

function Read-JsonReport {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# A. Relative-path safety
# ---------------------------------------------------------------------------
$reject = @(
    @('..\x.txt', 'traversal with backslash'),
    @('../x.txt', 'traversal with slash'),
    @('C:\Windows\x', 'drive-qualified absolute path'),
    @('\\server\share\x', 'UNC path'),
    @('/etc/passwd', 'rooted path'),
    @('a:b.txt', 'alternate data stream'),
    @('', 'empty path'),
    @('dir//file.bin', 'empty segment'),
    @('   \file.bin', 'whitespace-only segment')
)
foreach ($case in $reject) {
    $r = Test-Rg353psWriteSafeRelativePath -RelativePath $case[0]
    Add-Result ('rejects ' + $case[1]) (-not $r.Ok) ('input=[' + $case[0] + '] reason=' + $r.Reason)
}
$specs = Get-Rg353psWriteFileSpecs
$unicodeRel = ($specs | Where-Object { $_.kind -eq 'three-level-unicode' }).relpath
$r = Test-Rg353psWriteSafeRelativePath -RelativePath $unicodeRel
Add-Result 'accepts Unicode + spaces + three levels' ($r.Ok -and $r.Segments.Count -eq 3) ('segments=' + $r.Segments.Count + ' reason=' + $r.Reason)
$r = Test-Rg353psWriteSafeRelativePath -RelativePath 'nested/sub/deep.bin'
Add-Result 'accepts ASCII three-level path' ($r.Ok -and $r.Segments.Count -eq 3) ('segments=' + $r.Segments.Count)
$r = Test-Rg353psWriteSafeRelativePath -RelativePath 'name with spaces.txt'
Add-Result 'accepts a single name containing spaces' $r.Ok $r.Reason

# ---------------------------------------------------------------------------
# B. Resolved-path containment
# ---------------------------------------------------------------------------
$rootDir = Join-Path $TempRoot 'root'
New-Item -ItemType Directory -Path $rootDir -Force | Out-Null
$r = Resolve-Rg353psWriteItemPath -Root $rootDir -RelativePath 'nested/sub/deep.bin'
Add-Result 'resolves an in-dataset path' ($r.Ok -and $r.Path.StartsWith($rootDir + '\')) $r.Path
$r = Resolve-Rg353psWriteItemPath -Root $rootDir -RelativePath '..\escape.txt'
Add-Result 'refuses to escape the dataset root' (-not $r.Ok) $r.Reason
$r = Resolve-Rg353psWriteItemPath -Root $rootDir -RelativePath 'nested\..\x.bin'
Add-Result 'refuses inner traversal segments' (-not $r.Ok) $r.Reason
$r = Resolve-Rg353psWriteItemPath -Root ($rootDir + '\') -RelativePath 'a.bin'
Add-Result 'tolerates a trailing separator on the root' ($r.Ok -and $r.Path -eq (Join-Path $rootDir 'a.bin')) $r.Path
$sibling = $rootDir + '2'
New-Item -ItemType Directory -Path $sibling -Force | Out-Null
$r = Resolve-Rg353psWriteItemPath -Root $rootDir -RelativePath '..\root2\a.bin'
Add-Result 'refuses a sibling directory with a shared prefix' (-not $r.Ok) $r.Reason

# ---------------------------------------------------------------------------
# C. Write path: CreateNew, sizes, hashes, no overwrite
# ---------------------------------------------------------------------------
$dsDir = Join-Path $TempRoot 'dataset'
$ds = New-Rg353psWriteDataset -DatasetDir $dsDir -Files $specs
$written = @($ds.files | Where-Object { $_.written })
Add-Result 'writes all seven payloads' ($ds.ok -and $written.Count -eq 7) ('written=' + $written.Count + ' aborted=' + $ds.aborted + ' reason=' + $ds.abort_reason)
$sizes = @($ds.files | Where-Object { $_.actual_size -ne $_.expected_size })
Add-Result 'reported sizes match the specification' ($sizes.Count -eq 0) ('mismatches=' + $sizes.Count)
$big = @($ds.files | Where-Object { $_.relpath -eq 'large-128m.bin' })[0]
Add-Result '128 MiB payload is 134217728 bytes' ($big.actual_size -eq 134217728) ('actual=' + $big.actual_size)
$distinct = @($ds.files | ForEach-Object { $_.sha256 } | Sort-Object -Unique).Count
Add-Result 'payloads have distinct content' ($distinct -eq 7) ('distinct hashes=' + $distinct)
$onDisk = (Get-FileHash -LiteralPath (Join-Path $dsDir 'small-4k.bin') -Algorithm SHA256).Hash.ToLower()
Add-Result 'hash is computed while writing' ($onDisk -eq (@($ds.files | Where-Object { $_.relpath -eq 'small-4k.bin' })[0].sha256)) ('disk=' + $onDisk.Substring(0, 12))

$existing = Join-Path $dsDir 'small-4k.bin'
$beforeHash = (Get-FileHash -LiteralPath $existing -Algorithm SHA256).Hash
$beforeLen = (Get-Item -LiteralPath $existing).Length
$w = New-Rg353psWriteFile -Path $existing -Size 4096
$afterHash = (Get-FileHash -LiteralPath $existing -Algorithm SHA256).Hash
Add-Result 'CreateNew refuses to overwrite an existing file' ((-not $w.ok) -and $afterHash -eq $beforeHash -and (Get-Item -LiteralPath $existing).Length -eq $beforeLen) ('error=' + $w.error)

$ds2 = New-Rg353psWriteDataset -DatasetDir $dsDir -Files $specs
Add-Result 'existing dataset directory is a hard stop' ($ds2.aborted -and $ds2.abort_reason -eq 'dataset_dir_exists') ('reason=' + $ds2.abort_reason)

$unsafeDir = Join-Path $TempRoot 'unsafe'
$badSpecs = @([pscustomobject]@{ relpath = '..\evil.bin'; size = 16; kind = 'unsafe' })
$ds3 = New-Rg353psWriteDataset -DatasetDir $unsafeDir -Files $badSpecs
Add-Result 'unsafe spec aborts before creating anything' ($ds3.aborted -and $ds3.abort_reason -eq 'unsafe_relative_path' -and -not (Test-Path -LiteralPath $unsafeDir)) ('reason=' + $ds3.abort_reason + ' dirExists=' + (Test-Path -LiteralPath $unsafeDir))

$w2 = New-Rg353psWriteFile -Path (Join-Path $TempRoot 'nope\deep\x.bin') -Size 16
Add-Result 'missing parent directory is rejected' (-not $w2.ok) $w2.error

# ---------------------------------------------------------------------------
# D. Manifest validation
# ---------------------------------------------------------------------------
$goodFiles = @(
    [ordered]@{ relpath = 'a.bin'; size = 4096; sha256 = ('a' * 64) },
    [ordered]@{ relpath = 'dir/b with space.txt'; size = 1024; sha256 = ('b' * 64) }
)
function New-ManifestObject {
    param($Files, [string]$DatasetName = 'baseos-write-test-x')
    return [pscustomobject]@{ tool = 'rg353ps-mass-storage-write-check'; phase = 'Prepare'
        run_id = 'x'; dataset_name = $DatasetName; files = $Files }
}
$m = New-ManifestObject $goodFiles
$v = Test-Rg353psWriteManifestObject -Manifest $m
Add-Result 'accepts a well-formed manifest' $v.Ok $v.Reason
$v = Test-Rg353psWriteManifestObject -Manifest (New-ManifestObject @())
Add-Result 'rejects an empty files array' (-not $v.Ok) $v.Reason
$v = Test-Rg353psWriteManifestObject -Manifest ([pscustomobject]@{ run_id = 'x' })
Add-Result 'rejects a manifest without files' (-not $v.Ok) $v.Reason
$v = Test-Rg353psWriteManifestObject -Manifest (New-ManifestObject @([ordered]@{ relpath = '..\x.bin'; size = 1; sha256 = ('c' * 64) }))
Add-Result 'rejects a traversal entry in the manifest' (-not $v.Ok) $v.Reason
$v = Test-Rg353psWriteManifestObject -Manifest (New-ManifestObject @([ordered]@{ relpath = 'C:\x.bin'; size = 1; sha256 = ('c' * 64) }))
Add-Result 'rejects an absolute entry in the manifest' (-not $v.Ok) $v.Reason
$v = Test-Rg353psWriteManifestObject -Manifest (New-ManifestObject @([ordered]@{ relpath = 'a.bin'; size = 1; sha256 = 'not-a-hash' }))
Add-Result 'rejects a malformed SHA-256' (-not $v.Ok) $v.Reason
$v = Test-Rg353psWriteManifestObject -Manifest (New-ManifestObject @([ordered]@{ relpath = 'a.bin'; size = -1; sha256 = ('d' * 64) }))
Add-Result 'rejects a negative size' (-not $v.Ok) $v.Reason
$v = Test-Rg353psWriteManifestObject -Manifest (New-ManifestObject @(
    [ordered]@{ relpath = 'a.bin'; size = 1; sha256 = ('e' * 64) },
    [ordered]@{ relpath = 'a.bin'; size = 2; sha256 = ('f' * 64) }))
Add-Result 'rejects duplicate entries' (-not $v.Ok) $v.Reason
$v = Test-Rg353psWriteManifestObject -Manifest (New-ManifestObject $goodFiles '..\escape')
Add-Result 'rejects a dataset_name that contains a path' (-not $v.Ok) $v.Reason
$v = Test-Rg353psWriteManifestObject -Manifest (New-ManifestObject @([ordered]@{ relpath = 'a.bin'; sha256 = ('a' * 64) }))
Add-Result 'rejects an entry missing size' (-not $v.Ok) $v.Reason

$notJson = Join-Path $TempRoot 'broken.json'
[System.IO.File]::WriteAllText($notJson, '{ this is not json', (New-Object System.Text.UTF8Encoding($false)))
$v = Read-Rg353psWriteManifest -Path $notJson
Add-Result 'rejects a non-JSON manifest file' (-not $v.Ok) $v.Reason
$v = Read-Rg353psWriteManifest -Path (Join-Path $TempRoot 'absent.json')
Add-Result 'reports a missing manifest file' (-not $v.Ok) $v.Reason

# ---------------------------------------------------------------------------
# E. Verification: size, hash, missing file, missing directory
# ---------------------------------------------------------------------------
$vDir = Join-Path $TempRoot 'verify'
New-Item -ItemType Directory -Path $vDir -Force | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $vDir 'a.bin'), (New-Object byte[] 1024))
[System.IO.File]::WriteAllBytes((Join-Path $vDir 'b.bin'), (New-Object byte[] 2048))
$mFiles = @(
    [ordered]@{ relpath = 'a.bin'; size = 1024; sha256 = (Get-FileHash -LiteralPath (Join-Path $vDir 'a.bin') -Algorithm SHA256).Hash.ToLower() },
    [ordered]@{ relpath = 'b.bin'; size = 2048; sha256 = (Get-FileHash -LiteralPath (Join-Path $vDir 'b.bin') -Algorithm SHA256).Hash.ToLower() }
)
$manifest = New-ManifestObject $mFiles
$cmp = Compare-Rg353psWriteManifest -Manifest $manifest -DatasetDir $vDir
Add-Result 'verifies matching files' ($cmp.Ok -and @($cmp.Files | Where-Object { $_.status -eq 'match' }).Count -eq 2) $cmp.Reason

$truncated = Join-Path $TempRoot 'verify2'
Copy-Item -LiteralPath $vDir -Destination $truncated -Recurse
[System.IO.File]::WriteAllBytes((Join-Path $truncated 'a.bin'), (New-Object byte[] 10))
$cmp = Compare-Rg353psWriteManifest -Manifest $manifest -DatasetDir $truncated
$row = @($cmp.Files | Where-Object { $_.relpath -eq 'a.bin' })[0]
Add-Result 'detects a size mismatch' ((-not $cmp.Ok) -and $row.status -eq 'size_mismatch') ('status=' + $row.status)

$tampered = Join-Path $TempRoot 'verify3'
Copy-Item -LiteralPath $vDir -Destination $tampered -Recurse
$bytes = New-Object byte[] 1024
$bytes[0] = 0x7F
[System.IO.File]::WriteAllBytes((Join-Path $tampered 'a.bin'), $bytes)
$cmp = Compare-Rg353psWriteManifest -Manifest $manifest -DatasetDir $tampered
$row = @($cmp.Files | Where-Object { $_.relpath -eq 'a.bin' })[0]
Add-Result 'detects a SHA-256 mismatch at unchanged size' ((-not $cmp.Ok) -and $row.status -eq 'sha256_mismatch') ('status=' + $row.status + ' size=' + $row.actual_size)

$missing = Join-Path $TempRoot 'verify4'
Copy-Item -LiteralPath $vDir -Destination $missing -Recurse
$gone = Join-Path $missing 'b.bin'
$goneHash = (Get-FileHash -LiteralPath $gone -Algorithm SHA256).Hash
Remove-Item -LiteralPath $gone -Force
$cmp = Compare-Rg353psWriteManifest -Manifest $manifest -DatasetDir $missing
$row = @($cmp.Files | Where-Object { $_.relpath -eq 'b.bin' })[0]
Add-Result 'reports a missing file and never recreates it' ((-not $cmp.Ok) -and $row.status -eq 'missing' -and -not (Test-Path -LiteralPath $gone)) ('status=' + $row.status)

$cmp = Compare-Rg353psWriteManifest -Manifest $manifest -DatasetDir (Join-Path $TempRoot 'no-such-dataset')
Add-Result 'missing dataset directory is reported' (-not $cmp.Ok) $cmp.Reason

# ---------------------------------------------------------------------------
# F. Strict mapping failures (injected topology, subprocess)
# ---------------------------------------------------------------------------
$cases = @(
    @{ name = 'zero PID_0006 roots'; topo = (New-WriteTopology -RootCount 0); expect = 'device_absent' },
    @{ name = 'two PID_0006 roots'; topo = (New-WriteTopology -RootCount 2); expect = 'device_duplicated' },
    @{ name = 'no PnP child'; topo = (New-WriteTopology -NoChild); expect = 'child_missing' },
    @{ name = 'two disks claim the same child'; topo = (New-WriteTopology -DuplicateDisk); expect = 'disk_mapping_ambiguous' },
    @{ name = 'RAW filesystem'; topo = (New-WriteTopology -Raw); expect = 'filesystem_raw' },
    @{ name = 'two volumes on the target disk'; topo = (New-WriteTopology -MatchedVolumes 2); expect = 'ioctl_not_unique' }
)
$idx = 0
foreach ($c in $cases) {
    $idx++
    $mock = Write-MockTopology -Name ('mock-' + $idx) -Topology $c.topo
    $sub = Join-Path $TempRoot ('sub-prepare-' + $idx)
    New-Item -ItemType Directory -Path $sub -Force | Out-Null
    $res = Invoke-WriteTool -Arguments @('-Phase', 'Prepare', '-TopologyMockPath', $mock, '-OutDir', $sub, '-ReportBaseName', 'r')
    $rep = Read-JsonReport (Join-Path $sub 'r.json')
    $reason = ''
    if ($null -ne $rep) { $reason = [string]$rep.evidence.abort_reason }
    $noFiles = ($null -ne $rep) -and ($null -eq $rep.evidence.files -or @($rep.evidence.files).Count -eq 0)
    $fileCount = $(if ($null -eq $rep.evidence.files) { 0 } else { @($rep.evidence.files).Count })
    Add-Result ('mapping abort: ' + $c.name) ($res.ExitCode -eq 1 -and $reason -eq $c.expect -and $noFiles) ('exit=' + $res.ExitCode + ' reason=' + $reason + ' files=' + $fileCount)
}

$goodMock = Write-MockTopology -Name 'mock-good' -Topology (New-WriteTopology -RootCount 1)
$target = Get-Rg353psWriteTarget -TopologyMockPath $goodMock
Add-Result 'accepts the unique topology without writing' ($target.Ok -and $target.Drive -eq $TempDrive -and $target.Map.Path -eq 'superfloppy') ('ok=' + $target.Ok + ' drive=' + $target.Drive + ' path=' + $target.Map.Path)

# ---------------------------------------------------------------------------
# G. Verify-phase hard stops
# ---------------------------------------------------------------------------
$subV = Join-Path $TempRoot 'sub-verify'
New-Item -ItemType Directory -Path $subV -Force | Out-Null
$res = Invoke-WriteTool -Arguments @('-Phase', 'Verify', '-LocalManifestPath', (Join-Path $TempRoot 'no-manifest.json'), '-OutDir', $subV, '-ReportBaseName', 'v')
$rep = Read-JsonReport (Join-Path $subV 'v.json')
Add-Result 'Verify stops when the local manifest is missing' ($res.ExitCode -eq 1 -and [string]$rep.evidence.abort_reason -eq 'local_manifest_missing_or_invalid' -and $null -eq $rep.evidence.files) ('exit=' + $res.ExitCode + ' reason=' + [string]$rep.evidence.abort_reason)

$localManifestFixture = Join-Path $TempRoot 'manifest-for-verify.json'
$fixture = New-ManifestObject @([ordered]@{ relpath = 'a.bin'; size = 1; sha256 = ('a' * 64) }) 'baseos-write-test-absent'
[System.IO.File]::WriteAllText($localManifestFixture, ($fixture | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
$res = Invoke-WriteTool -Arguments @('-Phase', 'Verify', '-LocalManifestPath', $localManifestFixture, '-TopologyMockPath', $goodMock, '-OutDir', $subV, '-ReportBaseName', 'v2')
$rep = Read-JsonReport (Join-Path $subV 'v2.json')
Add-Result 'Verify stops when the dataset directory is absent' ($res.ExitCode -eq 1 -and [string]$rep.evidence.abort_reason -eq 'dataset_dir_missing') ('exit=' + $res.ExitCode + ' reason=' + [string]$rep.evidence.abort_reason)

$res = Invoke-WriteTool -Arguments @('-Phase', 'None', '-OutDir', $TempRoot)
Add-Result 'Phase None performs no device access' ($res.ExitCode -eq 0 -and $res.Output -match 'No device access') ('exit=' + $res.ExitCode)

# ---------------------------------------------------------------------------
# H. Static read-only / safety guards
# ---------------------------------------------------------------------------
$src = Get-Content -LiteralPath $WriteScript -Raw -Encoding UTF8
$forbidden = @('Format-Volume', 'Initialize-Disk', 'Clear-Disk', 'Set-Partition', 'New-Partition',
    'diskpart', 'Repair-Volume', 'Remove-Item', 'Remove-Partition', 'Set-Partition',
    'chkdsk', 'mountvol', 'subst ', 'Shell.Application', 'Eject')
$hits = @($forbidden | Where-Object { $src -cmatch [regex]::Escape($_) })
Add-Result 'no mutating or destructive cmdlets in the tool' ($hits.Count -eq 0) ('hits=' + ($hits -join ','))

Add-Result 'uses FileMode.CreateNew for payloads' ($src -match 'FileMode\]::CreateNew' -and $src -match 'CreateNew') 'CreateNew present'
Add-Result 'flushes to disk with Flush(true)' ($src -match 'Flush\(\$true\)') 'Flush(true) present'
Add-Result 'reuses the strict resolver and IOCTL ownership proof' (($src -match 'Rg353psDeviceMap\.ps1') -and ($src -match 'Resolve-Rg353psTarget') -and ($src -match 'Get-Rg353psIoctlVolumeMap')) 'resolver reuse present'
Add-Result 'has no fallback scan of USB disks or exFAT guessing' (-not ($src -match 'Get-CimInstance Win32_DiskDrive\s*\)?\s*\|\s*Where-Object \{\s*\$_.InterfaceType -eq ''USB''\s*\}')) 'no scan pattern'
Add-Result 'declares Prepare and Verify phases' (($src -match "ValidateSet\('Prepare', 'Verify'") -and ($src -match 'function Invoke-Rg353psWritePrepare') -and ($src -match 'function Invoke-Rg353psWriteVerify')) 'phases present'
$nonAscii = 0
foreach ($b in [System.IO.File]::ReadAllBytes($WriteScript)) { if ($b -gt 127) { $nonAscii++ } }
Add-Result 'tool source stays pure ASCII' ($nonAscii -eq 0) ('non-ascii bytes=' + $nonAscii)

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$pass = @($Results | Where-Object { $_.pass }).Count
$fail = @($Results | Where-Object { -not $_.pass }).Count
$summary = [ordered]@{
    tool = 'rg353ps-mass-storage-write-check'
    suite = 'offline'
    hardware_contacted = $false
    created_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    cases = @($Results).Count
    pass = $pass
    fail = $fail
    results = @($Results)
}
[System.IO.File]::WriteAllText($OutJson, ($summary | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host ('TOTAL: ' + $pass + '/' + @($Results).Count + ' PASS, ' + $fail + ' FAIL')
Write-Host ('Results: ' + $OutJson)
try { Remove-Item -LiteralPath $TempRoot -Recurse -Force } catch { }
if ($fail -gt 0) { exit 1 }
exit 0
