# RG353PS Mass Storage write-integrity report (Prepare)

- Run ID: `20261106-131355-4a3405`
- Overall: **PASS**
- Device writes in this phase: yes (new dataset only, CreateNew, no overwrite)
- Device selection: strict PnP/WMI mapping + IOCTL volume ownership; no fallback scanning
- Dataset directory: `G:\baseos-write-test-20261106-131355-4a3405`
- Mapping path: `superfloppy`; drive G:; exFAT

| Check | Status | Detail |
| --- | --- | --- |
| no_format_prompt | PASS | a Windows format prompt would be an immediate hard stop |
| strict_device_mapping | PASS | [superfloppy] unique PnP -> USBSTOR -> PHYSICALDRIVE3 -> IOCTL volume GUID mapping |
| dataset_dir_absent | PASS | checked G:\baseos-write-test-20261106-131355-4a3405; an existing directory is a hard stop |
| volume_space_sufficient | PASS | need 135667712 bytes plus 64 MiB headroom; free=12279709696 |
| dataset_created | PASS | created G:\baseos-write-test-20261106-131355-4a3405 with 7 files |
| create_new_only | PASS | every file used FileMode.CreateNew; no existing file could be overwritten |
| device_manifest_written | PASS | G:\baseos-write-test-20261106-131355-4a3405\baseos-write-test-manifest.json |
| local_manifest_written | PASS | F:\workspace\2026-10-28-22-11-37\.tmp-doc\p0-fix\win\docs\mtp-only-release-fixed-20261106\mass-storage\mass-storage-write-prepare-manifest.json |
| local_manifest_valid | PASS | manifest lists 7 entries |
| device_manifest_valid | PASS | manifest lists 7 entries (device copy: manifest lists 7 entries) |

## Files

| Relative path | Expected size | Actual size | SHA-256 match | Status |
| --- | --- | --- | --- | --- |
| small-4k.bin | 4096 | 4096 | recorded | written |
| medium-1m.bin | 1048576 | 1048576 | recorded | written |
| 中文文件名.txt | 4096 | 4096 | recorded | written |
| name with spaces.txt | 65536 | 65536 | recorded | written |
| nested/sub/deep.bin | 262144 | 262144 | recorded | written |
| 中文 目录 with spaces/嵌套 子目录/深层 文件.txt | 65536 | 65536 | recorded | written |
| large-128m.bin | 134217728 | 134217728 | recorded | written |

> The test files are left on the device on purpose: this tool never
> deletes, formats, repairs or re-letters anything, and never ejects the device.
