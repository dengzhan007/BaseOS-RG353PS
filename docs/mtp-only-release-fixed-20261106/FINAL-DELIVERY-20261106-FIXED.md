# RG353PS MTP-only Release (P0-fixed) - final delivery

- Generated (UTC): 2026-11-06T13:34:48Z
- Integration base: `fbb7d8346c19ceec0e140380aa461af6f1ce1542` (`feature/rg353ps-mtp-integrity-test`, PR #5 head)
- P0 fix applied locally: `7e29495233809c36c17f7475f064d4e421bffcad` (not pushed to the integration branch)
- Image kind: temporary hardware acceptance image, NOT a release build

> **Status update (2026-11-06, after real-hardware acceptance).** This document
> is the build-time delivery snapshot. The MTP-only Release acceptance has since
> been executed on the real RG353PS and **PASSED**. Authoritative records:
> `REAL-HARDWARE-ACCEPTANCE-20261106.md` and `hardware-acceptance/`
> (`mtp-only-acceptance.md` / `.json`, `pnp-enumeration.json`, raw logs).
> Verified: `VID_2207&PID_0009` only, no PID_0007/0008, no device-provided
> RNDIS/NCM, 14/14 host checks, 7/7 file sizes and SHA-256 matches.
> Sections 4, 9 and 10 below retain the historical build-time state and are
> superseded only on that point; all measured data is unchanged. Mass Storage,
> long-run stability and Linux gvfs remain untested - an MTP-only PASS does not
> imply those pass.

## 1. Independent fix branch and PR

- Branch: `fix/rg353ps-release-usb-profile-seed` (created from `origin/main` `4c8754fed1d13caeb07df58e18837d3890bf7ac3`)
- Commit: `7e29495233809c36c17f7475f064d4e421bffcad`
- PR: <https://github.com/dengzhan007/BaseOS-RG353PS/pull/6> (target `main`, open, **not merged**)
- PR #5 is untouched by the fix; `main` is still `4c8754f`.

## 2. Changed files

| File | Change |
| --- | --- |
| `platforms/rg353ps/rootfs/usr/sbin/baseos-init-userdata` | first-boot seed: no active `usb_debug=` / `usb_mtp=`; commented examples instead |
| `tests/test-rg353ps-usb-profile-inherit.sh` | new 18-check regression suite (real production functions) |
| `tests/test-rg353ps-usb-mtp.sh` | invokes the new suite (existing CI already runs this file) |
| `docs/usb-profile-inheritance.md` | behaviour table, precedence, legacy-card note |

No kernel, USB gadget, DWC3, supervisor, recovery, USB manager functional logic or MTP responder change.

## 3. Configuration inheritance regression results

Executed locally in the integration worktree (real output in `logs/tests.log`):

| Test | Result |
| --- | --- |
| `sh -n` on the three scripts | PASS |
| `tests/test-rg353ps-usb-profile-inherit.sh` | **18/18 PASS** |
| `tests/test-rg353ps-usb-mtp.sh` | PASS (and does invoke the new suite) |
| `tests/test-rg353ps-mtp-integrity.sh` | `Ran 35 tests ... OK` |
| `tests/test-baseos-config.sh` (Docker) | PASS |
| `tests/test-expand-storage.sh` (Docker) | **NOT COMPLETED** - the container stalled on image/dependency download and was stopped after a long timeout. This GPT-grow test is unrelated to the config-seed fix; no PASS is claimed. |

Fresh-card simulation (real `ensure_card_config()` + real `config_value()`):

- New card config contains **no active** `usb_debug` or `usb_mtp` line (raw file: `fresh-card-baseos.conf`).
- Effective values on this Release image: `usb_debug=no`, `usb_mtp=yes`.
- Explicit card `usb_debug=yes` still overrides a Release image, and explicit `no` still overrides a Development image.
- An existing non-empty card config stays byte-identical; legacy cards are not migrated.

## 4. CI results

PR #6 head `7e294952`:

- `RG353PS USB storage mode checks` / `pull_request` / job `syntax` / step `Check shell syntax`: **success** (this step runs `sh tests/test-rg353ps-usb-mtp.sh`, so the new regression did run in CI).
- `RG353PS bring-up build` / `pull_request`: **success**.
- Check-runs on the commit: `syntax` success, `build-rg353ps` success.

## 5. New MTP-only image path

Windows host (copied from the WSL build directory):

```
F:\workspace\2026-10-28-22-11-37\.tmp-doc\p0-fix\win\work\rg353ps-mtp-only-fixed\baseos-rg353ps-smoke.img.gz
```

WSL original: `/root/work/rg353ps-mtp-only-fixed/wt/work/rg353ps-mtp-only-fixed/baseos-rg353ps-smoke.img.gz`

Checksum file `baseos-rg353ps-smoke.img.gz.sha256` sits beside it. The previous
image at `.../mtp-only/wt/work/rg353ps-mtp-only-test/...` is untouched.

## 6. New image SHA-256

```
fded49aa4e8b1efb66d398c4aed17638f1a6a1ee232e2c1cbf4d42aeb62d81e6
```

Size: 139709198 bytes. Recomputed for this image (the old image was `26a07260...`).

## 7. New run_id

```
20261106-131355-4a3405
```

The temporary boot hook uses this run_id with `--profile full`: 7 files
including `large-128m.bin` (134217728 bytes), Chinese and spaced names and
a three-level directory. A host-side structural manifest sample produced by
the same production `mtp-prepare.sh` is in `dataset-manifest-sample.json`;
the device-side manifest is generated on first boot with fresh random bytes.

## 8. Windows one-shot acceptance script

```
.\work\rg353ps-mtp-only-fixed\run-mtp-only-acceptance.ps1
```

```powershell
powershell -ExecutionPolicy Bypass -File .\work\rg353ps-mtp-only-fixed\run-mtp-only-acceptance.ps1
```

Run from `F:\workspace\2026-10-28-22-11-37\.tmp-doc\p0-fix\win`. It checks
`VID_2207&PID_0009`, rejects PID_0007/0008 and device-provided RNDIS/NCM,
looks for WPD RG353PS + SDCARD, then runs `mtp_integrity.py pull` (no SSH,
no push/rename/delete/cleanup) with a finite wait and writes JSON + Markdown
reports. `host-script-self-test.*` is a negative self-test on the current
Development-mode device (PID_0008) and is **not** a hardware acceptance result.

## 9. Spare TF card test steps

1. Use a **spare** card. The current TF1 and its `baseos.conf` are untouched.
2. **No manual `baseos.conf` edit is needed any more** - the P0 fix makes a
   fresh card inherit the Release profile.
3. Write this image to the spare card with your usual tool (this task wrote no card).
4. Boot the RG353PS from it, connect USB to the Windows PC.
5. Run the one-shot script from section 8 and read `mtp-only-host-report.json/md`.
6. Expect: PID_0009 only, no RNDIS/NCM/DHCP/SSH, RG353PS + SDCARD in WPD,
   all 7 files with matching sizes and SHA-256.

> If the spare card already carries an old config with an active
> `usb_debug=yes`, it still wins. Remove that line (or the whole file) to
> restore inheritance; nothing is migrated automatically.

## 10. Hardware items NOT executed at build time (historical)

> These were outstanding **at delivery time**; the first two were subsequently
> completed and passed - see the authoritative reports linked in the status
> update above. The list is kept verbatim as process history.

- Windows PnP enumeration (needs the spare TF card)
- MTP pull of the 7-file dataset / SHA-256 verification
- Mass Storage hand-off (explicitly out of scope)
- Long-run stability (out of scope)

- No physical card was written/formatted/repartitioned, no device rebooted,
  no Mass Storage regression attempted.
- An MTP-only PASS does not imply Mass Storage or long-run stability passed.

