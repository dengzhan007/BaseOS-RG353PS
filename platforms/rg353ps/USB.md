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
independent `usb_debug=yes|no` and `usb_mtp=yes|no` switches.

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

## Kernel and source dependencies

The current kernel config already enables `CONFIG_USB_CONFIGFS=y`,
`CONFIG_USB_F_FS=y` and `CONFIG_USB_CONFIGFS_F_FS=y`. No dedicated kernel MTP
function or Android patch is required.

The rootfs build pins uMTP-Responder to upstream commit
`d3fe71b68e9af5472e72a843cda2c31c20167231`, builds it for the target Alpine
userspace, and installs its GPL-3.0 license at
`/usr/share/licenses/uMTP-Responder/`.

## Reconnect enumeration

### Observed baseline

Measured on commit `ff88dd9` with a known-good replacement cable, using one
host computer and the same host USB port for ten unplug/replug cycles. All ten
connections eventually became usable, but four did not enumerate immediately:

| After replug | Count | Recovery |
|---|---:|---|
| `configured` immediately | 3 | none |
| `addressed` then `configured` | 2 | normal enumeration |
| `not attached`, recovered by itself | 1 | under 2 s |
| `not attached`, needed supervisor re-probe | 4 | 6–9 s |

After recovery, RNDIS, MTP and DHCP worked in all ten trials. The four delayed
trials are therefore enumeration delays, not four DHCP-server failures. They
remain user-visible failures for a host that gives up before the supervisor
finishes recovery.

This is a single-host, single-port, single-cable baseline. It does not yet
establish whether the failure is specific to the RG353PS, the host controller,
the cable, or an interaction between them. Repeat the matrix with a second
computer and a second known-good cable before changing the normal recovery
policy.

### One-shot soft-connect result

In one of the observed `not attached` failures, the armed one-shot test wrote
both `disconnect` and `connect` successfully to
`/sys/class/udc/fcc00000.usb/soft_connect`. Sixteen samples over the following
eight seconds still reported `state=not attached` and
`speed=UNKNOWN`. The port recovered only after the supervisor re-probed the
DWC3 platform driver.

The supported conclusion is narrow: toggling the gadget pullup did not recover
this failure instance. It is not proof that `soft_connect` can never help in
other states. Keep the one-shot command as a manual diagnostic; do not put it
into the automatic recovery path:

```sh
baseos-usb-debug soft-connect-test-arm      # next failed enumeration runs it once
baseos-usb-debug soft-connect-test-cancel
```

### Kernel recovery investigation

The RG353PS kernel build already carries board-specific Rockchip USB2PHY changes:
the fixed-peripheral path avoids state-machine power-off transitions so the PHY
can continue detecting VBUS; BVALID IRQ and extcon state are instrumented; and
the former two-second `B_IDLE` polling loop was removed in favour of IRQ-driven
operation. The OTG work rescheduler uses `mod_delayed_work()` so a pending timer
can be moved to the requested deadline.

A DWC3 platform-driver re-probe is broader than a gadget pullup toggle. It
re-enters the DWC3 remove/probe lifecycle, including generic PHY exit/init and
power sequencing. The current measurements therefore do not isolate whether
the recovery depends on a DWC3 core reset, Rockchip PHY lifecycle reinitialization,
or a fresh VBUS/IRQ/extcon state transition.

The next low-risk kernel change serializes BVALID-IRQ and charger-detection
state-machine requests through the same `otg_sm_work` delayed-work item rather
than invoking that work function inline from two different paths. It does not
force a PHY reset, change the VBUS polling policy, or alter the userspace
recovery ladder. It is a candidate for hardware validation, not a proven fix.

Interpret the next failure logs in this order:

1. Did the BVALID IRQ fire, and did its status bit indicate pending?
2. Did the Rockchip OTG state machine read `bvalid=1` and complete charger
   detection?
3. Did extcon publish `EXTCON_USB=1` successfully?
4. Did DWC3 keep the gadget pullup active and transition out of
   `not attached`?

If BVALID never fires, investigate PHY interrupt arming/status and consider a
bounded `B_IDLE` watchdog as a separate experiment; continuous polling has a
power cost and is not enabled by default. If BVALID and extcon succeed while
DWC3 remains unattached, focus on the DWC3/PHY connect sequence instead.

### Open directions

1. Keep the current supervisor re-probe as the known-working fallback while
   collecting the multi-host/multi-cable matrix.
2. Do not replace the first DWC3 driver re-probe with a ConfigFS gadget rebind
   until the latter has been independently shown to recover this failure.
3. If the IRQ/state-machine serialization change does not help, use the logs
   above to decide whether a bounded VBUS watchdog or a narrower PHY/DWC3
   reinitialization is justified. Measure idle power before enabling any
   periodic polling in a release build.

## Hardware validation checklist

The USB implementation has received partial hardware validation on RG353PS. Reconnect enumeration has been measured and documented above. MTP transfer integrity, filesystem operations, release-profile behaviour, and the remaining checklist items still require hardware validation.
Verify on RG353PS:

- Development profile: Windows 10/11 enumerate a network adapter and an MTP
  portable device from the same USB connection.
- SSH works at `192.168.42.1` while MTP is open.
- Large files transfer in both directions and compare byte-for-byte.
- Chinese names, spaces, deep paths, create, rename and delete work.
- Unexpected cable pull does not leave FunctionFS or UDC stuck.
- Reconnect without reboot; repeat at least 20 times.
- MTP-only release profile enumerates without a network adapter.
- Function + Power Mass Storage still enters/exits and passes existing safety tests.
- Compare boot marks before/after; frontend hand-off must not regress.
