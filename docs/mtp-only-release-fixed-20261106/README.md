# RG353PS MTP-only Release (P0-fixed) - reports and raw logs

**Reports and raw logs only.** The test image, the Windows acceptance script,
`image-build.json` and all build artifacts remain local and are not uploaded.

| File | What it is |
| --- | --- |
| `REAL-HARDWARE-ACCEPTANCE-20261106.md` | **Authoritative** real-hardware upgrade + acceptance result (PASS) |
| `hardware-acceptance/` | **Authoritative** normalized read-only acceptance report and raw evidence |
| `mass-storage/check-rg353ps-mass-storage.ps1` | **Preparation only** - read-only host check for the next Mass Storage acceptance (NOT executed) |
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

Still NOT executed: Mass Storage hand-off, long-run stability, Linux gvfs.
An MTP-only PASS does not imply those pass. PR #6 stays open, PR #5 and
`main` are unchanged, no Release was created.

