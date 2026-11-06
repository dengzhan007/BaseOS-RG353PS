# Offline tests for the STRICT device mapping. No hardware is contacted.
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\test-rg353ps-mass-storage-device-map.ps1
$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir 'Rg353psDeviceMap.ps1')

$USB_ROOT = 'USB\VID_2207&PID_0006\BASEOS-RG353PS'
$USB_IFACE = 'USB\VID_2207&PID_0006&MI_00\BASEOS-RG353PS'
$USB_STOR = 'USBSTOR\Disk&Ven_BaseOS&Prod_RG353PS&Rev_1.00\BASEOS-RG353PS&0'
$TARGET_DISK = '\\.\PHYSICALDRIVE2'
$OTHER_DISK = '\\.\PHYSICALDRIVE3'
$OTHER_USB = 'USB\VID_1234&PID_5678\SOME_OTHER_DRIVE'
$OTHER_STOR = 'USBSTOR\Disk&Ven_Other&Prod_Disk&Rev_1.00\OTHER&0'

function New-Base {
    return [ordered]@{
        PnpDevices = @(
            [pscustomobject]@{ PNPDeviceID = $USB_ROOT; Name = 'RG353PS USB Storage'; PNPClass = 'USB'; Status = 'OK' },
            [pscustomobject]@{ PNPDeviceID = $USB_IFACE; Name = 'USB Mass Storage Device'; PNPClass = 'USB'; Status = 'OK' }
        )
        PnpChildren = @(
            [pscustomobject]@{ Parent = $USB_ROOT; Child = $USB_STOR }
        )
        Disks = @(
            [pscustomobject]@{ DeviceID = $TARGET_DISK; PNPDeviceID = $USB_STOR; InterfaceType = 'USB'; Index = 2; Model = 'RG353PS'; Size = 13000000000 },
            [pscustomobject]@{ DeviceID = $OTHER_DISK; PNPDeviceID = $OTHER_STOR; InterfaceType = 'USB'; Index = 3; Model = 'Other USB HDD'; Size = 1000000000000 }
        )
        DiskPartitions = @(
            [pscustomobject]@{ DiskDeviceID = $TARGET_DISK; DeviceID = 'Disk #2, Partition #0'; DriveLetter = 'E:'; FileSystem = 'exFAT'; Size = 13000000000; Type = 'Installable File System' },
            [pscustomobject]@{ DiskDeviceID = $OTHER_DISK; DeviceID = 'Disk #3, Partition #0'; DriveLetter = 'F:'; FileSystem = 'exFAT'; Size = 1000000000000; Type = 'Installable File System' }
        )
        Volumes = @(
            [pscustomobject]@{ DeviceID = '\\?\Volume{target}'; DriveLetter = 'E:'; FileSystem = 'exFAT'; Capacity = 13000000000 },
            [pscustomobject]@{ DeviceID = '\\?\Volume{other}'; DriveLetter = 'F:'; FileSystem = 'exFAT'; Capacity = 1000000000000 }
        )
    }
}

