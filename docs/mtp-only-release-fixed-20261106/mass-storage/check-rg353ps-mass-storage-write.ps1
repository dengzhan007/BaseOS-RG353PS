# RG353PS Mass Storage - write-integrity tool (Prepare / Verify), Windows host.
#
# Two phases, run one at a time by an operator:
#   Prepare: create ONE new unique directory on the already-proven volume and
#            write 4 KiB / 1 MiB / 128 MiB payloads plus Unicode, space and
#            deep-path names. Every file is opened with FileMode.CreateNew, so
#            an existing file is never overwritten. Each stream is Flush(true)'d
#            and SHA-256 is computed while writing. A local manifest AND a
#            device-side manifest are written.
#   Verify:  re-run the strict device mapping from scratch and compare every
#            file against the local manifest (size + SHA-256). Verify never
#            writes to the device.
#
# Target selection is the same strict chain as the read-only checker:
#   USB\VID_2207&PID_0006 -> PnP children (USBSTOR) -> Win32_DiskDrive
#   -> [partitioned] partition chain, or
#   -> [superfloppy] volume GUID -> read-only IOCTL_STORAGE_GET_DEVICE_NUMBER
#                    -> DeviceNumber == the confirmed PHYSICALDRIVE index
# There is no scan of other USB disks and no "guess by exFAT" fallback.
#
# Hard stops, before any volume is touched: a Windows format prompt, an
# ambiguous or missing device identity, a RAW/unknown filesystem, a dataset
# directory that already exists (Prepare), a missing dataset directory or
# missing local manifest (Verify), and any unsafe relative path in a manifest.
# Nothing is deleted, formatted, repaired or re-lettered, and the device is
# never ejected by this tool.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\check-rg353ps-mass-storage-write.ps1 -Phase Prepare
#   (operator: safe eject, unplug, wait for recovery, re-enter Mass Storage)
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\check-rg353ps-mass-storage-write.ps1 -Phase Verify
#
# -Phase None only defines the functions; it is used by the offline tests and
# performs no device access.
[CmdletBinding()]
param(
    [ValidateSet('Prepare', 'Verify', 'None')]
    [string]$Phase = 'None',
    [string]$RunId = '20261106-131355-4a3405',
    [int]$ProbeRetries = 3,
    [int]$ProbeIntervalSeconds = 5,
    [string]$TopologyMockPath = '',
    [string]$OutDir = '',
    [string]$LocalManifestPath = '',
    [string]$ReportBaseName = ''
)

$ErrorActionPreference = 'Continue'

# $PSScriptRoot is not reliable inside a param() default under -File on
# Windows PowerShell 5.1, so resolve the default output directory here.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = $ScriptDir }

$Module = Join-Path $ScriptDir 'Rg353psDeviceMap.ps1'
if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
    Write-Host 'FAIL: Rg353psDeviceMap.ps1 is missing next to this script.' -ForegroundColor Red
    exit 1
}
. $Module

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:DatasetPrefix = 'baseos-write-test-'
$script:DeviceManifestName = 'baseos-write-test-manifest.json'
$script:WriteChecks = New-Object System.Collections.ArrayList
$script:WriteFailures = New-Object System.Collections.ArrayList
$script:WriteEvidence = [ordered]@{}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function Add-Rg353psWriteCheck {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $entry = [ordered]@{ name = $Name; status = $(if ($Ok) { 'PASS' } else { 'FAIL' }); detail = $Detail }
    [void]$script:WriteChecks.Add($entry)
    if (-not $Ok) { [void]$script:WriteFailures.Add(($Name + ': ' + $Detail)) }
}

function ConvertFrom-Rg353psWriteCodePoint {
    # Keeps this file pure ASCII: Windows PowerShell 5.1 reads .ps1 as ANSI
    # unless a BOM is present, so non-ASCII literals would be mangled.
    param([int[]]$CodePoint)
    $s = ''
    foreach ($c in $CodePoint) { $s += [string][char]$c }
    return $s
}

function Get-Rg353psWriteFormatPrompt {
    $cnFormat = ConvertFrom-Rg353psWriteCodePoint @(0x683C, 0x5F0F, 0x5316)
    $pattern = 'format|You need to format|' + $cnFormat
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowTitle -match $pattern
    })
}

function Get-Rg353psWriteReasonKind {
    # Short, reportable kind for a resolver reason string.
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

# ---------------------------------------------------------------------------
# Path safety: a manifest entry must stay inside the dataset directory
# ---------------------------------------------------------------------------

function Test-Rg353psWriteSafeRelativePath {
    param([string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'empty relative path'; Segments = @() }
    }
    $p = [string]$RelativePath
    if ($p -match '^[A-Za-z]:[\\/]') {
        return [pscustomobject]@{ Ok = $false; Reason = 'drive-qualified path'; Segments = @() }
    }
    if ($p.StartsWith('\\') -or $p.StartsWith('//')) {
        return [pscustomobject]@{ Ok = $false; Reason = 'UNC path'; Segments = @() }
    }
    if ($p.StartsWith('\') -or $p.StartsWith('/')) {
        return [pscustomobject]@{ Ok = $false; Reason = 'rooted path'; Segments = @() }
    }
    if ($p -match '[\x00-\x1F]') {
        return [pscustomobject]@{ Ok = $false; Reason = 'control character in path'; Segments = @() }
    }
    if ($p -match ':') {
        return [pscustomobject]@{ Ok = $false; Reason = 'colon or alternate data stream in path'; Segments = @() }
    }
    $segments = @($p -split '[\\/]')
    foreach ($s in $segments) {
        if ($s -eq '') {
            return [pscustomobject]@{ Ok = $false; Reason = 'empty path segment'; Segments = @() }
        }
        if ($s -eq '.' -or $s -eq '..') {
            return [pscustomobject]@{ Ok = $false; Reason = 'relative traversal segment'; Segments = @() }
        }
        if ($s -match '^[ ]+$') {
            return [pscustomobject]@{ Ok = $false; Reason = 'whitespace-only path segment'; Segments = @() }
        }
    }
    return [pscustomobject]@{ Ok = $true; Reason = 'relative path stays inside the dataset directory'; Segments = $segments }
}

function Resolve-Rg353psWriteItemPath {
    # Joins and re-normalises, then proves the result is still under the root.
    # A plain StartsWith is not enough: '\data\a' must not accept '\data\ab'.
    param([string]$Root, [string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        return [pscustomobject]@{ Ok = $false; Path = ''; Reason = 'empty dataset root' }
    }
    $check = Test-Rg353psWriteSafeRelativePath -RelativePath $RelativePath
    if (-not $check.Ok) {
        return [pscustomobject]@{ Ok = $false; Path = ''; Reason = $check.Reason }
    }
    try {
        $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
        $joined = $RelativePath -replace '/', '\'
        $full = [System.IO.Path]::GetFullPath((Join-Path $rootFull $joined))
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Path = ''; Reason = ('path normalisation failed: ' + $_.Exception.Message) }
    }
    $prefix = $rootFull + '\'
    if ($full -eq $rootFull) {
        return [pscustomobject]@{ Ok = $false; Path = ''; Reason = 'path resolves to the dataset root itself' }
    }
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Ok = $false; Path = ''; Reason = 'path escapes the dataset directory' }
    }
    return [pscustomobject]@{ Ok = $true; Path = $full; Reason = 'inside dataset' }
}

