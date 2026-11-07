# RG353PS USB architecture

## Goals

BaseOS owns USB device-mode behaviour below the frontend layer. NextUI, Slot and
other frontends must not implement USB networking, MTP or raw mass-storage
gadget setup independently.

| Build profile | USB network / SSH | MTP | Default |
|---|---:|---:|---|
| Development/test | On | On | Composite RNDIS/NCM + MTP |
| Release | Off | On | MTP only |
| Either profile, on request | Exclusive | Exclusive | Existing Mass Storage mode |

A card-side `/mnt/SDCARD/baseos.conf` overrides image defaults using the
independent `usb_debug=yes|no` and `usb_mtp=yes|no` switches. Persistent USB
failure reports have a separate `usb_diagnostics=yes|no` opt-in (default
`no`); it does not enable USB networking or SSH.

## Composite Gadget

The normal gadget lives at `/sys/kernel/config/usb_gadget/baseos_debug`. One
configuration contains:

- `rndis.usb0`, `ncm.usb0` or `ecm.usb0` when `usb_debug=yes`.
- `ffs.mtp` when `usb_mtp=yes`.

Development builds combine network + SSH and MTP. RNDIS keeps its Microsoft OS
compatible-ID descriptors. MTP uses the standard FunctionFS interface serviced
by userspace `uMTP-Responder`. No Android `adbd`, Android runtime libraries or
kernel `f_mtp` function are needed.

| Functions | Product ID |
|---|---:|
| Network only | `0x0007` |
| Network + MTP | `0x0008` |
| MTP only | `0x0009` |
| Existing Mass Storage | `0x0006` |

## FunctionFS startup order

FunctionFS descriptors must exist before UDC bind. The USB manager:

1. Mounts ConfigFS and creates the gadget/configuration.
2. Creates and links the requested network and/or `ffs.mtp` function.
3. Mounts FunctionFS at `/dev/ffs-mtp`.
4. Starts `umtprd` and waits for endpoint nodes `ep1`, `ep2` and `ep3`.
5. Binds the configuration to the RK3566 DWC3 UDC.
6. Configures DHCP and Dropbear only when the network function is enabled.

The manager is backgrounded by `rcS`; UDC discovery and MTP setup never block
frontend hand-off. If MTP fails in a development composite build, the manager
falls back to network-only. In an MTP-only release build it fails closed.

## MTP storage boundary

MTP exposes exactly `/mnt/SDCARD`, the already-mounted exFAT user-data
filesystem. It never exposes the raw block device, `/`, `/mnt`, BASEOS_BOOT
or BASEOS_ROOT. Linux remains the filesystem owner while the host requests
file operations over MTP.

The frontend should be paused or exited before a host edits files that it may
be changing. MTP avoids simultaneous raw block-device mounting, but does not
prevent application-level conflicts on the same file. The responder flushes
completed transfers before acknowledging them.

## Mass Storage hand-off

Mass Storage remains separate and exclusive, preserving the existing helper and
its tested safety rules. On entry, `baseos-usb-storage` stops the normal USB
manager, which releases UDC and stops/unmounts FunctionFS. Mass Storage then
exports the selected data partition. Cleanup restarts the USB manager, which
restores the profile selected by the image and card configuration.

Never mount `/mnt/SDCARD` locally while Mass Storage exports that raw partition.

## Build profiles and boot cost

`build-rootfs.sh` accepts `BASEOS_USB_PROFILE=development|release`:

- `development` (local/default): `usb_debug=yes`, `usb_mtp=yes`.
- `release`: `usb_debug=no`, `usb_mtp=yes`.

The release workflow uses development for feature branches and release defaults
for main/version tags. The card-side config can override either setting.

The manager is started in the background by `rcS`. MTP does not run on the
synchronous frontend boot path, and no storage pre-scan is done at boot; files
are enumerated in response to host requests. The intended extra boot-path delay
is zero by design, but actual USB enumeration time needs hardware measurement.

## Persistent USB diagnostics

The USB manager keeps its live log and probe snapshot in `/run` for the
current session. By default it does not copy these reports to the user-data
card. This is intentional: a recoverable reconnect event should not leave
diagnostic files behind during normal use.

The image-side default file
`platforms/rg353ps/rootfs/etc/baseos.conf` explicitly contains
`usb_diagnostics=no`. However, the card-side `/mnt/SDCARD/baseos.conf` is
seeded only once and is never rewritten on later boots or system updates.
Therefore, an existing installation may have a card-side file that predates
this option and does not show the setting. A missing key is treated as the
default `no`; it does not enable persistent diagnostics.

For clarity, you can add this line to `/mnt/SDCARD/baseos.conf` to record
the normal default explicitly:

```ini
usb_diagnostics=no
```

To collect persistent evidence, change the setting to `yes` and reproduce
the USB issue:

```ini
usb_diagnostics=yes
```

When enabled, the manager may write:

- `/mnt/SDCARD/rg353ps-usb-probe.txt` — UDC, PHY/extcon, power-supply and
  relevant kernel-message snapshots.
- `/mnt/SDCARD/rg353ps-usb-debug.txt` — the USB manager's recent runtime log,
  including Supervisor recovery activity.

