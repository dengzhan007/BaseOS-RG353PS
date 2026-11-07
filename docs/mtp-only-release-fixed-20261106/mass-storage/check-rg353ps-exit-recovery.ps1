<#
RG353PS Mass Storage -> MTP exit-recovery host check (read-only).

Verifies, after the user has safely ejected the Mass Storage volume, unplugged,
waited and replugged the cable, that the device came back as MTP-only:

  1. exactly one root device with VID_2207&PID_0009
  2. zero root devices with VID_2207&PID_0006 / 0007 / 0008
  3. WPD recognises RG353PS (live device node, or live Shell item)
  4. no RNDIS/NCM network interface provided by this device

WPD evidence only counts *live* signals: a present PnP node with PNPClass=WPD
(Service WUDFWpdMtp) under PID_0009, or an RG353PS item in the Shell "This PC"
namespace. Registry keys left behind by older composite-mode sessions (for
example PID_0008&MI_02) are recorded as legacy_entries and never satisfy the
check.

Read-only by construction: it only enumerates CIM/PnP, reads WPD registry keys
and Shell namespace items, and lists network adapters and volumes. It never
opens a disk, never writes to the device, never changes configuration, and
never retries anything beyond polling for up to WaitSeconds.

Exit codes: 0 = PASS (all four conditions), 1 = FAIL (raw diagnostics kept).
#>

[CmdletBinding()]
param(
    [int]$WaitSeconds = 30,
    [string]$OutDir = $PSScriptRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RunId = '20261106-131355-4a3405'
$StartedUtc = (Get-Date).ToUniversalTime()
$StartedLocal = Get-Date
$Deadline = $StartedLocal.AddSeconds($WaitSeconds)
$PollIntervalSeconds = 3

function Get-Vid2207Entities {
    Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
        Where-Object { $_.PNPDeviceID -and $_.PNPDeviceID -match '^USB\\VID_2207&PID_[0-9A-Fa-f]{4}\\' }
}

function ConvertTo-BriefEntity {
    param($Entity)
    [pscustomobject]@{
        Name         = $Entity.Name
        PNPDeviceID  = $Entity.PNPDeviceID
        PNPClass     = $Entity.PNPClass
        Status       = $Entity.Status
        Service      = $Entity.Service
        Manufacturer = $Entity.Manufacturer
    }
}

function Get-WpdRegistryEvidence {
    $current = @()
    $legacy = @()
    $wpdKey = 'HKLM:\SOFTWARE\Microsoft\Windows Portable Devices\Devices'
    if (Test-Path $wpdKey) {
        foreach ($sub in Get-ChildItem $wpdKey -ErrorAction SilentlyContinue) {
            $props = Get-ItemProperty $sub.PSPath -ErrorAction SilentlyContinue
            $friendly = $null
            $desc = $null
            if ($props) {
                if ($props.PSObject.Properties.Name -contains 'FriendlyName') { $friendly = $props.FriendlyName }
                if ($props.PSObject.Properties.Name -contains 'Description') { $desc = $props.Description }
            }
            if (($sub.PSChildName -notmatch 'VID_2207') -and
                -not ($friendly -and $friendly -match 'RG353PS') -and
                -not ($desc -and $desc -match 'RG353PS')) { continue }

            $entry = [pscustomobject]@{
                Key             = $sub.PSChildName
                FriendlyName    = $friendly
                Description     = $desc
                matches_pid0009 = [bool]($sub.PSChildName -match 'VID_2207&PID_0009')
            }
            if ($entry.matches_pid0009) { $current += $entry } else { $legacy += $entry }
        }
    }
    [pscustomobject]@{
        current_pid0009_entries = @($current)
        legacy_other_entries    = @($legacy)
    }
}

function Get-WpdShellItems {
    $items = @()
    $shellError = ''
    try {
        $shell = New-Object -ComObject Shell.Application
        $thisPc = $shell.NameSpace(17)
        if ($thisPc) {
            foreach ($item in $thisPc.Items()) {
                $items += [pscustomobject]@{
                    Name     = $item.Name
                    IsFolder = [bool]$item.IsFolder
                    Path     = $item.Path
                }
            }
        }
    }
    catch {
        $shellError = $_.Exception.Message
    }
    [pscustomobject]@{
        items       = @($items)
        shell_error = $shellError
    }
}

function Get-NetworkEvidence {
    $adapters = @()
    try {
        $adapters = @(Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction Stop)
    }
    catch {
        $adapters = @()
    }

    $vid = @()
    $rndis = @()
    foreach ($a in $adapters) {
        $pnp = [string]$a.PNPDeviceID
        if ($pnp -notmatch 'VID_2207') { continue }
        $isNet = ($a.Name -match 'RNDIS|NCM|Remote NDIS') -or ($a.Description -match 'RNDIS|NCM') -or ($pnp -match 'RNDIS|NCM')
        $entry = [pscustomobject]@{
            Name                = $a.Name
            Description         = $a.Description
            PNPDeviceID         = $pnp
            NetEnabled          = $a.NetEnabled
            NetConnectionStatus = $a.NetConnectionStatus
            MACAddress          = $a.MACAddress
            rndis_or_ncm        = [bool]$isNet
        }
        $vid += $entry
        if ($isNet) { $rndis += $entry }
    }

    $netAdapters = @()
    $netAdapterError = ''
    try {
        $netAdapters = @(Get-NetAdapter -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                Name                 = $_.Name
                InterfaceDescription = $_.InterfaceDescription
                Status               = [string]$_.Status
                MacAddress           = $_.MacAddress
                PnpDeviceID          = $_.PnpDeviceID
            }
        })
    }
    catch {
        $netAdapterError = $_.Exception.Message
    }

    $ipv4 = @()
    try {
        $ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                InterfaceAlias = $_.InterfaceAlias
                IPAddress      = $_.IPAddress
                PrefixLength   = $_.PrefixLength
            }
        })
    }
    catch {
        $ipv4 = @()
    }

    [pscustomobject]@{
        vid2207_adapters   = @($vid)
        rndis_ncm_adapters = @($rndis)
        all_adapters       = @($netAdapters)
        ipv4_addresses     = @($ipv4)
        net_adapter_error  = $netAdapterError
    }
}

