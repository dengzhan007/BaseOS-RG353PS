# RG353PS Mass Storage exit-recovery host report

- Run ID: `20261106-131355-4a3405`
- Overall: **PASS**
- Read-only: yes; wait budget: 30s; polls: 1
- Started/Finished (UTC): 2026-11-06T15:09:25Z / 2026-11-06T15:09:27Z
- Scope: exit from Mass Storage back to MTP only; no file-transfer retest.

## Checks

| Check | Status | Detail |
| --- | --- | --- |
| pid_0009_root_exactly_one | PASS | VID_2207&PID_0009 root nodes=1 (expected exactly 1) |
| pid_0006_0007_0008_absent | PASS | PID_0006=0; PID_0007=0; PID_0008=0 (all expected 0) |
| wpd_recognises_rg353ps | PASS | live WPD nodes (WUDFWpdMtp)=1; live Shell RG353PS items=1; stale registry entries ignored for pass: 1 |
| no_device_rndis_ncm | PASS | VID_2207 network adapters=0; RNDIS/NCM adapters=0 (both expected 0) |

## Evidence

- VID_2207&PID_0009 roots: 1
  - `USB\VID_2207&PID_0009\BASEOS-RG353PS` - RG353PS (class=WPD, service=WUDFWpdMtp, status=OK)
- VID_2207&PID_0006 roots: 0; PID_0007: 0; PID_0008: 0
- Live WPD nodes: 1; live Shell RG353PS items: 1
  - shell `RG353PS` (folder=True)
- WPD registry keys for PID_0009: 1
  - `USB#VID_2207&PID_0009#BASEOS-RG353PS` - RG353PS
- WPD registry leftovers from older modes (not counted): 1
  - `USB#VID_2207&PID_0008&MI_02#7&26A4B16B&0&0002` - RG353PS
- Network: VID_2207 adapters=0; RNDIS/NCM adapters=0; host adapters observed=6
- Informational: mounted BASEOS_DATA/exFAT volumes=0

## Poll history

| # | At (UTC) | PID_0009 | 0006 | 0007 | 0008 | WPD live | VID_2207 net | All pass |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 2026-11-06T15:09:27Z | 1 | 0 | 0 | 0 | 2 | 0 | True |

> Read-only observation. No disk was opened, no configuration changed,
> no restart and no repair attempted. A failing result is kept as-is.
