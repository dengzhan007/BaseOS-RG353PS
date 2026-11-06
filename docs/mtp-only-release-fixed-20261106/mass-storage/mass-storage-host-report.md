# RG353PS Mass Storage host read-only report

- Run ID: `20261106-131355-4a3405`
- Overall: **FAIL**
- Device selection: strict PnP/WMI mapping, no fallback scanning

| Check | Status | Detail |
| --- | --- | --- |
| no_format_prompt | PASS | no Windows format prompt detected (additional guard) |
| pid_0006_root_unique | PASS | unique VID_2207&PID_0006 roots=1 |
| mtp_pid_0009_absent | PASS | PID_0009 matches=0 |
| wpd_mtp_absent | PASS | WPD RG353PS entries=0 |
| device_ready | PASS | unique PID_0006 identity present |
| strict_device_mapping | FAIL | no partition is associated with the mapped disk |

## Failure reasons

- strict_device_mapping: no partition is associated with the mapped disk

> Read-only observation. Ambiguous or unrecognised volumes are
> never opened; a format prompt is an immediate hard stop.
