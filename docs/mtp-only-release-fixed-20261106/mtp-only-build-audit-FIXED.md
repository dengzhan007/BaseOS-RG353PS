# P0-fixed MTP-only Release image - re-audit

- Generated (UTC): 2026-11-06T13:34:48Z
- Source: integration base `fbb7d8346c19ceec0e140380aa461af6f1ce1542` + local P0 fix `7e29495233809c36c17f7475f064d4e421bffcad`
- Fix branch / PR: `fix/rg353ps-release-usb-profile-seed` / <https://github.com/dengzhan007/BaseOS-RG353PS/pull/6>
- Kernel release: `7.2.7-baseos-rg353ps`
- USB build profile: **release** (`BASEOS_USB_PROFILE=release`)

## Configurations

`/etc/baseos.conf` in the staged rootfs:

```ini
usb_profile=release
usb_debug=no
usb_mtp=yes
```

BASEOS_BOOT copy read back from `boot-fat.img ::/baseos.conf`: **PASS (same three keys)**.

Fresh card `baseos.conf` produced by the **real** `ensure_card_config()`
(full text in `fresh-card-baseos.conf`):

```ini
# BaseOS RG353PS settings you can change without rebuilding.
#
# This file sits next to Games/ on the card and is read before the copy inside
# the system image, so editing it here overrides the defaults. Keys that are not
# present here keep their built-in values - frontend selection, in particular,
# is automatic and needs nothing here.
#
# Delete this file and reboot to get it back with the defaults.

# Verbose tracing for the USB-storage session and the boot-key report.
# Leaves nothing on the card when no.
debug=no

# USB network / SSH:
# Leave usb_debug unset to inherit the image profile (development: yes,
# release: no). An active usb_debug= line here always wins over the copy
# inside the image, so only set it when you want to override the image
# explicitly. Set usb_debug=yes to enable networking, or usb_debug=no to
# disable it. Networking gives 192.168.42.1 with dropbear on port 22.
# usb_debug=yes
#
# MTP is selected by the image profile too. Leave usb_mtp unset to inherit it;
# only add an active line here to override the image explicitly.
# usb_mtp=yes

# Uncomment to change the frontend order. The default is shown.
# frontends_order=nextui,slot,custom,baseos

# Uncomment if the PC shows an unknown device instead of a network adapter:
# newer Windows no longer ships the RNDIS driver, NCM is the one it binds.
# usb_debug_mode=ncm
```

Active `usb_debug` / `usb_mtp` keys: **none**.
Resolved with the **real** `config_value()` (card > boot > etc):

- `usb_debug=no`
- `usb_mtp=yes`

## Gadget static audit (code, not config text)

| Check | Result |
| --- | --- |
| `pid_0009_for_mtp_only` | PASS |
| `only_ffs_mtp_when_network_off` | PASS |
| `dhcp_ssh_gated_on_network` | PASS |
| `no_network_fallback_on_mtp_failure` | PASS |
| `umtp_responder_started` | PASS |

- Expected Product ID: `0x0009` (VID `0x2207`).
- DHCP / Dropbear: not started in MTP-only path (NETWORK_ENABLED=0).
- MTP-only start failure: UDC stays unbound, no network fallback (fail-closed retained).

## Image and dataset

- run_id: `20261106-131355-4a3405`
- Dataset profile: full, 7 files (manifest sample: `dataset-manifest-sample.json`).
- Image size: 139709198 bytes
- Image SHA-256: `fded49aa4e8b1efb66d398c4aed17638f1a6a1ee232e2c1cbf4d42aeb62d81e6`
- Image-build metadata kept locally (`image-build.json`), not uploaded.

## Reused build inputs

- kernel release: `7.2.7-baseos-rg353ps`
- kernel inputs changed between the two builds: **none**
- all 11 reused files byte-identical: **True**
- rebuild scope: rootfs (BASEOS_USB_PROFILE=release) + image only
- full evidence: `reuse-audit.json`

## Raw logs

- `logs/dataset-sample.log`
- `logs/image.log`
- `logs/rootfs.log`
- `logs/tests.log`

