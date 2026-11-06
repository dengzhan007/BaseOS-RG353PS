<#
.SYNOPSIS
    Windows Portable Devices helper for the BaseOS MTP integrity tool.

.DESCRIPTION
    Drives the Shell namespace (the same WPD stack Explorer uses) so the Python
    tool can list, download, upload, create and delete MTP objects without
    assuming the device gets a drive letter.

    Parameters arrive through a UTF-8 JSON request file rather than the command
    line, so non-ASCII file names survive the trip from Python.

    Request:  { "Action": "list|get|put|mkdir|delete",
                "Device": "RG353PS", "Storage": "RG353PS",
                "Path": "baseos-mtp-test-.../file.txt",
                "Local": "C:\\temp\\file.txt",
                "TimeoutSeconds": 120 }
    Response: { "ok": true, ... } or { "ok": false, "error": "..." }

    Every action reports what actually happened; the caller still verifies
    content with SHA-256 and never trusts this helper alone.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Request
)

$ErrorActionPreference = 'Stop'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    # Older hosts keep their default code page; JSON stays ASCII-safe anyway.
}

function Write-Result($payload) {
    $payload | ConvertTo-Json -Compress -Depth 6 | Write-Output
    exit 0
}

function Write-Failure($message) {
    @{ ok = $false; error = [string]$message } | ConvertTo-Json -Compress -Depth 4 | Write-Output
    exit 1
}

try {
    $json = [System.IO.File]::ReadAllText($Request, [System.Text.Encoding]::UTF8)
    $req = $json | ConvertFrom-Json
} catch {
    Write-Failure "cannot read request file: $($_.Exception.Message)"
}

$action = [string]$req.Action
$deviceName = if ($req.Device) { [string]$req.Device } else { 'RG353PS' }
$storageName = [string]$req.Storage
$relPath = if ($req.Path) { ([string]$req.Path).Trim('/') } else { '' }
$localPath = if ($req.Local) { [string]$req.Local } else { '' }
$timeoutSeconds = if ($req.TimeoutSeconds) { [int]$req.TimeoutSeconds } else { 120 }

$shell = New-Object -ComObject Shell.Application

function Get-DeviceItem {
    $thisPc = $shell.NameSpace(17)
    if (-not $thisPc) { throw 'cannot open the This PC namespace' }
    $item = $thisPc.Items() | Where-Object { $_.Name -eq $deviceName -and $_.IsFolder } | Select-Object -First 1
    if (-not $item) {
        $visible = ($thisPc.Items() | Where-Object { $_.IsFolder } | ForEach-Object { $_.Name }) -join ', '
        throw "device '$deviceName' not found in This PC. Visible folders: $visible"
    }
    return $item
}

function Get-StorageFolder {
    $deviceItem = Get-DeviceItem
    $deviceFolder = $deviceItem.GetFolder
    if (-not $deviceFolder) { throw "cannot open device '$deviceName'" }
    if ($storageName) {
        $storageItem = $deviceFolder.Items() | Where-Object { $_.Name -eq $storageName -and $_.IsFolder } | Select-Object -First 1
        if ($storageItem) { return $storageItem.GetFolder }
        $visible = ($deviceFolder.Items() | Where-Object { $_.IsFolder } | ForEach-Object { $_.Name }) -join ', '
        throw "storage '$storageName' not found on '$deviceName'. Visible storage: $visible"
    }
    return $deviceFolder
}

function Get-FolderFromPath($baseFolder, [string]$path) {
    $folder = $baseFolder
    if (-not $path) { return $folder }
    foreach ($segment in $path.Split('/')) {
        if (-not $segment) { continue }
        $child = $folder.Items() | Where-Object { $_.Name -eq $segment -and $_.IsFolder } | Select-Object -First 1
        if (-not $child) { throw "folder '$segment' not found in '$($folder.Title)'" }
        $folder = $child.GetFolder
    }
    return $folder
}

function Split-PathParts([string]$path) {
    if (-not $path) { return @{ Dir = ''; Name = '' } }
    $index = $path.LastIndexOf('/')
    if ($index -lt 0) { return @{ Dir = ''; Name = $path } }
    return @{ Dir = $path.Substring(0, $index); Name = $path.Substring($index + 1) }
}

function Get-ItemSize($item) {
    try {
        $size = $item.ExtendedProperty('System.Size')
        if ($null -eq $size) { return 0 }
        return [int64]$size
    } catch {
        return 0
    }
}

function Wait-ForCondition([scriptblock]$probe, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $probe) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return (& $probe)
}

