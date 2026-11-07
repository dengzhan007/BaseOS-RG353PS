# RG353PS MTP-only Release host acceptance report

- Run ID: `20261106-131355-4a3405`
- Started: 2026-11-06T14:08:50Z
- Finished: 2026-11-06T14:09:07Z
- Overall: **PASS**

## Checks

| Check | Status | Detail |
| --- | --- | --- |
| tool_present | PASS | F:\workspace\2026-10-28-22-11-37\.tmp-doc\p0-fix\win\tools\mtp\mtp_integrity.py |
| python_available | PASS | C:\Users\zhan\.workbuddy\binaries\python\versions\3.13.12\python3.exe |
| pnp_pid_0009 | PASS | VID_2207&PID_0009 matches=1 |
| no_pid_0007_0008 | PASS | forbidden PID matches=0 |
| no_rndis_ncm_adapter | PASS | device-provided network adapters=0 |
| wpd_rg353ps | PASS | WPD/RG353PS entries=1 |
| wpd_sdcard_storage | PASS | WPD storages=RG353PS |
| device_ready | PASS | PID_0009 device present |
| mtp_pull_exit | PASS | mtp_integrity.py pull exit=0 |
| mtp_tool_labels | PASS | pass=14 fail=0 skip=0 |
| mtp_manifest_7_files | PASS | manifest entries=7 |
| mtp_sizes_all_match | PASS | 7/7 sizes match |
| mtp_sha256_all_match | PASS | 7/7 SHA-256 match |
| mtp_128mib_verified | PASS | 128 MiB file downloaded and hashed |

## PnP evidence (VID_2207 / RG353PS)

| Name | Class | PnP ID | Status |
| --- | --- | --- | --- |
| RG353PS | WPD | `USB\VID_2207&PID_0009\BASEOS-RG353PS` | OK |

## WPD storages

- RG353PS

## MTP pull

- Exit code: 0
- Log: `F:\workspace\2026-10-28-22-11-37\.tmp-doc\p0-fix\win\work\rg353ps-mtp-only-fixed\mtp-pull.log`
- Tool report: `F:\workspace\2026-10-28-22-11-37\.tmp-doc\p0-fix\win\work\rg353ps-mtp-only-fixed\mtp-report`

> Local host acceptance. No SD card was written, no device was rebooted, no SSH was used.