function Get-ResidualStorageEvidence {
    # Informational only: a still-mounted BASEOS_DATA volume would mean the
    # mass-storage frontend did not release the disk. Never affects PASS.
    $vols = @()
    try {
        $vols = @(Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop |
            Where-Object { $_.Label -eq 'BASEOS_DATA' -or ($_.FileSystem -eq 'exFAT' -and $_.Capacity -gt 1GB) } |
            ForEach-Object {
                [pscustomobject]@{
                    Label       = $_.Label
                    FileSystem  = $_.FileSystem
                    DriveLetter = $_.DriveLetter
                    Capacity    = $_.Capacity
                    DeviceID    = $_.DeviceID
                }
            })
    }
    catch { $vols = @() }
    @($vols)
}

function Invoke-ExitRecoveryProbe {
    $entities = @(Get-Vid2207Entities)
    $roots0009 = @($entities | Where-Object { $_.PNPDeviceID -match '^USB\\VID_2207&PID_0009\\' })
    $roots0006 = @($entities | Where-Object { $_.PNPDeviceID -match '^USB\\VID_2207&PID_0006\\' })
    $roots0007 = @($entities | Where-Object { $_.PNPDeviceID -match '^USB\\VID_2207&PID_0007\\' })
    $roots0008 = @($entities | Where-Object { $_.PNPDeviceID -match '^USB\\VID_2207&PID_0008\\' })

    $wpdReg = Get-WpdRegistryEvidence
    $shell = Get-WpdShellItems
    $net = Get-NetworkEvidence
    $residual = Get-ResidualStorageEvidence

    $wpdLiveNodes = @($roots0009 | Where-Object {
        $_.PNPClass -eq 'WPD' -or $_.Service -eq 'WUDFWpdMtp'
    })
    $wpdShellHit = @($shell.items | Where-Object { $_.Name -match 'RG353PS' })
    $wpdLive = [bool](($wpdLiveNodes.Count + $wpdShellHit.Count) -gt 0)

    $checks = @(
        [pscustomobject]@{
            name   = 'pid_0009_root_exactly_one'
            status = if ($roots0009.Count -eq 1) { 'PASS' } else { 'FAIL' }
            detail = ("VID_2207&PID_0009 root nodes={0} (expected exactly 1)" -f $roots0009.Count)
        },
        [pscustomobject]@{
            name   = 'pid_0006_0007_0008_absent'
            status = if (($roots0006.Count + $roots0007.Count + $roots0008.Count) -eq 0) { 'PASS' } else { 'FAIL' }
            detail = ("PID_0006={0}; PID_0007={1}; PID_0008={2} (all expected 0)" -f $roots0006.Count, $roots0007.Count, $roots0008.Count)
        },
        [pscustomobject]@{
            name   = 'wpd_recognises_rg353ps'
            status = if ($wpdLive) { 'PASS' } else { 'FAIL' }
            detail = ("live WPD nodes (WUDFWpdMtp)={0}; live Shell RG353PS items={1}; stale registry entries ignored for pass: {2}" -f $wpdLiveNodes.Count, $wpdShellHit.Count, $wpdReg.legacy_other_entries.Count)
        },
        [pscustomobject]@{
            name   = 'no_device_rndis_ncm'
            status = if ($net.rndis_ncm_adapters.Count -eq 0 -and $net.vid2207_adapters.Count -eq 0) { 'PASS' } else { 'FAIL' }
            detail = ("VID_2207 network adapters={0}; RNDIS/NCM adapters={1} (both expected 0)" -f $net.vid2207_adapters.Count, $net.rndis_ncm_adapters.Count)
        }
    )

    [pscustomobject]@{
        observed_utc         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        vid2207_all          = @($entities | ForEach-Object { ConvertTo-BriefEntity $_ })
        pid_0009_roots       = @($roots0009 | ForEach-Object { ConvertTo-BriefEntity $_ })
        pid_0006_roots       = @($roots0006 | ForEach-Object { ConvertTo-BriefEntity $_ })
        pid_0007_roots       = @($roots0007 | ForEach-Object { ConvertTo-BriefEntity $_ })
        pid_0008_roots       = @($roots0008 | ForEach-Object { ConvertTo-BriefEntity $_ })
        wpd_live_nodes       = @($wpdLiveNodes | ForEach-Object { ConvertTo-BriefEntity $_ })
        wpd_live_shell_items = @($wpdShellHit)
        wpd_registry         = $wpdReg
        wpd_shell_all_items  = @($shell.items)
        wpd_shell_error      = $shell.shell_error
        network              = $net
        residual_mass_storage_volumes = @($residual)
        checks               = $checks
        all_pass             = [bool](@($checks | Where-Object { $_.status -ne 'PASS' }).Count -eq 0)
    }
}