try {
    switch ($action) {
        'list' {
            $folder = Get-FolderFromPath (Get-StorageFolder) $relPath
            $items = @()
            foreach ($item in $folder.Items()) {
                $items += [pscustomobject]@{
                    name    = $item.Name
                    is_dir  = [bool]$item.IsFolder
                    size    = if ($item.IsFolder) { 0 } else { Get-ItemSize $item }
                    relpath = if ($relPath) { "$relPath/$($item.Name)" } else { $item.Name }
                }
            }
            Write-Result @{ ok = $true; items = $items; count = $items.Count }
        }
        'get' {
            $parts = Split-PathParts $relPath
            if (-not $parts.Name) { throw 'get requires a file path' }
            $folder = Get-FolderFromPath (Get-StorageFolder) $parts.Dir
            $item = $folder.Items() | Where-Object { $_.Name -eq $parts.Name -and -not $_.IsFolder } | Select-Object -First 1
            if (-not $item) { throw "file '$($parts.Name)' not found on the device" }
            $expected = Get-ItemSize $item
            $localDir = [System.IO.Path]::GetDirectoryName($localPath)
            if ($localDir -and -not (Test-Path $localDir)) {
                New-Item -ItemType Directory -Path $localDir -Force | Out-Null
            }
            if (Test-Path $localPath) { Remove-Item $localPath -Force }
            $destination = $shell.NameSpace($localDir)
            if (-not $destination) { throw "cannot open local folder '$localDir'" }
            # 0x14 = no progress dialog, answer "yes to all" for prompts.
            $destination.CopyHere($item, 0x14)
            $arrived = Wait-ForCondition {
                if (-not (Test-Path $localPath)) { return $false }
                $length = (Get-Item $localPath).Length
                if ($expected -gt 0) { return $length -eq $expected }
                return $length -gt 0
            } $timeoutSeconds
            if (-not $arrived) {
                throw "copy did not complete within $timeoutSeconds s (expected $expected bytes)"
            }
            $actual = (Get-Item $localPath).Length
            Write-Result @{ ok = $true; bytes = $actual; expected = $expected }
        }
        'put' {
            if (-not (Test-Path $localPath)) { throw "local file '$localPath' does not exist" }
            $folder = Get-FolderFromPath (Get-StorageFolder) $relPath
            $leaf = [System.IO.Path]::GetFileName($localPath)
            $expected = (Get-Item $localPath).Length
            $sourceItem = $shell.NameSpace([System.IO.Path]::GetDirectoryName($localPath)).ParseName($leaf)
            if (-not $sourceItem) { throw "cannot open local file '$localPath'" }
            $folder.CopyHere($sourceItem, 0x14)
            $landed = Wait-ForCondition {
                $probe = $folder.Items() | Where-Object { $_.Name -eq $leaf } | Select-Object -First 1
                if (-not $probe) { return $false }
                $size = Get-ItemSize $probe
                if ($expected -gt 0) { return $size -eq $expected }
                return $true
            } $timeoutSeconds
            if (-not $landed) {
                throw "upload of '$leaf' did not appear with the expected size within $timeoutSeconds s"
            }
            $final = $folder.Items() | Where-Object { $_.Name -eq $leaf } | Select-Object -First 1
            Write-Result @{ ok = $true; name = $leaf; bytes = (Get-ItemSize $final) }
        }
        'mkdir' {
            $parts = Split-PathParts $relPath
            $parent = Get-FolderFromPath (Get-StorageFolder) $parts.Dir
            if (-not $parts.Name) { throw 'mkdir requires a directory path' }
            $existing = $parent.Items() | Where-Object { $_.Name -eq $parts.Name -and $_.IsFolder } | Select-Object -First 1
            if ($existing) { Write-Result @{ ok = $true; created = $false; name = $parts.Name } }
            $null = $parent.NewFolder($parts.Name)
            $created = Wait-ForCondition {
                $probe = $parent.Items() | Where-Object { $_.Name -eq $parts.Name -and $_.IsFolder } | Select-Object -First 1
                return [bool]$probe
            } $timeoutSeconds
            if (-not $created) { throw "folder '$($parts.Name)' did not appear within $timeoutSeconds s" }
            Write-Result @{ ok = $true; created = $true; name = $parts.Name }
        }
        'delete' {
            $parts = Split-PathParts $relPath
            if (-not $parts.Name) { throw 'delete requires a path' }
            $folder = Get-FolderFromPath (Get-StorageFolder) $parts.Dir
            $item = $folder.Items() | Where-Object { $_.Name -eq $parts.Name } | Select-Object -First 1
            if (-not $item) { Write-Result @{ ok = $true; deleted = $false; reason = 'not present' } }
            $item.InvokeVerb('delete')
            $gone = Wait-ForCondition {
                $probe = $folder.Items() | Where-Object { $_.Name -eq $parts.Name } | Select-Object -First 1
                return (-not $probe)
            } $timeoutSeconds
            if (-not $gone) {
                throw "delete verb did not remove '$($parts.Name)' within $timeoutSeconds s"
            }
            Write-Result @{ ok = $true; deleted = $true; name = $parts.Name }
        }
        default {
            throw "unknown action '$action'"
        }
    }
} catch {
    Write-Failure $_.Exception.Message
}
