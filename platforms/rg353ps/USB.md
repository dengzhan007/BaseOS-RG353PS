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

## Windows host routing when USB RNDIS/SSH is enabled

This is a **Windows host-side route-priority issue**, not a change to the
RG353PS `usb0` route. When the development profile enables the RNDIS network
function for SSH, Windows may install a low-metric default route through the
USB adapter. Because the USB link is point-to-point and has no internet
gateway, Windows can send some general traffic into that link instead of
Wi-Fi or Ethernet. The visible symptom can be partial network failure: some
websites or services stop working while other connections continue normally.

Set the RNDIS adapter's **IPv4 interface metric to 9999** and disable Windows'
Automatic metric. This lowers the USB adapter's default-route priority; the
more-specific `192.168.42.0/24` route remains available for SSH to
`192.168.42.1`.

In an elevated PowerShell window:

```powershell
Get-NetAdapter | Format-Table Name, InterfaceDescription, Status
Set-NetIPInterface -InterfaceAlias "RNDIS" -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 9999
Get-NetIPInterface -InterfaceAlias "RNDIS" -AddressFamily IPv4 | Format-Table InterfaceAlias, AutomaticMetric, InterfaceMetric
```

Replace `RNDIS` with the adapter **Name** shown by `Get-NetAdapter` if
Windows assigned a different alias. The same setting is available in the
adapter properties -> IPv4 -> Advanced dialog: clear "Automatic metric" and
enter `9999`. Apply it to each RNDIS instance if more than one is present.

This setting is made on the **Windows PC**, not on BaseOS. It does not disable
USB networking, Dropbear or the SSH channel; it prevents the USB debug link
from outranking the PC's normal internet connection.

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
`platforms/rg353ps/rootfs/etc/baseos.conf` contains `usb_diagnostics=no`.
The editable card-side file `/mnt/SDCARD/baseos.conf` is created by
`baseos-init-userdata` only when the file does not already exist, and is never
overwritten on later boots or system updates. The first-boot template now also
writes `usb_diagnostics=no` explicitly. Earlier images had this setting in the
system copy but omitted it from the generated card-side template, so even a
freshly flashed card could have a `baseos.conf` without the line. Existing
files are intentionally not rewritten; a missing key still falls back to the
built-in `no` default and does not enable persistent diagnostics.

For existing installations, you can add this line to
`/mnt/SDCARD/baseos.conf` to make the setting visible and explicit:

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

### MTP and Mass Storage real-hardware acceptance (2026-11-06/07)

The reconnect enumeration matrix above is a separate test. The following
results cover the MTP and Mass Storage data paths; they must not be conflated
with enumeration recovery or with one another.

#### MTP

| Test | Result | Evidence / boundary |
|---|---|---|
| MTP-only Release enumeration | **PASS** | Real RG353PS; VID_2207&PID_0009 only, no PID_0007/0008 or device RNDIS/NCM; 14/14 host checks |
| Device -> host transfer integrity | **PASS** | 7/7 files: actual sizes and SHA-256 match, including 128 MiB, Chinese/spaced names and nested paths |
| Host -> device transfer | **PASS, with boundary** | PR #5 Windows WPD test uploaded the dataset; hashes were then computed on-device over SSH and matched. This is not an MTP read-back verification |
| WPD overwrite / file rename / directory rename / file delete / directory delete | **SKIP** | Five operations were deliberately not attempted because Windows Shell/WPD presents modal confirmation prompts; no PASS is claimed |
| Linux GVFS backend on real hardware | **NOT TESTED** | No hardware result is recorded |
| MTP long-duration / repeated-unplug stress | **NOT TESTED** | The 30-minute stability report below is Mass Storage, not MTP |

The PR #5 integrity-tool report records Windows WPD fast and full datasets at
25 PASS / 0 FAIL / 5 SKIP each. The five SKIPs are the five mutating WPD
operations listed above. Local unit tests and the simulated local backend are
not MTP hardware evidence.