# ---------------------------------------------------------------------------
# Payload specification and single-file writer
# ---------------------------------------------------------------------------

function Get-Rg353psWriteFileSpecs {
    # Seven payloads: three sizes plus Unicode, spaces and deep paths.
    $cnName = (ConvertFrom-Rg353psWriteCodePoint @(0x4E2D, 0x6587, 0x6587, 0x4EF6, 0x540D)) + '.txt'
    $cnDir = (ConvertFrom-Rg353psWriteCodePoint @(0x4E2D, 0x6587)) + ' ' +
             (ConvertFrom-Rg353psWriteCodePoint @(0x76EE, 0x5F55)) + ' with spaces'
    $cnSub = (ConvertFrom-Rg353psWriteCodePoint @(0x5D4C, 0x5957)) + ' ' +
             (ConvertFrom-Rg353psWriteCodePoint @(0x5B50, 0x76EE, 0x5F55))
    $cnDeep = (ConvertFrom-Rg353psWriteCodePoint @(0x6DF1, 0x5C42)) + ' ' +
              (ConvertFrom-Rg353psWriteCodePoint @(0x6587, 0x4EF6)) + '.txt'

    return @(
        [pscustomobject]@{ relpath = 'small-4k.bin'; size = 4096; kind = '4KiB' }
        [pscustomobject]@{ relpath = 'medium-1m.bin'; size = 1048576; kind = '1MiB' }
        [pscustomobject]@{ relpath = $cnName; size = 4096; kind = 'unicode-name' }
        [pscustomobject]@{ relpath = 'name with spaces.txt'; size = 65536; kind = 'space-name' }
        [pscustomobject]@{ relpath = 'nested/sub/deep.bin'; size = 262144; kind = 'three-level-ascii' }
        [pscustomobject]@{ relpath = ($cnDir + '/' + $cnSub + '/' + $cnDeep); size = 65536; kind = 'three-level-unicode' }
        [pscustomobject]@{ relpath = 'large-128m.bin'; size = 134217728; kind = '128MiB' }
    )
}

function New-Rg353psWriteFile {
    # CreateNew only: an existing target is an error, never an overwrite.
    # Data is hashed while it is written, and the stream is Flush(true)'d.
    param(
        [string]$Path,
        [long]$Size,
        [int]$BlockBytes = 1048576,
        [int]$SeedBase = 1
    )

    $existedBefore = $false
    try { $existedBefore = [bool](Test-Path -LiteralPath $Path) } catch { $existedBefore = $false }
    if ($existedBefore) {
        return [pscustomobject]@{ ok = $false; size = $null; sha256 = ''; created = $false; existed_before = $true; error = 'target already exists; CreateNew refuses to overwrite' }
    }
    if ($Size -lt 0) {
        return [pscustomobject]@{ ok = $false; size = $null; sha256 = ''; created = $false; existed_before = $false; error = 'negative size' }
    }
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        return [pscustomobject]@{ ok = $false; size = $null; sha256 = ''; created = $false; existed_before = $false; error = 'parent directory does not exist' }
    }
    if ($BlockBytes -le 0) { $BlockBytes = 1048576 }

    $fs = $null
    $hash = $null
    $sha = ''
    $errText = ''
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $hash = [System.Security.Cryptography.IncrementalHash]::CreateHash(
            [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $remaining = $Size
        $seed = $SeedBase
        while ($remaining -gt 0) {
            $n = [int][math]::Min([long]$BlockBytes, $remaining)
            $buf = New-Object byte[] $n
            (New-Object System.Random $seed).NextBytes($buf)
            $fs.Write($buf, 0, $n)
            $hash.AppendData($buf)
            $remaining -= $n
            $seed++
        }
        $fs.Flush($true)
        $sha = [System.BitConverter]::ToString($hash.GetHashAndReset()).Replace('-', '').ToLower()
    }
    catch {
        $errText = $_.Exception.Message
    }
    finally {
        if ($null -ne $hash) { $hash.Dispose() }
        if ($null -ne $fs) {
            try { $fs.Dispose() } catch { }
        }
    }

    if (-not [string]::IsNullOrEmpty($errText)) {
        return [pscustomobject]@{ ok = $false; size = $null; sha256 = $sha; created = $true; existed_before = $false; error = $errText }
    }
    $actual = $null
    try { $actual = [long](Get-Item -LiteralPath $Path -ErrorAction Stop).Length } catch { $actual = $null }
    if ($null -eq $actual -or $actual -ne $Size) {
        return [pscustomobject]@{ ok = $false; size = $actual; sha256 = $sha; created = $true; existed_before = $false; error = ('size mismatch after write: expected ' + $Size + ', got ' + $actual) }
    }
    return [pscustomobject]@{ ok = $true; size = $actual; sha256 = $sha; created = $true; existed_before = $false; error = '' }
}

function Write-Rg353psWriteTextNew {
    # CreateNew text write with Flush(true); used for both manifests.
    param([string]$Path, [string]$Text)

    if (Test-Path -LiteralPath $Path) {
        return [pscustomobject]@{ ok = $false; error = 'target already exists; CreateNew refuses to overwrite' }
    }
    $fs = $null
    $errText = ''
    try {
        $bytes = $script:Utf8NoBom.GetBytes($Text)
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush($true)
    }
    catch {
        $errText = $_.Exception.Message
    }
    finally {
        if ($null -ne $fs) {
            try { $fs.Dispose() } catch { }
        }
    }
    if ($errText) { return [pscustomobject]@{ ok = $false; error = $errText } }
    return [pscustomobject]@{ ok = $true; error = '' }
}

