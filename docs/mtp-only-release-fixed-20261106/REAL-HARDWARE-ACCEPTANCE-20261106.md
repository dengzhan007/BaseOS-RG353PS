# Real-hardware MTP-only upgrade and acceptance (2026-11-06)

> This document supersedes the "hardware not executed" statements in the
> earlier reports in this directory. The upgrade and the full MTP acceptance
> were executed on the user's online RG353PS after explicit confirmation.

## What was upgraded

The device was **not** reflashed. A `.bosupd` payload built from the
P0-fixed MTP-only Release image was pushed over RNDIS/SSH and applied by the
device's A/B update mechanism on reboot. The payload carries both the boot and
rootfs slots, so after application the card is byte-identical to a freshly
flashed image; ROMs, saves and other card data were not touched.

| Item | Value |
| --- | --- |
| Payload | `baseos-rg353ps-1.2.4.bosupd` |
| Payload size / SHA-256 | 121,139,200 bytes / `90f04c8429461cbb5930d1c9b6dbbb5315bbda3406aeee55ec845d2dd2d4cf8b` |
| Manifest | `format=baseos-update/2`, `target=rg353ps`, `version=1.2.4`, `build=fbb7d83-dirty-20261106131355` |
| Source image SHA-256 | `fded49aa4e8b1efb66d398c4aed17638f1a6a1ee232e2c1cbf4d42aeb62d81e6` |
| MTP run_id | `20261106-131355-4a3405` |

Device state **before** the upgrade:

- `BASEOS_VERSION=1.2.4`, `BASEOS_BUILD=aa3536b-dirty-20261106013813`
- `/etc/baseos.conf` and `/mnt/boot/baseos.conf`: `usb_profile=development`, `usb_debug=yes`, `usb_mtp=yes`
- `/mnt/SDCARD/baseos.conf` still carried the OLD seed's active `usb_debug=yes` (the P0 defect, observed in the wild)

## Steps executed

1. Verified the payload would be accepted: same version but newer build stamp
   (`20261106131355` > `20261106013813`), rootfs SHA not in update history, no
   trial state, 11.6 GB free on the card.
2. Pushed the payload to `/mnt/SDCARD/` and verified the device-side SHA-256
   matched the host exactly.
3. Backed up `/mnt/SDCARD/baseos.conf` to
   `/mnt/SDCARD/baseos.conf.pre-mtp-only.bak` and removed **only** the active
   `usb_debug=yes` line (user-authorised). All other lines were preserved.
4. Rebooted. Roughly 110 s later the device re-enumerated as MTP-only.

## Result

- Windows PnP: **`USB\VID_2207&PID_0009\BASEOS-RG353PS`**, class WPD, name RG353PS.
- No `PID_0007` / `PID_0008`, no device-provided RNDIS/NCM network adapter.
- `192.168.42.1` no longer answers (100 % packet loss): USB DHCP and Dropbear
  are gone, as designed. **The device can no longer be reached over SSH**;
  reverting needs a card reader or the spare card.
- The fresh-boot hook produced the real device-side manifest at
  `2026-11-06T13:57:38Z` with 7 files including `large-128m.bin` (134217728 bytes).

One-shot Windows acceptance (`run-mtp-only-acceptance.ps1`): **14/14 checks PASS**,
`mtp_integrity.py pull` reported `labels: pass=14 fail=0 skip=0`.

Independent host-side verification against that device manifest:

| Check | Result |
| --- | --- |
| Manifest entries | 7 |
| Actual sizes matching | 7/7 |
| SHA-256 matching | 7/7 |
| 128 MiB file | downloaded and hashed |
| Chinese name / space name / three-level directory | all present and verified |

Raw evidence: `mtp-only-host-report.json`, `mtp-only-host-report.md`,
`pull-verification.json`, `mtp-pull.log`.

## Conclusion

The P0 fix and the Release profile both work on real hardware. Removing the
legacy active `usb_debug=yes` line let the fresh Release defaults
(`usb_debug=no`, `usb_mtp=yes`) take effect through the real
`config_value()` chain, giving a genuine MTP-only gadget with full 7-file
integrity verification.

## Still out of scope

Mass Storage hand-off, USB SSH/DHCP negative testing beyond PnP, long-run
stability, and Linux gvfs backends were not tested. An MTP-only PASS does not
imply those pass. No PR was merged, `main` was not modified, no Release was
created.
