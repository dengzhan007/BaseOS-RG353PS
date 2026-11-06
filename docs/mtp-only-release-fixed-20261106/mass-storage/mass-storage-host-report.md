# RG353PS Mass Storage host read-only report

- Run ID: `20261106-131355-4a3405`
- Overall: **PASS**
- Device selection: strict PnP/WMI mapping + IOCTL volume ownership; no fallback scanning
- Mapping path: `superfloppy`
- PHYSICALDRIVE index: 3
- IOCTL volume records: 6; matched: 1; unresolved: 0
- Partition associations: 0

| Check | Status | Detail |
| --- | --- | --- |
| no_format_prompt | PASS | no Windows format prompt detected (additional guard) |
| pid_0006_root_unique | PASS | unique VID_2207&PID_0006 roots=1 |
| mtp_pid_0009_absent | PASS | PID_0009 matches=0 |
| wpd_mtp_absent | PASS | WPD RG353PS entries=0 |
| device_ready | PASS | unique PID_0006 identity present |
| strict_device_mapping | PASS | [superfloppy] unique PnP -> USBSTOR -> PHYSICALDRIVE3 -> IOCTL volume GUID mapping |
| topology_inspected | PASS | path=superfloppy; partitions=0; ioctl_records=6 |
| no_raw_or_unknown_filesystem | PASS | all inspected partitions/volumes on path superfloppy have a known filesystem |
| volume_ownership_confirmed | PASS | volume GUID \\?\Volume{4508079a-d83f-11f1-9794-c8a3e85ae46c} -> PHYSICALDRIVE3 via IOCTL |
| target_volume_has_drive_letter | PASS | volume=G: |
| exfat_volume_visible | PASS | filesystem=exFAT |
| dataset_dir_found | PASS | looked only on G: |
| manifest_present | PASS | G:\baseos-mtp-test-20261106-131355-4a3405\baseos-mtp-test-manifest.json |
| seven_files_listed | PASS | manifest entries=7 |
| all_sizes_match | PASS | 7/7 sizes match |
| all_sha256_match | PASS | 7/7 SHA-256 match |
| large_128mib_verified | PASS | 128 MiB file sized 134217728 and hashed |
| unicode_name_verified | PASS | Chinese filename read and hashed |
| space_name_verified | PASS | filename with spaces read and hashed |
| three_level_dir_verified | PASS | three-level directory read and hashed |


> Read-only observation. Ambiguous, RAW or unowned volumes are
> never opened; a format prompt is an immediate hard stop.