function New-Rg353psWriteDataset {
    # Creates the unique dataset directory and every payload. Refuses to run at
    # all if the directory already exists, and preflights every target path
    # before the first byte is written.
    param(
        [string]$DatasetDir,
        [array]$Files,
        [int]$BlockBytes = 1048576
    )

    $result = [ordered]@{
        ok = $false; aborted = $false; abort_reason = ''; abort_detail = ''
        dataset_dir = $DatasetDir; files = @()
    }
    if ([string]::IsNullOrWhiteSpace($DatasetDir)) {
        $result.aborted = $true
        $result.abort_reason = 'dataset_dir_empty'
        $result.abort_detail = 'no dataset directory was provided'
        return [pscustomobject]$result
    }
    if (Test-Path -LiteralPath $DatasetDir) {
        $result.aborted = $true
        $result.abort_reason = 'dataset_dir_exists'
        $result.abort_detail = 'the unique dataset directory already exists; nothing was written'
        return [pscustomobject]$result
    }

    foreach ($f in @($Files)) {
        $r = Resolve-Rg353psWriteItemPath -Root $DatasetDir -RelativePath $f.relpath
        if (-not $r.Ok) {
            $result.aborted = $true
            $result.abort_reason = 'unsafe_relative_path'
            $result.abort_detail = ([string]$f.relpath + ': ' + $r.Reason)
            return [pscustomobject]$result
        }
        if (Test-Path -LiteralPath $r.Path) {
            $result.aborted = $true
            $result.abort_reason = 'target_file_exists'
            $result.abort_detail = ($r.Path + ' already exists; nothing was written')
            return [pscustomobject]$result
        }
    }

    try {
        [void][System.IO.Directory]::CreateDirectory($DatasetDir)
    }
    catch {
        $result.aborted = $true
        $result.abort_reason = 'dataset_dir_create_failed'
        $result.abort_detail = $_.Exception.Message
        return [pscustomobject]$result
    }

    $rows = New-Object System.Collections.ArrayList
    $specIndex = 0
    foreach ($f in @($Files)) {
        $specIndex++
        $r = Resolve-Rg353psWriteItemPath -Root $DatasetDir -RelativePath $f.relpath
        $row = [ordered]@{
            relpath = [string]$f.relpath
            kind = [string]$f.kind
            expected_size = [long]$f.size
            written = $false
            actual_size = $null
            sha256 = ''
            status = 'pending'
            error = ''
        }
        if (-not $r.Ok) {
            $row.status = 'failed'
            $row.error = $r.Reason
            [void]$rows.Add($row)
            $result.aborted = $true
            $result.abort_reason = 'unsafe_relative_path'
            $result.abort_detail = ([string]$f.relpath + ': ' + $r.Reason)
            break
        }
        $parent = [System.IO.Path]::GetDirectoryName($r.Path)
        if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            try { [void][System.IO.Directory]::CreateDirectory($parent) }
            catch {
                $row.status = 'failed'
                $row.error = 'parent directory create failed: ' + $_.Exception.Message
                [void]$rows.Add($row)
                $result.aborted = $true
                $result.abort_reason = 'parent_dir_create_failed'
                $result.abort_detail = $row.error
                break
            }
        }
        $w = New-Rg353psWriteFile -Path $r.Path -Size ([long]$f.size) -BlockBytes $BlockBytes -SeedBase ($specIndex * 7919)
        $row.written = [bool]$w.ok
        $row.actual_size = $w.size
        $row.sha256 = [string]$w.sha256
        $row.status = $(if ($w.ok) { 'written' } else { 'failed' })
        $row.error = [string]$w.error
        [void]$rows.Add($row)
        if (-not $w.ok) {
            $result.aborted = $true
            $result.abort_reason = 'write_failed'
            $result.abort_detail = ([string]$f.relpath + ': ' + [string]$w.error)
            break
        }
    }

    $result.files = @($rows)
    $result.ok = (-not $result.aborted) -and (@($rows | Where-Object { -not $_.written }).Count -eq 0)
    return [pscustomobject]$result
}

# ---------------------------------------------------------------------------
# Manifests: local (authoritative for Verify) and device-side
# ---------------------------------------------------------------------------

function Test-Rg353psWriteProperty {
    # Manifests arrive either as ConvertFrom-Json objects (PSObject) or, when a
    # caller builds one in memory, as an ordered dictionary. Accept both.
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return [bool]$Object.Contains($Name) }
    return (@($Object.PSObject.Properties.Name) -contains $Name)
}

function Get-Rg353psWriteProperty {
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    if (@($Object.PSObject.Properties.Name) -contains $Name) { return $Object.$Name }
    return $null
}

function Test-Rg353psWriteManifestObject {
    # Validates structure and every entry. A malformed manifest is never used
    # to address files, so a tampered or truncated manifest cannot redirect
    # Verify outside the dataset directory.
    param($Manifest)

    if ($null -eq $Manifest) {
        return [pscustomobject]@{ Ok = $false; Reason = 'manifest is empty' }
    }
    if (-not (Test-Rg353psWriteProperty $Manifest 'files')) {
        return [pscustomobject]@{ Ok = $false; Reason = 'manifest has no files array' }
    }
    $files = @(Get-Rg353psWriteProperty $Manifest 'files')
    if ($files.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Reason = 'manifest files array is empty' }
    }
    if (Test-Rg353psWriteProperty $Manifest 'dataset_name') {
        $dn = [string](Get-Rg353psWriteProperty $Manifest 'dataset_name')
        if (-not [string]::IsNullOrWhiteSpace($dn)) {
            if ($dn -match '[\\/]' -or $dn -match '^[A-Za-z]:' -or $dn -match '\.\.') {
                return [pscustomobject]@{ Ok = $false; Reason = 'dataset_name is not a single safe directory name' }
            }
        }
    }
    $seen = @{}
    foreach ($f in $files) {
        foreach ($need in @('relpath', 'size', 'sha256')) {
            if (-not (Test-Rg353psWriteProperty $f $need)) {
                return [pscustomobject]@{ Ok = $false; Reason = ('file entry is missing ' + $need) }
            }
        }
        $rel = [string](Get-Rg353psWriteProperty $f 'relpath')
        $check = Test-Rg353psWriteSafeRelativePath -RelativePath $rel
        if (-not $check.Ok) {
            return [pscustomobject]@{ Ok = $false; Reason = ('unsafe relpath ' + $rel + ': ' + $check.Reason) }
        }
        if ($seen.ContainsKey($rel)) {
            return [pscustomobject]@{ Ok = $false; Reason = ('duplicate relpath ' + $rel) }
        }
        $seen[$rel] = $true
        $size = 0
        try { $size = [long](Get-Rg353psWriteProperty $f 'size') }
        catch {
            return [pscustomobject]@{ Ok = $false; Reason = ('non-numeric size for ' + $rel) }
        }
        if ($size -lt 0) {
            return [pscustomobject]@{ Ok = $false; Reason = ('negative size for ' + $rel) }
        }
        $sha = [string](Get-Rg353psWriteProperty $f 'sha256')
        if ($sha -notmatch '^[0-9a-fA-F]{64}$') {
            return [pscustomobject]@{ Ok = $false; Reason = ('sha256 is not 64 hex characters for ' + $rel) }
        }
    }
    return [pscustomobject]@{ Ok = $true; Reason = ('manifest lists ' + $files.Count + ' entries') }
}

