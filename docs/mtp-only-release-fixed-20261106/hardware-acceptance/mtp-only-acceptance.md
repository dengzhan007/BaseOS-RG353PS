# RG353PS MTP-only Release - hardware acceptance report

- Overall: **PASS**
- Scope: read-only verification. No source change, no physical disk/TF card write, no Mass Storage.
- Image: `F:\workspace\2026-10-28-22-11-37\.tmp-doc\p0-fix\win\work\rg353ps-mtp-only-fixed\baseos-rg353ps-smoke.img.gz`
- Image SHA-256: `fded49aa4e8b1efb66d398c4aed17638f1a6a1ee232e2c1cbf4d42aeb62d81e6` (MATCH)
- run_id: `20261106-131355-4a3405`

## 1. Local pre-check

| Item | Result |
| --- | --- |
| Test image exists | PASS |
| Image SHA-256 equals expected | PASS |
| `run-mtp-only-acceptance.ps1` exists | PASS |
| Script only runs PnP checks + `pull` (`--skip-prepare`) | PASS |

## 2. PnP enumeration

Captured with `Get-CimInstance Win32_PnPEntity` filtered by `VID_2207`. Raw data: `pnp-enumeration.json`.

| Name | PNPClass | PNPDeviceID | Status |
| --- | --- | --- | --- |
| RG353PS | WPD | `USB\VID_2207&PID_0009\BASEOS-RG353PS` | OK |

- WPD storages enumerated: `RG353PS`.
- The device exposes its `/mnt/SDCARD` user-data volume as the WPD storage named `RG353PS`;
  there is no separate object literally named `SDCARD`. This is the device's own naming.

| Check | Result |
| --- | --- |
| `pid_0009_present` | PASS |
| `no_pid_0007_0008` | PASS |
| `no_device_rndis_ncm` | PASS |
| `wpd_rg353ps_present` | PASS |
| `sdcard_storage_visible` | PASS |

## 3. MTP pull (one run)

Command, executed once from `F:\workspace\2026-10-28-22-11-37\.tmp-doc\p0-fix\win`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\work\rg353ps-mtp-only-fixed\run-mtp-only-acceptance.ps1
```

- Script exit: 0; host report `pass=True`, failures=0.
- Tool labels: `pass=14 fail=0 skip=0` (raw log: `mtp-pull.log`).
- No `prepare`, `cleanup`, push/rename/delete/overwrite, SSH or Mass Storage was invoked.

## 4. Independent integrity verification

The device-generated manifest (`origin=device`, `created_utc=2026-11-06T13:57:38Z`) is the authority.
Its hashes differ from the repository's `dataset-manifest-sample.json`: **yes**.
Every file in `pulled\received\` was re-sized and re-hashed on the host.

| File | Expected size | Actual size | Size | SHA-256 |
| --- | --- | --- | --- | --- |
| `small-4k.bin` | 4096 | 4096 | PASS | PASS |
| `medium-1m.bin` | 1048576 | 1048576 | PASS | PASS |
| `large-128m.bin` | 134217728 | 134217728 | PASS | PASS |
| `中文文件名.txt` | 1024 | 1024 | PASS | PASS |
| `name with spaces.txt` | 1024 | 1024 | PASS | PASS |
| `中文 目录 with spaces/嵌套 子目录/深层 文件.txt` | 1024 | 1024 | PASS | PASS |
| `nested/sub/deep.bin` | 65536 | 65536 | PASS | PASS |

Counts: 7/7 downloaded, 7/7 sizes match, 7/7 SHA-256 match.

| Required property | Result |
| --- | --- |
| `large-128m.bin` = 134217728 bytes and hash matches | PASS |
| Chinese filename accessible and verified | PASS |
| Filename with spaces accessible and verified | PASS |
| Three-level Chinese/space directory accessible and verified | PASS |

> Enumerating a file, seeing it exist, or finishing a transfer is NOT counted as
> integrity passing. Only a matching actual size AND a matching SHA-256 count.

## 5. Final conclusions

1. Image SHA-256 matches expected: **YES**.
2. PnP is `VID_2207&PID_0009` only, no PID_0007/0008: **YES**.
3. Device-provided RNDIS/NCM completely absent: **YES**.
4. All 7 files' sizes and SHA-256 pass: **YES**.
5. Overall: **PASS**.

Raw evidence in this directory: `pnp-enumeration.json`, `device-manifest.json`,
`mtp-only-host-report.json` / `.md`, `mtp-pull.log`, `pull-verification.json`.

Not executed: Mass Storage hand-off, long-run stability, Linux gvfs, SSH/Dropbear
(the device is MTP-only by design). No PR was modified, no commit created.
