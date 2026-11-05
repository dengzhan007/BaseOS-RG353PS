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

A replug does not always end in an enumerated port. Measured on commit
`ff88dd9` with a known-good cable, ten unplug/replug cycles on the same host
port and the same USB port gave ten working connects — RNDIS, MTP and DHCP all
succeeded every time — but four of the ten settled in `not attached` instead of
enumerating, and only recovered when the supervisor re-probed the UDC.

| After replug | Count | Recovery |
|---|---:|---|
| `configured` immediately | 3 | none |
| `addressed` then `configured` | 2 | none |
| `not attached`, recovered by itself | 1 | none, under 2 s |
| `not attached`, needed re-probe | 4 | 6–9 s |

The wait is the re-probe itself: unbinding and rebinding the DWC3 driver is
what makes the PHY re-run `rockchip_usb2phy_init()`, and only then does the host
see the device again. DHCP survives it because dnsmasq answers the retry and the
host keeps the same lease; a host that gives up earlier would show this as a
failed network connect rather than a slow one.

`soft_connect` does not help. An armed one-shot test wrote `disconnect` then
`connect` to `/sys/class/udc/fcc00000.usb/soft_connect` while the port sat in
`not attached` with the cable present. Both writes were accepted, and sixteen
samples over eight seconds all reported `state=not attached speed=UNKNOWN`. The
port came back only when the supervisor re-probed. Pullup alone is not enough;
the PHY has to be re-initialised.

The supervisor therefore keeps `soft_connect` out of its automatic path. The
one-shot test stays as a manual diagnostic:

```sh
baseos-usb-debug soft-connect-test-arm      # next failed enumeration runs it once
baseos-usb-debug soft-connect-test-cancel
```

Open directions, in increasing cost:

1. Leave it. Re-probe works; the cost is 6–9 s on roughly four replugs in ten.
2. Shorten the ladder. Attempt 1 and 2 both re-probe the driver; with
   `soft_connect` ruled out, the first attempt could go straight to the
   rebind that already works.
3. Fix the cause in the kernel. DWC3 should re-arm its pullup and drive the PHY
   through a fresh init when VBUS returns in peripheral mode. That is the real
   fix and needs its own round of hardware validation.

## Hardware validation checklist

This branch is an implementation candidate, not yet hardware-validated.
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