function Read-Rg353psWriteManifest {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'manifest file not found: ' + [string]$Path; Manifest = $null }
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Reason = ('manifest is not valid JSON: ' + $_.Exception.Message); Manifest = $null }
    }
    $check = Test-Rg353psWriteManifestObject -Manifest $obj
    if (-not $check.Ok) {
        return [pscustomobject]@{ Ok = $false; Reason = $check.Reason; Manifest = $obj }
    }
    return [pscustomobject]@{ Ok = $true; Reason = $check.Reason; Manifest = $obj }
}

function Compare-Rg353psWriteManifest {
    # Read-only comparison of every manifest entry against the dataset.
    # Missing files are reported, never created, repaired or re-hashed twice.
    param($Manifest, [string]$DatasetDir)

    $rows = New-Object System.Collections.ArrayList
    $failures = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $DatasetDir -PathType Container)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'dataset directory is missing'; Files = @(); Failures = @('dataset directory is missing') }
    }
    foreach ($f in @(Get-Rg353psWriteProperty $Manifest 'files')) {
        $rel = [string](Get-Rg353psWriteProperty $f 'relpath')
        $row = [ordered]@{
            relpath = $rel
            expected_size = [long](Get-Rg353psWriteProperty $f 'size')
            actual_size = $null
            expected_sha256 = ([string](Get-Rg353psWriteProperty $f 'sha256')).ToLower()
            actual_sha256 = ''
            present = $false
            size_ok = $false
            sha256_ok = $false
            status = 'missing'
            error = ''
        }
        $r = Resolve-Rg353psWriteItemPath -Root $DatasetDir -RelativePath $rel
        if (-not $r.Ok) {
            $row.status = 'unsafe_path'
            $row.error = $r.Reason
            [void]$rows.Add($row)
            [void]$failures.Add(($rel + ': ' + $r.Reason))
            continue
        }
        if (-not (Test-Path -LiteralPath $r.Path -PathType Leaf)) {
            [void]$rows.Add($row)
            [void]$failures.Add(($rel + ': file is missing'))
            continue
        }
        $row.present = $true
        try {
            $item = Get-Item -LiteralPath $r.Path -ErrorAction Stop
            $row.actual_size = [long]$item.Length
            $row.size_ok = ($row.actual_size -eq $row.expected_size)
        }
        catch {
            $row.error = $_.Exception.Message
        }
        if ($row.size_ok) {
            try {
                $row.actual_sha256 = (Get-FileHash -LiteralPath $r.Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
                $row.sha256_ok = ($row.actual_sha256 -eq $row.expected_sha256)
            }
            catch {
                $row.error = $_.Exception.Message
            }
        }
        if (-not $row.size_ok) {
            $row.status = 'size_mismatch'
            [void]$failures.Add(($rel + ': size ' + [string]$row.actual_size + ' != ' + [string]$row.expected_size))
        }
        elseif (-not $row.sha256_ok) {
            $row.status = 'sha256_mismatch'
            [void]$failures.Add(($rel + ': SHA-256 differs from the manifest'))
        }
        else {
            $row.status = 'match'
        }
        [void]$rows.Add($row)
    }
    $ok = (@($failures).Count -eq 0)
    return [pscustomobject]@{
        Ok = $ok
        Reason = $(if ($ok) { 'all manifest entries match on the device' } else { ($failures.Count.ToString() + ' manifest entrie(s) did not match') })
        Files = @($rows)
        Failures = @($failures)
    }
}

# ---------------------------------------------------------------------------
# Strict device identity (shared by both phases)
# ---------------------------------------------------------------------------

function Get-Rg353psWriteTopology {
    param([string]$TopologyMockPath = '')

    if (-not [string]::IsNullOrWhiteSpace($TopologyMockPath)) {
        $mock = Get-Content -LiteralPath $TopologyMockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $topo = [pscustomobject]@{
            PnpDevices = @($mock.PnpDevices); PnpChildren = @($mock.PnpChildren)
            Disks = @($mock.Disks); DiskPartitions = @($mock.DiskPartitions)
            Volumes = @($mock.Volumes)
        }
        return [pscustomobject]@{ Topology = $topo; IoctlVolumes = @($mock.IoctlVolumes); Source = 'offline mock' }
    }
    $live = Get-Rg353psLiveTopology
    $ioctl = @(Get-Rg353psIoctlVolumeMap -Volumes $live.Volumes)
    return [pscustomobject]@{ Topology = $live; IoctlVolumes = $ioctl; Source = 'live CIM/PnP + read-only IOCTL' }
}

