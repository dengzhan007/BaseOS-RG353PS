# RG353PS MTP-only Release Profile - build and static acceptance audit

- Generated (UTC): 2026-11-06T12:48:18Z
- Source commit: `2809e62463e28c1cc32746138d1fe9a11cdd853d` (`feature/rg353ps-mtp-integrity-test`, PR #5)
- Base main: `4c8754fed1d13caeb07df58e18837d3890bf7ac3` (unchanged, PR not merged)
- Kernel release: `7.2.7-baseos-rg353ps`
- USB build profile: **release** (`BASEOS_USB_PROFILE=release`)
- MTP test run_id: `20261106-120429-62aa6d`

## 1. /etc/baseos.conf in the staged rootfs

```ini
usb_profile=release
usb_debug=no
usb_mtp=yes
```

Static check: **PASS**.

## 2. BASEOS_BOOT copy

`build-image.sh` copies `/work/rootfs/etc/baseos.conf` into the FAT boot
partition via `mcopy -o -i`. Read back from `boot-fat.img ::/baseos.conf`:
**PASS - same three keys**.

## 3. USB manager / configfs static audit (code, not configuration text)

| # | Check | Result |
| --- | --- | --- |
| 1 | Card baseos.conf auto-generated | yes - baseos-init-userdata::ensure_card_config seeds /mnt/SDCARD/baseos.conf on first boot |
| 2 | Card config can override Release defaults | YES - config_value() order is /mnt/SDCARD > /mnt/boot > /etc; the seeded card file contains usb_debug=yes. This is a blocking risk, see report. |
| 3 | Only MTP FunctionFS when network off | yes - build_gadget() with NETWORK_ENABLED=0 creates only ffs.mtp, clears stale network links and OS descriptors |
| 4 | MTP-only Product ID | yes - case 0:1 in build_gadget() sets 0x0009 |
| 5 | DHCP / Dropbear gated by usb_debug | yes - do_start() calls configure_iface/start_dhcp/start_sshd only inside NETWORK_ENABLED=1 |
| 6 | uMTP-Responder start path | yes - do_start() calls baseos-usb-mtp start, which mounts functionfs and starts umtprd |
| 7 | USB manager fail-closed | yes - when MTP start fails in MTP-only mode the UDC is left unbound and start exits 1; no network fallback |

> **Blocking risk (P0).** `baseos-init-userdata::ensure_card_config()` seeds
> `/mnt/SDCARD/baseos.conf` with `usb_debug=yes` on a fresh card, and
> `baseos-usb-debug::config_value()` reads the card copy *first*. A blank spare
> card therefore overrides the image Release default and brings RNDIS/SSH back.
> The temporary boot hook performs a READ-ONLY audit of all three config
> files and logs the effective values; it does **not** modify any existing
> card config, per the safety constraint. Before booting the spare card, put a
> `baseos.conf` on its data partition (via a card reader) containing
> `usb_debug=no`, `usb_mtp=yes`, `usb_profile=release`. The Windows one-shot
> script hard-fails on PID_0007/0008 so this cannot pass unnoticed.

## 4. Temporary boot prepare hook

- Helper: `/root/work/baseos-rg353ps-mtp-only/wt/work/rg353ps-mtp-only-test/rootfs/usr/sbin/mtp-test-prepare.sh` (verbatim copy of `tools/mtp/device/mtp-prepare.sh`)
- Hook: `/root/work/baseos-rg353ps-mtp-only/wt/work/rg353ps-mtp-only-test/rootfs/usr/sbin/mtp-only-test-prepare`
- Insertion: immediately before the USB Gadget manager start block in rcS (after user-data init)
- Order: after `/mnt/SDCARD` is mounted, **before** `baseos-usb-debug start` (synchronous).
- Refuses to overwrite an existing `baseos-mtp-test-20261106-120429-62aa6d` directory.
- Any failure is logged to `/mnt/SDCARD/baseos-mtp-only-test.log` and boot continues.
- `sh -n` passed on the helper, the hook and the patched temporary `rcS`.
- No git-tracked `rcS` or rootfs source file was modified.

## 5. Test dataset (profile `full`)

| File | Size (bytes) |
| --- | --- |
| `small-4k.bin` | 4096 |
| `medium-1m.bin` | 1048576 |
| `large-128m.bin` | 134217728 |
| `中文文件名.txt` | 1024 |
| `name with spaces.txt` | 1024 |
| `中文 目录 with spaces/嵌套 子目录/深层 文件.txt` | 1024 |
| `nested/sub/deep.bin` | 65536 |

Standard marker and SHA-256 manifest are produced by `mtp-prepare.sh`.
Covers 128 MiB, Chinese names, spaces and a three-level directory.

## 6. Image

- Path: `/root/work/baseos-rg353ps-mtp-only/wt/work/rg353ps-mtp-only-test/baseos-rg353ps-smoke.img.gz`
- Size: 139708622 bytes
- SHA-256: `26a0726037ae8702c672904355494e5aecacae6161c6cdef2d26c2cf4de7a320`
- Checksum file: `baseos-rg353ps-smoke.img.gz.sha256`
- Metadata: `image-build.json`

## 7. Build logs (raw evidence)

- `logs/firmware.log`
- `logs/image-final.log`
- `logs/image.log`
- `logs/kernel.log`
- `logs/rootfs.log`
- `logs/uboot.log`

## 8. Not executed (requires the spare card)

- Windows PnP enumeration (needs the spare card to be booted)
- MTP pull of the 7-file dataset / SHA-256 verification
- Mass Storage hand-off (explicitly out of scope)
- Long-run stability (out of scope)

> This is a temporary hardware acceptance image, not a release build.
> No physical SD card was written, formatted or repartitioned. No device was
> rebooted. No SSH, Mass Storage or MTP upload test was attempted.