$attempts = @()
$last = $null
while ($true) {
    $last = Invoke-ExitRecoveryProbe
    $attempts += [pscustomobject]@{
        attempt   = $attempts.Count + 1
        at_utc    = $last.observed_utc
        pid_0009  = $last.pid_0009_roots.Count
        pid_0006  = $last.pid_0006_roots.Count
        pid_0007  = $last.pid_0007_roots.Count
        pid_0008  = $last.pid_0008_roots.Count
        wpd_live  = $last.wpd_live_nodes.Count + $last.wpd_live_shell_items.Count
        vid2207_net = $last.network.vid2207_adapters.Count
        all_pass  = $last.all_pass
    }
    if ($last.all_pass) { break }
    if ((Get-Date) -ge $Deadline) { break }
    Start-Sleep -Seconds $PollIntervalSeconds
}

$FinishedUtc = (Get-Date).ToUniversalTime()
$failures = @($last.checks | Where-Object { $_.status -ne 'PASS' } | ForEach-Object { $_.name })
$pass = [bool]$last.all_pass

$report = [pscustomobject]@{
    tool          = 'rg353ps-exit-recovery-readonly-check'
    run_id        = $RunId
    started_utc   = $StartedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    finished_utc  = $FinishedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    read_only     = $true
    wait_seconds  = $WaitSeconds
    poll_interval = $PollIntervalSeconds
    attempts      = @($attempts)
    evidence      = $last
    checks        = @($last.checks)
    failures      = @($failures)
    pass          = $pass
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$jsonPath = Join-Path $OutDir 'exit-recovery-host-report.json'
$mdPath = Join-Path $OutDir 'exit-recovery-host-report.md'

$json = $report | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($jsonPath, $json, (New-Object System.Text.UTF8Encoding($false)))

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# RG353PS Mass Storage exit-recovery host report')
$lines.Add('')
$lines.Add(('- Run ID: `{0}`' -f $RunId))
$lines.Add(('- Overall: **{0}**' -f $(if ($pass) { 'PASS' } else { 'FAIL' })))
$lines.Add(('- Read-only: yes; wait budget: {0}s; polls: {1}' -f $WaitSeconds, $attempts.Count))
$lines.Add(('- Started/Finished (UTC): {0} / {1}' -f $report.started_utc, $report.finished_utc))
$lines.Add('- Scope: exit from Mass Storage back to MTP only; no file-transfer retest.')
$lines.Add('')
$lines.Add('## Checks')
$lines.Add('')
$lines.Add('| Check | Status | Detail |')
$lines.Add('| --- | --- | --- |')
foreach ($c in $last.checks) {
    $lines.Add(('| {0} | {1} | {2} |' -f $c.name, $c.status, $c.detail))
}
$lines.Add('')
$lines.Add('## Evidence')
$lines.Add('')
$lines.Add(('- VID_2207&PID_0009 roots: {0}' -f $last.pid_0009_roots.Count))
foreach ($e in $last.pid_0009_roots) {
    $lines.Add(('  - `{0}` - {1} (class={2}, service={3}, status={4})' -f $e.PNPDeviceID, $e.Name, $e.PNPClass, $e.Service, $e.Status))
}
$lines.Add(('- VID_2207&PID_0006 roots: {0}; PID_0007: {1}; PID_0008: {2}' -f $last.pid_0006_roots.Count, $last.pid_0007_roots.Count, $last.pid_0008_roots.Count))
$lines.Add(('- Live WPD nodes: {0}; live Shell RG353PS items: {1}' -f $last.wpd_live_nodes.Count, $last.wpd_live_shell_items.Count))
foreach ($w in $last.wpd_live_shell_items) {
    $lines.Add(('  - shell `{0}` (folder={1})' -f $w.Name, $w.IsFolder))
}
$lines.Add(('- WPD registry keys for PID_0009: {0}' -f $last.wpd_registry.current_pid0009_entries.Count))
foreach ($w in $last.wpd_registry.current_pid0009_entries) {
    $lines.Add(('  - `{0}` - {1}' -f $w.Key, $w.FriendlyName))
}
$lines.Add(('- WPD registry leftovers from older modes (not counted): {0}' -f $last.wpd_registry.legacy_other_entries.Count))
foreach ($w in $last.wpd_registry.legacy_other_entries) {
    $lines.Add(('  - `{0}` - {1}' -f $w.Key, $w.FriendlyName))
}
$lines.Add(('- Network: VID_2207 adapters={0}; RNDIS/NCM adapters={1}; host adapters observed={2}' -f $last.network.vid2207_adapters.Count, $last.network.rndis_ncm_adapters.Count, $last.network.all_adapters.Count))
$lines.Add(('- Informational: mounted BASEOS_DATA/exFAT volumes={0}' -f $last.residual_mass_storage_volumes.Count))
$lines.Add('')
$lines.Add('## Poll history')
$lines.Add('')
$lines.Add('| # | At (UTC) | PID_0009 | 0006 | 0007 | 0008 | WPD live | VID_2207 net | All pass |')
$lines.Add('| --- | --- | --- | --- | --- | --- | --- | --- | --- |')
foreach ($a in $attempts) {
    $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f $a.attempt, $a.at_utc, $a.pid_0009, $a.pid_0006, $a.pid_0007, $a.pid_0008, $a.wpd_live, $a.vid2207_net, $a.all_pass))
}
$lines.Add('')
$lines.Add('> Read-only observation. No disk was opened, no configuration changed,')
$lines.Add('> no restart and no repair attempted. A failing result is kept as-is.')
$md = ($lines -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText($mdPath, $md, (New-Object System.Text.UTF8Encoding($false)))

Write-Output '== RG353PS Mass Storage exit-recovery check (read-only) =='
Write-Output ('Run ID: {0}' -f $RunId)
foreach ($c in $last.checks) {
    Write-Output ('{0}: {1} ({2})' -f $c.status, $c.name, $c.detail)
}
Write-Output ('Reports: {0}' -f $jsonPath)
Write-Output ('         {0}' -f $mdPath)
if ($pass) {
    Write-Output 'PASS: device returned as MTP-only (PID_0009), no mass-storage or legacy PID, WPD visible, no device network interface.'
    exit 0
}
Write-Output ('FAIL: {0}' -f ($failures -join ', '))
exit 1
