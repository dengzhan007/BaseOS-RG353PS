# RG353PS MTP-only Release Profile - final delivery (task §10)

- Generated (UTC): 2026-11-06T12:49:29Z
- Source commit: `2809e62463e28c1cc32746138d1fe9a11cdd853d` (PR #5 branch, detached worktree)
- Image kind: temporary hardware acceptance image, NOT a release build

## 1. Build result

**SUCCESS** - U-Boot, kernel, firmware, Release rootfs and smoke image all
completed in the isolated work directory. The final `build-image.sh` pass
was run after the temporary boot hook was injected into the staged rootfs.
Raw logs: `logs/`. A first U-Boot attempt was aborted because the official
Debian mirror stalled inside the build container; the retry used the TUNA
mirror (see `BUILD-ENVIRONMENT-20261106.md`). Both attempts' logs are kept.

## 2. Image local path

```
/root/work/baseos-rg353ps-mtp-only/wt/work/rg353ps-mtp-only-test/baseos-rg353ps-smoke.img.gz
```

Checksum file: `baseos-rg353ps-smoke.img.gz.sha256` (same directory).
Metadata: `image-build.json`. Neither is uploaded to GitHub.

## 3. SHA-256

```
26a0726037ae8702c672904355494e5aecacae6161c6cdef2d26c2cf4de7a320
```

Image size: 139708622 bytes.

## 4. Release Profile audit

- `/etc/baseos.conf`: `usb_profile=release, usb_debug=no, usb_mtp=yes`
- BASEOS_BOOT copy: **PASS (same three keys)**
- Expected USB identity: `VID_2207&PID_0009`; no RNDIS/NCM, no DHCP, no Dropbear.
- Static code audit (USB manager, configfs links, fail-closed): see
  `mtp-only-build-audit.md` section 3, all 7 items recorded.
- **Blocking risk found**: `baseos-init-userdata` seeds
  `/mnt/SDCARD/baseos.conf` with `usb_debug=yes` on a fresh card, and
  `config_value()` reads that card copy first. A blank spare card would
  therefore override the Release default and bring RNDIS/SSH back. The
  temporary boot hook audits this read-only; see section 6 below.

## 5. Windows one-shot acceptance script

Path (host worktree):

```
.\work\rg353ps-mtp-only-test\run-mtp-only-acceptance.ps1
```

Command:

```powershell
powershell -ExecutionPolicy Bypass -File .\work\rg353ps-mtp-only-test\run-mtp-only-acceptance.ps1
```

It performs finite PnP probing (no infinite wait), hard-fails on
PID_0007/0008 or a device-provided RNDIS/NCM adapter, then runs
`mtp_integrity.py pull` with `--backend windows-wpd --run-id 20261106-120429-62aa6d
 --skip-prepare --keep-workdir --timeout 300`, writing
`mtp-only-host-report.json` / `.md`. It never uses SSH, never runs push/ops,
never writes an SD card and never reboots the device.

## 6. Spare-card boot test (short)

1. Use a **spare** TF card. Do NOT overwrite the current TF1 with ROMs/data.
2. Before first boot, put a `baseos.conf` on the card's data partition via a
   card reader, containing `usb_debug=no`, `usb_mtp=yes`,
   `usb_profile=release` (works around the seeding risk above).
3. Write the test image to that spare card with your usual tool; this task
   did NOT write any card.
4. Boot the RG353PS from the spare card, connect USB to the Windows PC.
5. Run the one-shot script from section 5 and read the two reports.
6. Expected: PID_0009 only, no RNDIS/NCM/DHCP/SSH, RG353PS + SDCARD in WPD,
   7 files pulled with matching sizes and SHA-256, including the 128 MiB
   file, Chinese names, spaces and the three-level directory.

## 7. What could not be automated, and why

- Windows PnP enumeration (needs the spare card to be booted)
- MTP pull of the 7-file dataset / SHA-256 verification
- Mass Storage hand-off (explicitly out of scope)
- Long-run stability (out of scope)

- No physical card was written/formatted/repartitioned, no device was
  rebooted: the task explicitly forbids it and requires the user's spare card.
- The MTP-only host report does not exist yet: it is produced by the one-shot
  script only after the spare card is booted. Do not read the
  `pretest-pnp-baseline.*` files as an acceptance result - they are the
  host state BEFORE the test image was ever booted.
- Mass Storage hand-off and long-run stability are out of scope; an MTP-only
  PASS does not imply either of them passed.

> PR #5 was NOT merged. `main` was NOT modified. No GitHub Release was
> created. Only reports and raw logs are uploaded to the branch.

