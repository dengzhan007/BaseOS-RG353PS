# RG353PS MTP-only Release (P0-fixed) - reports and raw logs

**Reports and raw logs only.** The test image, the Windows acceptance script,
`image-build.json` and all build artifacts remain local and are not uploaded.

| File | What it is |
| --- | --- |
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

Real-hardware acceptance has **NOT** been executed: it needs the user's
spare TF card. PR #6 stays open, PR #5 and `main` are unchanged, no Release
was created.

