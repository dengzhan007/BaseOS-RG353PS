# RG353PS Mass Storage stability report (read-only)

- Run ID: `20261106-131355-4a3405`
- Overall: **PASS**
- Read-only: yes (no write, no format, no repair, no drive-letter change, no disconnect)
- Planned: 30 min, poll every 10 s, SHA-256 every 5 min
- Started/Finished (UTC): 2026-11-06T15:22:54Z / 2026-11-06T15:52:57Z
- Samples: 166 (166 ok); SHA-256 checks: 7 (7 ok)
- Anomalies: 0

## Baseline identity

| Field | Value |
| --- | --- |
| path | superfloppy |
| disk_device_id | \\.\PHYSICALDRIVE3 |
| disk_index | 3 |
| volume_device_id | \\?\Volume{4508079a-d83f-11f1-9794-c8a3e85ae46c}\ |
| drive_letter | G: |
| filesystem | exFAT |
| capacity | 14190346240 |

## Test file

- Path: `G:\baseos-mtp-test-20261106-131355-4a3405\large-128m.bin`
- Expected size: 134217728
- Expected SHA-256: `52b43720572483d215a3ba86436a8a9acda01cda1fa5c4135914ddc19cfc93cd`
- Source: device manifest

## SHA-256 checks

| UTC | Size | SHA-256 match | ms | Error |
| --- | --- | --- | --- | --- |
| 2026-11-06T15:22:56Z | 134217728 | yes | 174 |  |
| 2026-11-06T15:28:04Z | 134217728 | yes | 135 |  |
| 2026-11-06T15:33:00Z | 134217728 | yes | 138 |  |
| 2026-11-06T15:38:07Z | 134217728 | yes | 138 |  |
| 2026-11-06T15:43:04Z | 134217728 | yes | 141 |  |
| 2026-11-06T15:48:00Z | 134217728 | yes | 140 |  |
| 2026-11-06T15:52:57Z | 134217728 | yes | 134 |  |

## Timeline (first and last samples)

| # | UTC | Elapsed s | PID_0006 | Map | Path | Disk idx | Drive | Volume | File | OK |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 2026-11-06T15:22:55Z | 1.7 | 1 | ok | superfloppy | 3 | G: | yes | yes | yes |
| 2 | 2026-11-06T15:23:06Z | 12.9 | 1 | ok | superfloppy | 3 | G: | yes | yes | yes |
| 3 | 2026-11-06T15:23:18Z | 23.9 | 1 | ok | superfloppy | 3 | G: | yes | yes | yes |
| 4 | 2026-11-06T15:23:28Z | 34.9 | 1 | ok | superfloppy | 3 | G: | yes | yes | yes |
| 5 | 2026-11-06T15:23:40Z | 45.9 | 1 | ok | superfloppy | 3 | G: | yes | yes | yes |
| 162 | 2026-11-06T15:52:23Z | 1769 | 1 | ok | superfloppy | 3 | G: | yes | yes | yes |
| 163 | 2026-11-06T15:52:33Z | 1779.9 | 1 | ok | superfloppy | 3 | G: | yes | yes | yes |
| 164 | 2026-11-06T15:52:44Z | 1790.9 | 1 | ok | superfloppy | 3 | G: | yes | yes | yes |
| 165 | 2026-11-06T15:52:53Z | 1799.8 | 1 | ok | superfloppy | 3 | G: | yes | yes | yes |
| 166 | 2026-11-06T15:52:56Z | 1802 | 1 | ok | superfloppy | 3 | G: | yes | yes | yes |

> Full per-poll timeline is in the JSON report. Read-only observation:
> no write, no format, no repair, no drive-letter change, no disconnect.
