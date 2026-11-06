# RG353PS MTP-only Release (P0-fixed) - reports and raw logs

**Reports and raw logs only.** The test image, the Windows acceptance script,
`image-build.json` and all build artifacts remain local and are not uploaded.

| File | What it is |
| --- | --- |
| `REAL-HARDWARE-ACCEPTANCE-20261106.md` | **Authoritative** real-hardware upgrade + acceptance result (PASS) |
| `hardware-acceptance/` | **Authoritative** normalized read-only acceptance report and raw evidence |
| `mass-storage/check-rg353ps-mass-storage.ps1` | Read-only host check for the Mass Storage hand-off (**executed: PASS**, 20/20) |
| `mass-storage/exit-recovery-host-report.json` / `.md` | Read-only exit recovery (Mass Storage -> MTP) result (**PASS**) |
| `mass-storage/README.md` | Strict device identity, superfloppy IOCTL path, exit-recovery conditions |
| `FINAL-DELIVERY-20261106-FIXED.md` | Task section 10 final delivery (10 items) |
| `mtp-only-build-audit-FIXED.md` | Fresh-card simulation + gadget/static re-audit |
| `mtp-only-release-audit.json` | Structured audit result |
| `reuse-audit.json` | Byte-level verification of reused kernel/U-Boot/firmware inputs |
| `fresh-card-baseos.conf` | Raw config produced by the real `ensure_card_config()` |
| `dataset-manifest-sample.json` | Host-side structural manifest sample (7 files) |
| `BUILD-ENVIRONMENT-FIXED.md` | Integration worktree and rebuild scope |
| `HOST-SELF-TEST-NOTES.md` | Negative self-test classification note |
| `host-script-self-test.json` / `.md` | Raw self-test evidence (NOT a hardware result) |
| `logs/*.log` | Raw build, dataset-sample and test logs |

## Status update (2026-11-06, after real-hardware acceptance)

The MTP-only Release acceptance **HAS been executed on the real RG353PS and
PASSED**. The authoritative records are:

- `REAL-HARDWARE-ACCEPTANCE-20261106.md` - upgrade procedure and result
- `hardware-acceptance/mtp-only-acceptance.md` / `.json` - normalized five-stage
  read-only verification report
- `hardware-acceptance/pnp-enumeration.json` - raw PnP evidence
- `hardware-acceptance/device-manifest.json`, `mtp-only-host-report.json`,
  `mtp-pull.log`, `pull-verification.json` - raw evidence

Verified: `VID_2207&PID_0009` only; no PID_0007/0008; no device-provided
RNDIS/NCM; 14/14 host checks; 7/7 downloaded files with matching sizes and
SHA-256 (including the 128 MiB file, Chinese names, spaces and a three-level
directory). Image SHA-256 `fded49aa...81e6` matched.

`FINAL-DELIVERY-20261106-FIXED.md` and `mtp-only-build-audit-FIXED.md` are
kept as the **build-time snapshot**: their "hardware not executed" wording is
historical and is superseded by the records above. Test data and measured
values are unchanged.

## Status update (2026-11-06, after Mass Storage acceptance)

The Mass Storage hand-off **HAS been executed on the real RG353PS in read-only
form and PASSED**: 20/20 host checks, unique `VID_2207&PID_0006` ->
`\\.\PHYSICALDRIVE3` with zero partition associations, ownership proven by
read-only `IOCTL_STORAGE_GET_DEVICE_NUMBER` (exactly one matched volume, zero
unresolved) on `G:` exFAT `BASEOS_DATA`, and 7/7 sizes plus 7/7 SHA-256. Exit
recovery back to MTP also **PASSED**: exactly one `PID_0009` root, zero
`PID_0006/0007/0008`, live WPD `RG353PS`, zero device-provided network
interfaces. Records: `mass-storage/mass-storage-host-report.json` / `.md` and
`mass-storage/exit-recovery-host-report.json` / `.md`.

A **30-minute read-only stability run also PASSED** on the same device: 166/166
polls over 1803 s with zero anomalies, the identity fingerprint never changed
(`superfloppy`, `\\.\PHYSICALDRIVE3`, `Volume{4508079a-...}`, `G:`, exFAT,
14,190,346,240 bytes) and all 7 SHA-256 checks of the 128 MiB file matched the
device manifest. Records: `mass-storage/mass-storage-stability-report.json` /
`.md`.

Still NOT executed: Mass Storage writes/data mutation, MTP<->MSC mutual
exclusion under load, Linux gvfs. A read-only Mass Storage PASS does not imply
those pass. PR #6 stays open, PR #5 and `main` are unchanged, no Release was
created.