function Get-Rg353psWriteTarget {
    # Returns Ok=$true with Drive/Map, or Ok=$false with an Abort kind.
    param([string]$TopologyMockPath = '', [int]$ProbeRetries = 3, [int]$ProbeIntervalSeconds = 5)

    $prompt = Get-Rg353psWriteFormatPrompt
    if (@($prompt).Count -gt 0) {
        return [pscustomobject]@{ Ok = $false; Abort = 'format_prompt'; Detail = 'a Windows format prompt is open'; Drive = ''; Map = $null; TopologySource = '' }
    }

    if ([string]::IsNullOrWhiteSpace($TopologyMockPath)) {
        $seen = $false
        for ($i = 1; $i -le [math]::Max(1, $ProbeRetries); $i++) {
            $pnp = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
                Where-Object { $_.PNPDeviceID -match 'VID_2207' })
            $roots = @($pnp | Where-Object {
                $_.PNPDeviceID -match '^USB\\VID_2207&PID_0006\\' -and $_.PNPDeviceID -notmatch '&MI_'
            })
            if ($roots.Count -eq 1) { $seen = $true; break }
            if ($i -lt $ProbeRetries) { Start-Sleep -Seconds ([math]::Max(1, $ProbeIntervalSeconds)) }
        }
        if (-not $seen) {
            return [pscustomobject]@{ Ok = $false; Abort = 'device_absent'; Detail = 'unique VID_2207&PID_0006 root did not appear within the finite probe window'; Drive = ''; Map = $null; TopologySource = 'live CIM/PnP' }
        }
    }

    $src = $null
    try {
        $src = Get-Rg353psWriteTopology -TopologyMockPath $TopologyMockPath
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Abort = 'topology_collection_failed'; Detail = $_.Exception.Message; Drive = ''; Map = $null; TopologySource = '' }
    }

    $map = Resolve-Rg353psTarget -PnpDevices $src.Topology.PnpDevices -PnpChildren $src.Topology.PnpChildren `
        -Disks $src.Topology.Disks -DiskPartitions $src.Topology.DiskPartitions `
        -Volumes $src.Topology.Volumes -IoctlVolumes $src.IoctlVolumes
    if (-not $map.Ok) {
        return [pscustomobject]@{ Ok = $false; Abort = (Get-Rg353psWriteReasonKind -Reason ([string]$map.Reason)); Detail = [string]$map.Reason; Drive = ''; Map = $map; TopologySource = $src.Source }
    }
    if ($null -eq $map.Volume -or [string]::IsNullOrEmpty([string]$map.Volume.DriveLetter)) {
        return [pscustomobject]@{ Ok = $false; Abort = 'no_drive_letter'; Detail = 'the uniquely mapped volume has no drive letter'; Drive = ''; Map = $map; TopologySource = $src.Source }
    }
    $fs = [string]$map.Volume.FileSystem
    if ($fs -notmatch '^(exFAT|FAT32)$') {
        return [pscustomobject]@{ Ok = $false; Abort = 'filesystem_unexpected'; Detail = ('target volume filesystem is ' + $fs); Drive = ''; Map = $map; TopologySource = $src.Source }
    }
    return [pscustomobject]@{ Ok = $true; Abort = ''; Detail = [string]$map.Reason; Drive = [string]$map.Volume.DriveLetter; Map = $map; TopologySource = $src.Source }
}

# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------

function Write-Rg353psWriteReport {
    param([string]$PhaseName, [string]$BaseName, [bool]$DeviceWritesPerformed, $Extra)

    $allPass = (@($script:WriteFailures).Count -eq 0)
    $report = [ordered]@{
        tool = 'rg353ps-mass-storage-write-check'
        phase = $PhaseName
        run_id = $RunId
        started_utc = $script:WriteStartedUtc
        finished_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        mode = 'USB Mass Storage (VID_2207&PID_0006)'
        device_writes = $DeviceWritesPerformed
        device_selection = 'strict PnP parent/child + WMI disk/partition/volume, or volume GUID -> PHYSICALDRIVE via read-only IOCTL_STORAGE_GET_DEVICE_NUMBER'
        evidence = $script:WriteEvidence
        checks = @($script:WriteChecks)
        failures = @($script:WriteFailures)
        pass = $allPass
    }
    if ($null -ne $Extra) {
        foreach ($k in $Extra.Keys) { $report[$k] = $Extra[$k] }
    }
    $jsonPath = Join-Path $OutDir ($BaseName + '.json')
    $mdPath = Join-Path $OutDir ($BaseName + '.md')
    if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($OutDir)
    }
    [System.IO.File]::WriteAllText($jsonPath, ($report | ConvertTo-Json -Depth 10), $script:Utf8NoBom)

    $md = New-Object System.Collections.ArrayList
    [void]$md.Add('# RG353PS Mass Storage write-integrity report (' + $PhaseName + ')')
    [void]$md.Add('')
    [void]$md.Add('- Run ID: `' + $RunId + '`')
    [void]$md.Add('- Overall: ' + $(if ($allPass) { '**PASS**' } else { '**FAIL**' }))
    [void]$md.Add('- Device writes in this phase: ' + $(if ($DeviceWritesPerformed) { 'yes (new dataset only, CreateNew, no overwrite)' } else { 'no (read-only verification)' }))
    [void]$md.Add('- Device selection: strict PnP/WMI mapping + IOCTL volume ownership; no fallback scanning')
    if ($script:WriteEvidence.Contains('abort_reason') -and $script:WriteEvidence['abort_reason']) {
        [void]$md.Add('- Aborted: `' + [string]$script:WriteEvidence['abort_reason'] + '` - ' + [string]$script:WriteEvidence['abort_detail'])
    }
    if ($script:WriteEvidence.Contains('dataset_dir')) {
        [void]$md.Add('- Dataset directory: `' + [string]$script:WriteEvidence['dataset_dir'] + '`')
    }
    if ($script:WriteEvidence.Contains('identity')) {
        $id = $script:WriteEvidence['identity']
        [void]$md.Add('- Mapping path: `' + [string]$id['path'] + '`; drive ' + [string]$id['drive'] + '; ' + [string]$id['filesystem'])
    }
    [void]$md.Add('')
    [void]$md.Add('| Check | Status | Detail |')
    [void]$md.Add('| --- | --- | --- |')
    foreach ($c in $script:WriteChecks) {
        [void]$md.Add('| ' + $c.name + ' | ' + $c.status + ' | ' + (([string]$c.detail) -replace '\|', '/') + ' |')
    }
    [void]$md.Add('')
    if ($script:WriteEvidence.Contains('files') -and @($script:WriteEvidence['files']).Count -gt 0) {
        [void]$md.Add('## Files')
        [void]$md.Add('')
        [void]$md.Add('| Relative path | Expected size | Actual size | SHA-256 match | Status |')
        [void]$md.Add('| --- | --- | --- | --- | --- |')
        foreach ($f in @($script:WriteEvidence['files'])) {
            $sha = '-'
            if ($f.Contains('sha256_ok')) { $sha = $(if ($f['sha256_ok']) { 'yes' } else { 'no' }) }
            elseif ($f.Contains('written')) { $sha = $(if ($f['written']) { 'recorded' } else { '-' }) }
            [void]$md.Add('| ' + [string]$f['relpath'] + ' | ' + [string]$f['expected_size'] + ' | ' + [string]$f['actual_size'] + ' | ' + $sha + ' | ' + [string]$f['status'] + ' |')
        }
        [void]$md.Add('')
    }
    if (@($script:WriteFailures).Count -gt 0) {
        [void]$md.Add('## Failure reasons')
        [void]$md.Add('')
        foreach ($f in $script:WriteFailures) { [void]$md.Add('- ' + $f) }
        [void]$md.Add('')
    }
    [void]$md.Add('> The test files are left on the device on purpose: this tool never')
    [void]$md.Add('> deletes, formats, repairs or re-letters anything, and never ejects the device.')
    [System.IO.File]::WriteAllText($mdPath, (($md -join "`r`n") + "`r`n"), $script:Utf8NoBom)
    return [pscustomobject]@{ Json = $jsonPath; Md = $mdPath; Pass = $allPass }
}