The switch is independent of `usb_debug` (RNDIS/NCM/ECM and SSH) and
`debug` (verbose Mass Storage tracing). It gates persistent card copies only;
it does not disable in-memory logging, USB reconnect supervision, or recovery.
The forced-save path used for failed start/stop operations also respects this
opt-in. Set it back to `no` after collecting evidence. Files already written
are not automatically deleted when the switch is turned off.

## Kernel and source dependencies

The current kernel config already enables `CONFIG_USB_CONFIGFS=y`,
`CONFIG_USB_F_FS=y` and `CONFIG_USB_CONFIGFS_F_FS=y`. No dedicated kernel MTP
function or Android patch is required.

The rootfs build pins uMTP-Responder to upstream commit
`d3fe71b68e9af5472e72a843cda2c31c20167231`, builds it for the target Alpine
userspace, and installs its GPL-3.0 license at
`/usr/share/licenses/uMTP-Responder/`.

## Reconnect enumeration and hardware validation

### Functional baseline

The RG353PS functional source baseline is `main@507004ee`, with
`usb_reconnect_kernel_revision=bvalid-otg-sm-serialized-v1`. The 2026-11-06
hardware matrix used this functional candidate with nine additional
low-frequency DWC3/gadget/UDC `dev_dbg` observation callsites injected by the
diagnostic branch. Those callsites only record execution; they do not perform
recovery or change Supervisor policy. The diagnostic image is not the clean
production artifact.

### 2-host / 2-cable matrix (39 valid cycles)

| Host / cable | Valid cycles | Supervisor re-probe | Rate |
|---|---:|---:|---:|
| PC-A + cable 1 | 10 | 8 | 80% |
| PC-A + cable 3 | 10 | 0 | 0% |
| PC-B + cable 1 | 10 | 2 | 20% |
| PC-B + cable 3 | 9 | 0 | 0% |
| **Total** | **39** | **10** | **25.6%** |

PC-B round 30 was invalidated because the host lost power. PC-A run 2 is the
authoritative 20-cycle set; PC-A run 1 is retained separately because its
diagnostic log hit the old 20,000-line cap during an intermittent WARN burst.

All 39 valid cycles recovered within 20 seconds. RNDIS, DHCP and MTP were
detected successfully in all 39 cycles. No APIPA/DHCP failure or
`gadget.c:2076` WARN burst occurred in this effective set. Ten cycles used
Supervisor DWC3 re-probe (Path A); 29 recovered without Supervisor re-probe
(Path B). Path A took about 9–11 seconds; Path B about 1–5 seconds.

The old independent baseline was 19/40 (47.5%) Supervisor re-probes. The new
39-cycle result is 10/39 (25.6%). This is an observational comparison, not a
controlled code A/B test, so the rate reduction must not be attributed solely
to workqueue serialization.

### Cable disposition

Cable 1 had a materially higher re-probe rate than cable 3 on both hosts.
The user reports cable 1 is much longer. The raw PHY captures also show more
additional BVALID transitions with cable 1. This supports treating cable 1 as
a suspect cable with potentially poorer electrical characteristics; it does
not prove excessive resistance, VBUS drop or signal-impedance non-compliance.

- Treat cable 1 as a suspect long cable and exclude it from reference testing.
- Keep cable 3 as the current reference cable.
- Keep the current Supervisor DWC3 re-probe as the working fallback for
  `not attached`.
- Do not change PHY, DWC3, gadget, DHCP or USB state-machine logic merely to
  accommodate cable 1.
- A PC-C comparison with cable 1 and a new short USB 2.0 High-Speed data cable
  is optional supplementary evidence. If run, swap the two adjacent host-port
  assignments halfway through the test to separate cable and port effects.

### One-shot soft-connect test

In one observed `not attached` failure, writing `disconnect` and `connect`
to `/sys/class/udc/fcc00000.usb/soft_connect` did not recover the link after
eight seconds. Recovery occurred after Supervisor DWC3 re-probe. Keep this
one-shot test diagnostic-only; do not add it to automatic recovery.

### Diagnostic evidence

The diagnostic branch retains the full report, per-cycle CSV, hashes and raw
captures:
- [40-cycle final report](https://github.com/dengzhan007/BaseOS-RG353PS/blob/usb-reconnect-diag/docs/usb-reconnect-tests/40round-20261106/RESULT-40round.md)
- [per-cycle CSV](https://github.com/dengzhan007/BaseOS-RG353PS/blob/usb-reconnect-diag/docs/usb-reconnect-tests/40round-20261106/cycles.csv)
- [raw diagnostic captures](https://github.com/dengzhan007/BaseOS-RG353PS/tree/usb-reconnect-diag/docs/usb-reconnect-tests/40round-20261106/raw)
- [DWC3/PHY source review](https://github.com/dengzhan007/BaseOS-RG353PS/blob/usb-reconnect-diag/platforms/rg353ps/USB-RECONNECT-ROOT-CAUSE-REVIEW.md)

Do not copy the DWC3 diagnostic injector into the clean release build.

### Remaining hardware validation

The reconnect matrix confirms enumeration recovery and host detection of
RNDIS/DHCP/MTP. It does not establish:
- byte-for-byte integrity of large MTP transfers in both directions;
- Chinese names, spaces, deep paths, create, rename and delete over MTP;
- MTP-only release-profile enumeration on hardware;
- long-duration unexpected-unplug stress;
- complete Mass Storage enter/exit hardware regression.

Keep these as separate release checklist items. The 39-cycle reconnect
result is not a full USB feature certification.
