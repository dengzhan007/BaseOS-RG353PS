# RG353PS Mass Storage write-integrity report (Verify)

- Run ID: `20261106-131355-4a3405`
- Overall: **PASS**
- Device writes in this phase: no (read-only verification)
- Device selection: strict PnP/WMI mapping + IOCTL volume ownership; no fallback scanning
- Dataset directory: `G:\baseos-write-test-20261106-131355-4a3405`
- Mapping path: `superfloppy`; drive G:; exFAT

| Check | Status | Detail |
| --- | --- | --- |
| local_manifest_readable | PASS | manifest lists 7 entries |
| no_format_prompt | PASS | a Windows format prompt would be an immediate hard stop |
| strict_device_mapping | PASS | [superfloppy] unique PnP -> USBSTOR -> PHYSICALDRIVE3 -> IOCTL volume GUID mapping |
| dataset_dir_present | PASS | expected G:\baseos-write-test-20261106-131355-4a3405; a missing directory is a hard stop and is never created |
| identity_remeasured | PASS | drift fields: none |
| all_files_present | PASS | missing=0 |
| all_sizes_match | PASS | mismatched sizes=0 |
| all_sha256_match | PASS | mismatched SHA-256=0 |
| manifest_comparison | PASS | all manifest entries match on the device |
| device_manifest_consistent | PASS | device manifest matches the local manifest entry-for-entry |

## Files

| Relative path | Expected size | Actual size | SHA-256 match | Status |
| --- | --- | --- | --- | --- |
| small-4k.bin | 4096 | 4096 | yes | match |
| medium-1m.bin | 1048576 | 1048576 | yes | match |
| 中文文件名.txt | 4096 | 4096 | yes | match |
| name with spaces.txt | 65536 | 65536 | yes | match |
| nested/sub/deep.bin | 262144 | 262144 | yes | match |
| 中文 目录 with spaces/嵌套 子目录/深层 文件.txt | 65536 | 65536 | yes | match |
| large-128m.bin | 134217728 | 134217728 | yes | match |

> The test files are left on the device on purpose: this tool never
> deletes, formats, repairs or re-letters anything, and never ejects the device.