Authoritative MTP-only acceptance records:
- [Real-hardware upgrade and acceptance](../../docs/mtp-only-release-fixed-20261106/REAL-HARDWARE-ACCEPTANCE-20261106.md)
- [Normalized MTP-only acceptance](../../docs/mtp-only-release-fixed-20261106/hardware-acceptance/mtp-only-acceptance.md)
- [MTP-only host report](../../docs/mtp-only-release-fixed-20261106/hardware-acceptance/mtp-only-host-report.md)
- [PR #5 integrity-tool evidence and limitations](https://github.com/dengzhan007/BaseOS-RG353PS/pull/5)

#### Mass Storage

| Test | Result | Evidence / boundary |
|---|---|---|
| Mass Storage host identification and read-only data checks | **PASS** | 20/20 checks; unique PID_0006; strict PnP -> disk -> IOCTL volume ownership; 7/7 sizes and SHA-256 |
| Exit recovery: Mass Storage -> MTP | **PASS** | PID_0009 returned; PID_0006/0007/0008 absent; live WPD RG353PS present; no device network adapter |
| 30-minute stability | **PASS** | 166/166 polls over 1803 s, zero anomalies; seven 128 MiB SHA-256 checks matched |
| Write integrity | **PASS** | Prepare 10/10; after safe eject, cable removal and re-entry, Verify 10/10; 7/7 sizes and SHA-256 matched |
| MTP <-> Mass Storage mutual exclusion under load | **NOT TESTED** | The exit-recovery test proves restoration after leaving Mass Storage, not concurrent/under-load mutual-exclusion stress |

Authoritative Mass Storage records:
- [Host identification and integrity report](../../docs/mtp-only-release-fixed-20261106/mass-storage/mass-storage-host-report.md)
- [Exit recovery report](../../docs/mtp-only-release-fixed-20261106/mass-storage/exit-recovery-host-report.md)
- [30-minute stability report](../../docs/mtp-only-release-fixed-20261106/mass-storage/mass-storage-stability-report.md)
- [Write Prepare report](../../docs/mtp-only-release-fixed-20261106/mass-storage/mass-storage-write-prepare-report.md)
- [Write Verify report](../../docs/mtp-only-release-fixed-20261106/mass-storage/mass-storage-write-verify-report.md)

#### Remaining USB acceptance items

1. Exercise the five WPD mutating operations through a backend that can do so
   without modal UI, or record an explicit decision that this is unsupported.
2. Run the MTP integrity suite through Linux GVFS on real hardware.
3. Stress MTP <-> Mass Storage mutual exclusion under load, including entry,
   exit, cable removal and return to the configured USB profile.
4. Run a separate MTP long-duration / repeated-unplug stability test.

The existing Mass Storage stability and write-integrity PASS results do not
close these four items. Likewise, the 39-cycle reconnect matrix establishes
enumeration recovery, not full USB feature certification.


### Reconnect-triggered WPD recheck (2026-11-09)

A follow-up test was performed after the Windows host initially enumerated the
RG353PS WPD device but exposed zero storage items. Reconnecting the USB cable
restored the storage list. The repeated test distinguishes the unplug event
from an unsolicited responder failure:

- The second `incoming_packet : Read Error (-1)!` occurred in the same
  timestamp second as the USB debug log's `cable removed (state=not attached)`.
  The next `cable inserted` event followed two seconds later. This associates
  the read error with physical disconnect while a transfer/session was active;
  it is not evidence of a spontaneous uMTP failure.
- After re-enumeration, Windows WPD exposed the RG353PS storage again and the
  storage root listed **27 items** (the earlier failed enumeration had zero).
- uMTP remained alive, FunctionFS remained mounted, and no new device-side
  mode-lock, active-request, paused-state or teardown-failure marker appeared.
  No DWC3, PHY, Gadget, uMTP, DHCP or RNDIS runtime change was made.

A bounded **64 KiB bidirectional transfer check** then passed using a unique
`.baseos-audit-<UTC>-<random>` directory. The directory was confirmed absent
before creation; the procedure refused same-name overwrite and used a
`finally` cleanup path:

| Direction | Procedure | Result |
|---|---|---|
| Device -> host | Device-generated 64 KiB random file, downloaded with WPD/MTP `get`; source and destination SHA-256 matched (`3bd883a1…b16e6c`) | **PASS** |
| Host -> device | Host-generated 64 KiB file uploaded with WPD/MTP `put`; source hash matched the device-side SSH `sha256sum` (`5b01cfc2…0b8f3`) | **PASS, with boundary** |

The host-to-device case is **not** an MTP read-back test: Windows WPD may show a
modal prompt when opening a just-uploaded object, so the destination hash was
computed on the device over SSH. Cleanup validated the run marker, removed the
three temporary test files and the empty unique directory, and reported
`audit_dirs_left=NONE`. No ROM, save, or other user directory was touched.

This closes the reconnect-related MTP browse/read error and this bounded
64 KiB bidirectional integrity check. It does **not** replace the separate
7-file / 128 MiB hardware acceptance, nor does it establish MTP long-duration
stability, MTP-only session stability, WPD rename/delete support, or MTP and
Mass Storage mutual-exclusion stress; those remain separate tests.