function Invoke-Resolve($t) {
    return Resolve-Rg353psTarget -PnpDevices @($t.PnpDevices) -PnpChildren @($t.PnpChildren) `
        -Disks @($t.Disks) -DiskPartitions @($t.DiskPartitions) -Volumes @($t.Volumes)
}

$Results = New-Object System.Collections.ArrayList
function Assert-Case {
    param([string]$Name, [bool]$ExpectOk, [string]$ExpectDisk, [scriptblock]$Setup, [string]$ExpectReason = '')
    $t = New-Base
    if ($Setup) { & $Setup $t }
    $r = Invoke-Resolve $t
    $wrongDevice = ($r.Ok -and $r.Disk -and $r.Disk.DeviceID -eq $OTHER_DISK)
    $ok = ($r.Ok -eq $ExpectOk) -and (-not $wrongDevice)
    if ($ExpectDisk) { $ok = $ok -and $r.Ok -and ($r.Disk.DeviceID -eq $ExpectDisk) }
    if ($ExpectReason) { $ok = $ok -and ($r.Reason -match $ExpectReason) }
    [void]$Results.Add([ordered]@{
        name = $Name; expected_ok = $ExpectOk; actual_ok = $r.Ok
        reason = $r.Reason; selected_disk = $(if ($r.Disk) { $r.Disk.DeviceID } else { '' })
        wrong_device_selected = $wrongDevice; pass = $ok
    })
    $label = $(if ($ok) { 'PASS' } else { 'FAIL' })
    Write-Host (('{0,-5} {1,-46} ok={2} disk={3}' -f $label, $Name, $r.Ok, $(if ($r.Disk) { $r.Disk.DeviceID } else { '-' })))
    if (-not $ok) { Write-Host ('       reason=' + $r.Reason) -ForegroundColor Red }
}

Assert-Case 'correct device -> unique target volume' $true $TARGET_DISK {}
Assert-Case 'other USB disk only (no target identity)' $false '' {
    param($t)
    $t.PnpDevices = @([pscustomobject]@{ PNPDeviceID = $OTHER_USB; Name = 'Other'; PNPClass = 'USB'; Status = 'OK' })
    $t.PnpChildren = @()
} 'exactly one'
Assert-Case 'target + other exFAT disk -> still target' $true $TARGET_DISK {}
Assert-Case 'two PID_0006 roots -> FAIL' $false '' {
    param($t)
    $t.PnpDevices += [pscustomobject]@{ PNPDeviceID = 'USB\VID_2207&PID_0006\SECOND'; Name = 'RG353PS 2'; PNPClass = 'USB'; Status = 'OK' }
} 'exactly one'
Assert-Case 'two USBSTOR children -> two disks -> FAIL' $false '' {
    param($t)
    $t.PnpChildren += [pscustomobject]@{ Parent = $USB_ROOT; Child = $OTHER_STOR }
} 'not unique'
Assert-Case 'RAW partition on target disk -> FAIL' $false '' {
    param($t)
    $t.DiskPartitions[0].FileSystem = 'RAW'
} 'RAW/unknown'
Assert-Case 'unknown filesystem partition -> FAIL' $false '' {
    param($t)
    $t.DiskPartitions[0].FileSystem = 'Unknown'
} 'RAW/unknown'
Assert-Case 'no-letter partition is still inspected (RAW) -> FAIL' $false '' {
    param($t)
    $t.DiskPartitions[0].DriveLetter = ''
    $t.DiskPartitions[0].FileSystem = ''
} 'RAW/unknown'
Assert-Case 'no-letter normal partition -> no usable volume -> FAIL' $false '' {
    param($t)
    $t.DiskPartitions[0].DriveLetter = ''
} 'exactly one accessible'
Assert-Case 'no PnP children -> identity uncertain -> FAIL' $false '' {
    param($t)
    $t.PnpChildren = @()
} 'no PnP child'
Assert-Case 'child cannot map to any disk -> FAIL' $false '' {
    param($t)
    $t.Disks = @($t.Disks[1])
} 'not unique'
Assert-Case 'no partitions for target disk -> FAIL' $false '' {
    param($t)
    $t.DiskPartitions = @($t.DiskPartitions[1])
} 'no partition'
Assert-Case 'two accessible exFAT volumes on target disk -> FAIL' $false '' {
    param($t)
    $t.DiskPartitions += [pscustomobject]@{ DiskDeviceID = $TARGET_DISK; DeviceID = 'Disk #2, Partition #1'; DriveLetter = 'G:'; FileSystem = 'exFAT'; Size = 1000; Type = 'Installable File System' }
    $t.Volumes += [pscustomobject]@{ DeviceID = '\\?\Volume{extra}'; DriveLetter = 'G:'; FileSystem = 'exFAT'; Capacity = 1000 }
} 'exactly one accessible'
Assert-Case 'volume metadata not unique -> FAIL' $false '' {
    param($t)
    $t.Volumes += [pscustomobject]@{ DeviceID = '\\?\Volume{dup}'; DriveLetter = 'E:'; FileSystem = 'exFAT'; Capacity = 1 }
} 'volume metadata'
Assert-Case 'mapped disk is not USBSTOR/USB -> FAIL' $false '' {
    param($t)
    $t.Disks[0].PNPDeviceID = 'SCSI\Disk&Ven_Internal'
    $t.Disks[0].InterfaceType = 'SCSI'
    $t.PnpChildren = @([pscustomobject]@{ Parent = $USB_ROOT; Child = 'SCSI\Disk&Ven_Internal' })
} 'not a USB'

$passed = @($Results | Where-Object { $_.pass }).Count
$failed = @($Results | Where-Object { -not $_.pass }).Count
$wrong = @($Results | Where-Object { $_.wrong_device_selected }).Count
$out = [ordered]@{
    tool = 'rg353ps-mass-storage-device-map-offline-tests'
    utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    total = $Results.Count; passed = $passed; failed = $failed
    wrong_device_selected_count = $wrong
    overall = $(if ($failed -eq 0 -and $wrong -eq 0) { 'PASS' } else { 'FAIL' })
    cases = @($Results)
}
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $ScriptDir 'offline-test-results.json'),
    ($out | ConvertTo-Json -Depth 6), $enc)
Write-Host ('Ran ' + $Results.Count + ' cases: ' + $passed + ' passed, ' + $failed + ' failed, wrong-device=' + $wrong)
Write-Host ('OVERALL=' + $out.overall)
if ($out.overall -ne 'PASS') { exit 1 }
exit 0
