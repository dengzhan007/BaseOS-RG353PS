# RG353PS MTP-only Release host acceptance report

- Run ID: `20261106-120429-62aa6d`
- Started: 2026-11-06T12:11:01Z
- Finished: 2026-11-06T12:11:01Z
- Overall: **FAIL**

## Checks

| Check | Status | Detail |
| --- | --- | --- |
| tool_present | PASS | F:\workspace\2026-10-28-22-11-37\.tmp-doc\mtp-only\wt\tools\mtp\mtp_integrity.py |
| python_available | PASS | python |
| pnp_pid_0009 | FAIL | VID_2207&PID_0009 matches=0 |
| no_pid_0007_0008 | FAIL | forbidden PID matches=3 |
| no_rndis_ncm_adapter | FAIL | device-provided network adapters=1 |
| wpd_rg353ps | PASS | WPD/RG353PS entries=1 |
| wpd_sdcard_storage | PASS | WPD storages=RG353PS |
| device_ready | FAIL | PID_0009 device did not appear within the finite probe window; see PnP table above |

## PnP evidence (VID_2207 / RG353PS)

| Name | Class | PnP ID | Status |
| --- | --- | --- | --- |
| RG353PS | WPD | `USB\VID_2207&PID_0008&MI_02\7&26A4B16B&0&0002` | OK |
| Remote NDIS Compatible Device | Net | `USB\VID_2207&PID_0008&MI_00\7&26A4B16B&0&0000` | OK |
| USB Composite Device | USB | `USB\VID_2207&PID_0008\BASEOS-RG353PS` | OK |

## WPD storages

- RG353PS

## MTP pull

- Exit code: 1
- Log: `F:\workspace\2026-10-28-22-11-37\.tmp-doc\mtp-only\wt\work\rg353ps-mtp-only-test\mtp-pull.log`
- Tool report: `F:\workspace\2026-10-28-22-11-37\.tmp-doc\mtp-only\wt\work\rg353ps-mtp-only-test\mtp-report`

## Failure reasons

- pnp_pid_0009: VID_2207&PID_0009 matches=0
- no_pid_0007_0008: forbidden PID matches=3
- no_rndis_ncm_adapter: device-provided network adapters=1
- device_ready: PID_0009 device did not appear within the finite probe window; see PnP table above

> Local host acceptance. No SD card was written, no device was rebooted, no SSH was used.