# ---------------------------------------------------------------------------
# Prepare
# ---------------------------------------------------------------------------

function Invoke-Rg353psWritePrepare {
    param($Context)

    $script:WriteStartedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $target = Get-Rg353psWriteTarget -TopologyMockPath $Context.TopologyMockPath `
        -ProbeRetries $ProbeRetries -ProbeIntervalSeconds $ProbeIntervalSeconds
    $script:WriteEvidence['topology_source'] = $target.TopologySource
    Add-Rg353psWriteCheck 'no_format_prompt' ($target.Abort -ne 'format_prompt') 'a Windows format prompt would be an immediate hard stop'
    if (-not $target.Ok) {
        $script:WriteEvidence['abort_reason'] = [string]$target.Abort
        $script:WriteEvidence['abort_detail'] = [string]$target.Detail
        Add-Rg353psWriteCheck 'strict_device_mapping' $false ([string]$target.Abort + ': ' + [string]$target.Detail)
        return (Write-Rg353psWriteReport -PhaseName 'Prepare' -BaseName $Context.BaseName -DeviceWritesPerformed $false -Extra $null)
    }
    Add-Rg353psWriteCheck 'strict_device_mapping' $true ('[' + [string]$target.Map.Path + '] ' + [string]$target.Detail)

    $drive = [string]$target.Drive
    $datasetName = $script:DatasetPrefix + $RunId
    $datasetDir = $drive.TrimEnd('\') + '\' + $datasetName
    $identity = [ordered]@{
        path = [string]$target.Map.Path
        drive = $drive
        filesystem = [string]$target.Map.Volume.FileSystem
        capacity = [string]$target.Map.Volume.Capacity
        free_space = [string]$target.Map.Volume.FreeSpace
        disk_device_id = [string]$target.Map.Disk.DeviceID
        disk_index = $(if ($null -ne $target.Map.Diagnostics['target_disk_index']) { [string]$target.Map.Diagnostics['target_disk_index'] } else { '' })
        volume_device_id = [string]$target.Map.Volume.DeviceID
    }
    $script:WriteEvidence['identity'] = $identity
    $script:WriteEvidence['dataset_dir'] = $datasetDir
    $script:WriteEvidence['dataset_name'] = $datasetName

    Add-Rg353psWriteCheck 'dataset_dir_absent' (-not (Test-Path -LiteralPath $datasetDir)) ('checked ' + $datasetDir + '; an existing directory is a hard stop')
    if (Test-Path -LiteralPath $datasetDir) {
        $script:WriteEvidence['abort_reason'] = 'dataset_dir_exists'
        $script:WriteEvidence['abort_detail'] = 'the unique dataset directory already exists; nothing was written'
        return (Write-Rg353psWriteReport -PhaseName 'Prepare' -BaseName $Context.BaseName -DeviceWritesPerformed $false -Extra $null)
    }

    $specs = Get-Rg353psWriteFileSpecs
    $required = [long]0
    foreach ($s in $specs) { $required += [long]$s.size }
    $free = [long]0
    try { $free = [long]$target.Map.Volume.FreeSpace } catch { $free = 0 }
    $enough = ($free -gt ($required + 67108864))
    Add-Rg353psWriteCheck 'volume_space_sufficient' $enough ('need ' + $required + ' bytes plus 64 MiB headroom; free=' + $free)
    if (-not $enough) {
        $script:WriteEvidence['abort_reason'] = 'volume_space_insufficient'
        $script:WriteEvidence['abort_detail'] = ('free=' + $free + ', required=' + $required + ' plus 64 MiB headroom')
        return (Write-Rg353psWriteReport -PhaseName 'Prepare' -BaseName $Context.BaseName -DeviceWritesPerformed $false -Extra $null)
    }

    $ds = New-Rg353psWriteDataset -DatasetDir $datasetDir -Files $specs
    $script:WriteEvidence['files'] = @($ds.files)
    if ($ds.aborted) {
        $script:WriteEvidence['abort_reason'] = [string]$ds.abort_reason
        $script:WriteEvidence['abort_detail'] = [string]$ds.abort_detail
        Add-Rg353psWriteCheck 'dataset_created' $false ([string]$ds.abort_reason + ': ' + [string]$ds.abort_detail)
        return (Write-Rg353psWriteReport -PhaseName 'Prepare' -BaseName $Context.BaseName -DeviceWritesPerformed $true -Extra $null)
    }
    Add-Rg353psWriteCheck 'dataset_created' $true ('created ' + $datasetDir + ' with ' + @($ds.files).Count + ' files')
    Add-Rg353psWriteCheck 'create_new_only' $true 'every file used FileMode.CreateNew; no existing file could be overwritten'

    $manifestFiles = New-Object System.Collections.ArrayList
    foreach ($row in @($ds.files)) {
        [void]$manifestFiles.Add([ordered]@{
            relpath = [string]$row.relpath
            size = [long]$row.actual_size
            sha256 = [string]$row.sha256
            kind = [string]$row.kind
        })
    }
    $created = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $manifest = [ordered]@{
        tool = 'rg353ps-mass-storage-write-check'
        phase = 'Prepare'
        run_id = $RunId
        created_utc = $created
        dataset_name = $datasetName
        drive_letter = $drive
        volume_device_id = $identity.volume_device_id
        disk_device_id = $identity.disk_device_id
        filesystem = $identity.filesystem
        capacity = $identity.capacity
        total_bytes = $required
        files = @($manifestFiles)
    }
    $manifestJson = $manifest | ConvertTo-Json -Depth 10

    $deviceManifestPath = Join-Path $datasetDir $script:DeviceManifestName
    $dw = Write-Rg353psWriteTextNew -Path $deviceManifestPath -Text $manifestJson
    Add-Rg353psWriteCheck 'device_manifest_written' ([bool]$dw.ok) $(if ($dw.ok) { $deviceManifestPath } else { $dw.error })
    $script:WriteEvidence['device_manifest'] = $deviceManifestPath

    $localManifest = $Context.LocalManifestPath
    $lw = Write-Rg353psWriteTextNew -Path $localManifest -Text $manifestJson
    Add-Rg353psWriteCheck 'local_manifest_written' ([bool]$lw.ok) $(if ($lw.ok) { $localManifest } else { $lw.error })
    $script:WriteEvidence['local_manifest'] = $localManifest

    # Re-read both manifests so a truncated write cannot be reported as PASS.
    $lcheck = Read-Rg353psWriteManifest -Path $localManifest
    Add-Rg353psWriteCheck 'local_manifest_valid' ([bool]$lcheck.Ok) ([string]$lcheck.Reason)
    if ($lcheck.Ok) {
        $script:WriteEvidence['local_manifest_files'] = @($lcheck.Manifest.files).Count
        $script:WriteEvidence['local_manifest_sha256'] = (Get-FileHash -LiteralPath $localManifest -Algorithm SHA256).Hash.ToLower()
    }
    $dcheck = Read-Rg353psWriteManifest -Path $deviceManifestPath
    Add-Rg353psWriteCheck 'device_manifest_valid' ([bool]$dcheck.Ok) ([string]$lcheck.Reason + ' (device copy: ' + [string]$dcheck.Reason + ')')

    return (Write-Rg353psWriteReport -PhaseName 'Prepare' -BaseName $Context.BaseName -DeviceWritesPerformed $true -Extra ([ordered]@{
        dataset_name = $datasetName
        device_manifest = $deviceManifestPath
        local_manifest = $localManifest
    }))
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

function Invoke-Rg353psWriteVerify {
    param($Context)

    $script:WriteStartedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $localManifest = $Context.LocalManifestPath
    $script:WriteEvidence['local_manifest'] = $localManifest

    $lm = Read-Rg353psWriteManifest -Path $localManifest
    Add-Rg353psWriteCheck 'local_manifest_readable' ([bool]$lm.Ok) ([string]$lm.Reason)
    if (-not $lm.Ok) {
        $script:WriteEvidence['abort_reason'] = 'local_manifest_missing_or_invalid'
        $script:WriteEvidence['abort_detail'] = [string]$lm.Reason
        return (Write-Rg353psWriteReport -PhaseName 'Verify' -BaseName $Context.BaseName -DeviceWritesPerformed $false -Extra $null)
    }

    $target = Get-Rg353psWriteTarget -TopologyMockPath $Context.TopologyMockPath `
        -ProbeRetries $ProbeRetries -ProbeIntervalSeconds $ProbeIntervalSeconds
    $script:WriteEvidence['topology_source'] = $target.TopologySource
    Add-Rg353psWriteCheck 'no_format_prompt' ($target.Abort -ne 'format_prompt') 'a Windows format prompt would be an immediate hard stop'
    if (-not $target.Ok) {
        $script:WriteEvidence['abort_reason'] = [string]$target.Abort
        $script:WriteEvidence['abort_detail'] = [string]$target.Detail
        Add-Rg353psWriteCheck 'strict_device_mapping' $false ([string]$target.Abort + ': ' + [string]$target.Detail)
        return (Write-Rg353psWriteReport -PhaseName 'Verify' -BaseName $Context.BaseName -DeviceWritesPerformed $false -Extra $null)
    }
    Add-Rg353psWriteCheck 'strict_device_mapping' $true ('[' + [string]$target.Map.Path + '] ' + [string]$target.Detail)

    $drive = [string]$target.Drive
    $identity = [ordered]@{
        path = [string]$target.Map.Path
        drive = $drive
        filesystem = [string]$target.Map.Volume.FileSystem
        capacity = [string]$target.Map.Volume.Capacity
        disk_device_id = [string]$target.Map.Disk.DeviceID
        disk_index = $(if ($null -ne $target.Map.Diagnostics['target_disk_index']) { [string]$target.Map.Diagnostics['target_disk_index'] } else { '' })
        volume_device_id = [string]$target.Map.Volume.DeviceID
    }
    $script:WriteEvidence['identity'] = $identity

    $datasetName = [string](Get-Rg353psWriteProperty $lm.Manifest 'dataset_name')
    if ([string]::IsNullOrWhiteSpace($datasetName)) {
        $datasetName = $script:DatasetPrefix + $RunId
    }
    $datasetDir = $drive.TrimEnd('\') + '\' + $datasetName
    $script:WriteEvidence['dataset_dir'] = $datasetDir
    $script:WriteEvidence['dataset_name'] = $datasetName

    Add-Rg353psWriteCheck 'dataset_dir_present' (Test-Path -LiteralPath $datasetDir -PathType Container) ('expected ' + $datasetDir + '; a missing directory is a hard stop and is never created')
    if (-not (Test-Path -LiteralPath $datasetDir -PathType Container)) {
        $script:WriteEvidence['abort_reason'] = 'dataset_dir_missing'
        $script:WriteEvidence['abort_detail'] = 'the dataset directory from the Prepare phase is not present on the mapped volume'
        return (Write-Rg353psWriteReport -PhaseName 'Verify' -BaseName $Context.BaseName -DeviceWritesPerformed $false -Extra $null)
    }

    # Identity drift between phases is informational: the mount can legitimately
    # come back with a different letter or GUID, and the strict mapping above is
    # what re-establishes ownership. Absolute paths from Prepare are never reused.
    $drift = New-Object System.Collections.ArrayList
    foreach ($field in @('volume_device_id', 'disk_device_id', 'drive_letter')) {
        $oldProp = @($lm.Manifest.PSObject.Properties.Name) -contains $field
        if (-not $oldProp) { continue }
        $old = [string]$lm.Manifest.$field
        $new = ''
        if ($field -eq 'volume_device_id') { $new = [string]$identity.volume_device_id }
        if ($field -eq 'disk_device_id') { $new = [string]$identity.disk_device_id }
        if ($field -eq 'drive_letter') { $new = [string]$identity.drive }
        if (-not [string]::IsNullOrEmpty($old) -and $old -ne $new) {
            [void]$drift.Add([ordered]@{ field = $field; prepare = $old; verify = $new })
        }
    }
    $script:WriteEvidence['identity_drift'] = @($drift)
    Add-Rg353psWriteCheck 'identity_remeasured' $true ('drift fields: ' + $(if (@($drift).Count -eq 0) { 'none' } else { (@($drift) | ForEach-Object { $_.field }) -join ',' }))

    $cmp = Compare-Rg353psWriteManifest -Manifest $lm.Manifest -DatasetDir $datasetDir
    $script:WriteEvidence['files'] = @($cmp.Files)
    Add-Rg353psWriteCheck 'all_files_present' (@($cmp.Files | Where-Object { -not $_.present }).Count -eq 0) ('missing=' + @($cmp.Files | Where-Object { -not $_.present }).Count)
    Add-Rg353psWriteCheck 'all_sizes_match' (@($cmp.Files | Where-Object { $_.present -and -not $_.size_ok }).Count -eq 0) ('mismatched sizes=' + @($cmp.Files | Where-Object { $_.present -and -not $_.size_ok }).Count)
    Add-Rg353psWriteCheck 'all_sha256_match' (@($cmp.Files | Where-Object { $_.present -and $_.size_ok -and -not $_.sha256_ok }).Count -eq 0) ('mismatched SHA-256=' + @($cmp.Files | Where-Object { $_.present -and $_.size_ok -and -not $_.sha256_ok }).Count)
    Add-Rg353psWriteCheck 'manifest_comparison' ([bool]$cmp.Ok) ([string]$cmp.Reason)

    # Device-side manifest is a second opinion, not the authority.
    $deviceManifestPath = Join-Path $datasetDir $script:DeviceManifestName
    $script:WriteEvidence['device_manifest'] = $deviceManifestPath
    $dm = Read-Rg353psWriteManifest -Path $deviceManifestPath
    if (-not $dm.Ok) {
        $script:WriteEvidence['device_manifest_check'] = 'unavailable: ' + [string]$dm.Reason
        Add-Rg353psWriteCheck 'device_manifest_consistent' $true ('device copy unavailable, verification used the local manifest only: ' + [string]$dm.Reason)
    }
    else {
        $localMap = @{}
        foreach ($f in @(Get-Rg353psWriteProperty $lm.Manifest 'files')) {
            $localMap[([string](Get-Rg353psWriteProperty $f 'relpath')).ToLower()] = ([string](Get-Rg353psWriteProperty $f 'size')) + ':' + ([string](Get-Rg353psWriteProperty $f 'sha256')).ToLower()
        }
        $deviceMap = @{}
        foreach ($f in @(Get-Rg353psWriteProperty $dm.Manifest 'files')) {
            $deviceMap[([string](Get-Rg353psWriteProperty $f 'relpath')).ToLower()] = ([string](Get-Rg353psWriteProperty $f 'size')) + ':' + ([string](Get-Rg353psWriteProperty $f 'sha256')).ToLower()
        }
        $diff = New-Object System.Collections.ArrayList
        foreach ($k in $localMap.Keys) {
            if (-not $deviceMap.ContainsKey($k)) { [void]$diff.Add('missing on device: ' + $k); continue }
            if ($deviceMap[$k] -ne $localMap[$k]) { [void]$diff.Add('differs: ' + $k) }
        }
        foreach ($k in $deviceMap.Keys) {
            if (-not $localMap.ContainsKey($k)) { [void]$diff.Add('not in local manifest: ' + $k) }
        }
        $script:WriteEvidence['device_manifest_check'] = @($diff)
        Add-Rg353psWriteCheck 'device_manifest_consistent' (@($diff).Count -eq 0) ($(if (@($diff).Count -eq 0) { 'device manifest matches the local manifest entry-for-entry' } else { (@($diff) -join '; ') }))
    }

    return (Write-Rg353psWriteReport -PhaseName 'Verify' -BaseName $Context.BaseName -DeviceWritesPerformed $false -Extra ([ordered]@{
        dataset_name = $datasetName
        device_manifest = $deviceManifestPath
        local_manifest = $localManifest
    }))
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if ($Phase -eq 'None') {
    Write-Host 'Functions loaded (Phase=None). No device access was performed.'
}
else {
    $baseName = $ReportBaseName
    if ([string]::IsNullOrWhiteSpace($baseName)) {
        $baseName = 'mass-storage-write-' + $Phase.ToLower() + '-report'
    }
    $localManifest = $LocalManifestPath
    if ([string]::IsNullOrWhiteSpace($localManifest)) {
        $localManifest = Join-Path $OutDir 'mass-storage-write-prepare-manifest.json'
    }
    $context = [pscustomobject]@{
        TopologyMockPath = $TopologyMockPath
        BaseName = $baseName
        LocalManifestPath = $localManifest
    }
    Write-Host ('== RG353PS Mass Storage write-integrity check: ' + $Phase + ' ==') -ForegroundColor Cyan
    Write-Host ('Run ID: ' + $RunId)
    if ($Phase -eq 'Prepare') { $result = Invoke-Rg353psWritePrepare -Context $context }
    else { $result = Invoke-Rg353psWriteVerify -Context $context }

    Write-Host ('Reports: ' + $result.Json) -ForegroundColor Cyan
    Write-Host ('         ' + $result.Md) -ForegroundColor Cyan
    if ($script:WriteEvidence.Contains('abort_reason') -and $script:WriteEvidence['abort_reason']) {
        Write-Host ('STOP: ' + [string]$script:WriteEvidence['abort_reason'] + ' - ' + [string]$script:WriteEvidence['abort_detail']) -ForegroundColor Red
        exit 1
    }
    if (-not $result.Pass) {
        Write-Host ('FAIL (' + @($script:WriteFailures).Count + ' reasons):') -ForegroundColor Red
        foreach ($f in $script:WriteFailures) { Write-Host ('  - ' + $f) -ForegroundColor Red }
        exit 1
    }
    if ($Phase -eq 'Prepare') {
        Write-Host 'PASS: new dataset written with CreateNew and Flush(true); both manifests saved.' -ForegroundColor Green
        Write-Host 'Next: safely eject the volume, unplug the cable, wait for the device to recover, re-enter Mass Storage, then run -Phase Verify.' -ForegroundColor Yellow
    }
    else {
        Write-Host 'PASS: every file matched the local manifest after re-mapping the device.' -ForegroundColor Green
    }
    exit 0
}
