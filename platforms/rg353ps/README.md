# RG353PS port — BaseOS 1.2.9

This directory contains the independent BaseOS target for the Anbernic RG353PS
(Rockchip RK3566). It does not replace or alter the existing Miyoo Flip
(`my355`) build path.

## Release status

**Version: 1.2.9 release candidate.** The RG353PS target has a complete image and A/B update build path:
U-Boot, Linux kernel and device tree, kernel modules, wireless firmware,
BusyBox-based root filesystem and GPT SD-card image. The release workflow
supports A/B update payloads for compatible versions. **1.2.8 remains
full-image-only** because it changed the persisted SSH setting name; 1.2.9
restores `.bosupd` updates from an installed 1.2.8 system.

The 1.2.6 full image and update package have both been tested on physical
RG353PS hardware. That remains the latest complete-image / in-place-update
hardware acceptance baseline. The 1.2.6 checks established that:
- A fresh SD-card flash boots successfully.
- An in-place system update completes successfully.
- The persistent user-data partition is kept separate from the A/B system
  frontends, so normal system updates do not replace ROMs, saves, frontend files,
  or user settings stored there.

Version 1.2.9 is based on the 1.2.8 release branch. It preserves Wi-Fi SFTP,
Wi-Fi interactive SSH, the generated default boot logo and the generic
frontend adapter contract. Its audio initialization gates the internal speaker
switch before any PCM open on each boot, creates/checks softvol, sets it to its
minimum gain while reconnecting the speaker route, waits 100 ms, then restores
the saved/default volume. The existing ALSA state restore path remains enabled.
The 1.2.9 audio-sequencing candidate still requires physical validation with
actual sound playback.

## Installation

### New installation

**For a fresh installation, use the complete 1.2.9 image.** A system already
running 1.2.8 can use the 1.2.9 `.bosupd` package. In-place upgrades from 1.2.7
or earlier remain unsupported because the 1.2.8 release changed the persisted
SSH setting name. Back up important files before any system update or reflash.

1. Download the complete `baseos-rg353ps-1.2.9.img.gz` image from the
   [GitHub Releases](https://github.com/dengzhan007/BaseOS-RG353PS/releases)
   page.
2. Write the image to the TF1 card with an SD-card imaging tool.
3. Insert the card into TF1 and boot the RG353PS.
4. On first boot, the user-data partition is expanded to the end of the card
   and initialized for user files.

**Writing the full image erases the target card. Back up its contents first.**

### Upgrade an existing BaseOS RG353PS installation

This procedure applies only to versions that publish a compatible update
payload. **Do not use it to install or migrate to 1.2.8.**

For a version with an available update payload:

1. Download the matching `.bosupd` package from that version's release.
2. Copy the update package to the root of either card's accessible volume,
   following the system's update procedure. This release's update payload is for
   systems already running 1.2.8; do not use it on 1.2.7 or earlier.
3. Restart the device and allow the updater to complete.

The `.bosupd` package updates the A/B system BOOT and ROOTFS regions. It does
not include the Rockchip U-Boot region and does not overwrite the persistent
`BASEOS` user-data partition. A U-Boot change therefore requires a full
card reflash rather than a normal `.bosupd` update.

The release provides a SHA-256 checksum file alongside the selected binary
artifacts. Verify downloaded files against it before installation.

## Platform layout and services

The SD card separates the bootloader, A/B system frontends and persistent user
data. The user-data partition is mounted at `/mnt/SDCARD`; the compatibility
path `/mnt/sdcard` follows the selected frontend root. Frontend discovery
checks TF2 first and then TF1, and starts the diagnostic UI if no supported
frontend is available. The diagnostic UI remains available for hardware and
input checks.

The platform includes:
- BaseOS startup and frontend supervision, with automatic frontend discovery.
- Persistent boot-logo selection and restoration across system updates.
- Audio, display, input, Wi-Fi and Bluetooth platform integration.
- USB device-mode networking/MTP for development and MTP for release builds.
- Exclusive USB Mass Storage mode, accessible from the diagnostic UI or by
  holding Function while powering on.
- A/B system updates that preserve the user-data partition.

For USB modes, host compatibility, reconnect behavior and test results, see
[USB architecture and validation](USB.md). For the boot-logo file format and
frontend integration contract, see [BOOTLOGO.md](BOOTLOGO.md). For frontend
discovery and adapter integration, see [FRONTENDS.md](FRONTENDS.md).

## Building

Run the platform build scripts from the repository root. The release workflow
is the recommended reproducible path and performs the required cross-builds,
static checks, image assembly, update packaging and checksum generation.

The individual build steps are:

```sh
./platforms/rg353ps/build-uboot.sh
./platforms/rg353ps/build-firmware.sh
./platforms/rg353ps/build-kernel.sh
./platforms/rg353ps/build-rootfs.sh
./platforms/rg353ps/build-image.sh
./platforms/rg353ps/build-update.sh
```

`build-update.sh` consumes the composed image, so the image is still built as
an intermediate input even when the workflow publishes only the update
package. See the workflow
[`.github/workflows/rg353ps-release.yml`](../../.github/workflows/rg353ps-release.yml)
for the independent `package_type` choices and release attachment behavior.

## Detailed documentation

- [USB architecture and reconnect validation](USB.md)
- [Boot-logo persistence and frontend contract](BOOTLOGO.md)
- [Frontend discovery and adapter contract](FRONTENDS.md)
- [BaseOS 1.2.7 release notes](../../docs/RG353PS-RELEASE-1.2.7.md)
- [Kernel sources, patches and configuration](kernel/UPSTREAM.md)
- [Release baseline and historical validation notes](../../docs/RG353PS-RELEASE-BASELINE-1.2.4.md)

---

## Boot logo

BaseOS draws /mnt/boot/bootlogo.bmp from the active BASEOS_BOOT
partition. This is an A/B-updated system frontend, not durable user storage:
.bosupd updates replace both BASEOS_BOOT and BASEOS_ROOT, while the
BASEOS user-data volume at /mnt/SDCARD is left untouched. A custom image
copied only to /mnt/boot is therefore replaced by a system update.

The platform now restores the selected image from persistent user data during
startup. The shared frontend contract is
/mnt/SDCARD/Bootlogos/<filename>.bmp plus the selected basename in
/mnt/SDCARD/System/bootlogo.txt. After user data is mounted, rcS copies
the selected source back to /mnt/boot/bootlogo.bmp, verifies the bytes, and
redraws it with fbsplash before the frontend starts. an external frontend currently uses
these names; other frontends should implement the same contract rather than
inventing a private BaseOS integration.

The RG353PS format is 640×480, 24-bit, uncompressed BMP. Frontends must reuse
the already-mounted BASEOS_BOOT volume, preserve the original image once at
/mnt/SDCARD/System/bootlogo-original.bmp, verify writes, and save the
selection record only after a successful install. The current restore path
reads TF1's /mnt/SDCARD; a frontend launched from TF2 must write the shared
state there explicitly rather than only to its /mnt/sdcard frontend root.

See the [RG353PS boot-logo persistence and frontend contract](BOOTLOGO.md)
for the complete partition model, file layout, startup sequence, update
lifecycle, BMP requirements and frontend implementation rules.

## USB: composite MTP and development SSH

The USB device port is managed below the frontend layer by one BaseOS Gadget.
Development images default to USB network + SSH + MTP for remote debugging and
transfer testing; release images default to MTP only. Mass Storage remains a
separate, exclusive mode using the existing Function + Power / diagnostic
controls. See [USB.md](USB.md) for the architecture, profiles, FunctionFS
startup order, storage boundary and hardware validation checklist.

## USB Mass Storage mode

Mass Storage is an exclusive USB mode. To enter it at power-on, connect the
device as needed, hold **Function** and press **Power**. The device enters its
storage screen and waits for the USB data cable/host connection. The diagnostic
UI also provides a Mass Storage entry.

Only the selected user-data volume is exported. While the host has the volume
as a raw USB disk, do not access or mount that same filesystem locally on the
device. Exit the mode or disconnect the host before returning to the frontend.

For the USB gadget hand-off, supported host profiles, reconnect recovery and
hardware test evidence, see [USB.md](USB.md).

## USB debug channel: a shell without pulling the card

The rootfs has no `adbd` — ADB needs the Android daemon, and its libraries do
not exist on Alpine. Instead the port can present itself as an RNDIS network
device with a dropbear listener, which gives the same practical result: a shell
on the unit over the cable.

Enabled by default in development builds; release builds default to MTP-only. When USB networking is enabled, the unit takes `192.168.42.1`, hands the
PC `192.168.42.100` over DHCP, and listens on port 22 for root, with either the
key in the image or the password `root`:

```sh
ssh -o StrictHostKeyChecking=no -i baseos-debug root@192.168.42.1
```

Windows 10/11 binds RNDIS without a driver package. If the adapter comes up
without an address, set `192.168.42.2/24` by hand and the same command works.

> **Windows: raise the RNDIS metric, or it can take over the default route.**
> When Windows assigns the RNDIS adapter a low metric (observed as 25 alongside
> Wi-Fi and Ethernet), it may send general internet traffic through the USB
> cable. This link is point-to-point and has no internet gateway, so some
> websites or network services fail while other connectivity still works.
> Set the Windows adapter's IPv4 interface metric to **9999** and disable
> Automatic metric. This makes the RNDIS default route less preferred while
> keeping the more-specific `192.168.42.0/24` route available for SSH:
>
> ```powershell
> Get-NetAdapter | Format-Table Name, InterfaceDescription, Status
> Set-NetIPInterface -InterfaceAlias "RNDIS" -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 9999
> Get-NetIPInterface -InterfaceAlias "RNDIS" -AddressFamily IPv4 | Format-Table InterfaceAlias, AutomaticMetric, InterfaceMetric
> ```
>
> Replace `RNDIS` with the adapter **Name** reported by `Get-NetAdapter` if
> Windows assigned a different alias. In the GUI, open adapter properties ->
> IPv4 -> Advanced, clear "Automatic metric", and set the interface metric to
> `9999`. Apply this to every RNDIS instance if Windows enumerated more than
> one.

### Plug the cable before powering on

A cable inserted after boot only enumerates some of the time. The controller is
already `dr_mode = "peripheral"` with the usual Rockchip quirks
(`dis_u2_susphy`, `dis_enblslpm`, `dis-u2-freeclk-exists`,
`dis-tx-ipgap-linecheck`, gadget LPM disabled), so the remaining failure is in
the PHY: on insertion `fe8a0000.usb2phy` runs BC1.2 charger detection, which
holds D+/D- for a few hundred milliseconds. dwc3 sees a device event with
`speed=0` during that window, drops to `DISCONNECT` 60 ms later, and the UDC
parks in `not attached`. With the cable already in place at boot, the PHY
finishes detection before the controller initialises, and enumeration runs from
the start.

`baseos-usb-debug` supervises this: a 2 s tick, and after 12 s parked in `not
attached` it rebinds the gadget, then rebuilds the whole stack (unbind dwc3 →
unbind the PHY → bind the PHY, then the controller → bind the gadget). Attempts
back off to one per minute and never give up; a plug event resets the ladder.
Unplugging for five seconds and plugging back in works better than waiting,
because it gives the PHY a real power cycle.

This is accepted as a usage convention rather than a pending fix. Closing it
properly means reworking charger detection or the PHY init order in
`phy-rockchip-inno-usb2`, which needs repeated bench validation on hardware.

The `ssh_debug` setting controls both interactive shell endpoints: USB
Dropbear at `192.168.42.1:22` and Wi-Fi Dropbear at the current `wlan0`
address on TCP `2222`. Wi-Fi SFTP is independent and remains on TCP `22`
when `wifi_sftp=yes`. The image ships `baseos.conf` at the root of
`BASEOS_BOOT`, but that partition is hidden from file browsers on purpose, so
first boot also writes a card-side copy to the root of the visible `BASEOS`
volume, next to `Games/`:

```
BASEOS/baseos.conf      # debug=no, ssh_debug=yes, frontend_id=auto
```

That copy is read before the image one and only overrides the keys it contains,
so editing it needs no rebuild and no update file. It is seeded once and never
rewritten; delete it and reboot to get the defaults back.

Root logs in with either the key or the password `root` (the hash is baked into
`/etc/shadow` by `build-rootfs.sh`). A key dropped at
`BASEOS/baseos-ssh/authorized_keys` replaces the one baked into the image and
keeps working alongside the password. Setting
`ssh_debug=no` disables both interactive SSH listeners. When `usb_mtp=yes`,
the USB gadget remains MTP-only; it can still enter exclusive Mass Storage with
Function + Power:
`baseos-usb-storage` releases this gadget first and restarts it from its cleanup
trap, so the two modes never fight over the controller.

The image also carries a fixed dropbear host key at
`platforms/rg353ps/rootfs/etc/dropbear/dropbear_ed25519_host_key` (mode 0600, set
by the build, marked `-text` in `.gitattributes`). Never delete it: without one
dropbear generates a fresh key on first boot, every reflash changes the host
fingerprint, and clients then abort with `REMOTE HOST IDENTIFICATION HAS
CHANGED`. Because it is committed, anyone with the repository can impersonate
this debug port — acceptable for a private bring-up board, not for a shipped
device. To rotate it, run `dropbearkey -t ed25519 -f <file>` on the device and
commit the result.

With a shell available, the diagnostics that used to need a rebuild are one
line away: `baseos-audio-check`, `baseos-usb-debug status`, `dmesg`, `amixer`.


## Graphics userspace and first render test

The physical RG353PS graphics audit identified a working Rockchip DRM display
controller and a loaded Panfrost Mali-G52 kernel driver, but the earlier image
did not contain EGL/GLES/GBM userspace libraries or tools. The rootfs build now
installs Mesa EGL/GLES/GBM, the Panfrost DRI driver, SDL2 runtime, `eglinfo`,
`modetest`, and `kmscube`. This is a first graphics-stack test environment,
not yet proof of hardware-accelerated rendering or frontend compatibility.

On the device, run:

```sh
/usr/sbin/rg353ps-graphics-stack-test
```

The test writes `/mnt/boot/rg353ps-graphics-stack-test.txt` (or
`/tmp/rg353ps-graphics-stack-test.txt` if the boot partition is not writable).
It enumerates DRM connectors, captures EGL information, and runs `kmscube` on
`/dev/dri/card0` for a maximum of 12 seconds. The built-in display should show
a spinning cube. Exit code 124 from the timed cube command is expected if the
process ran until the timeout; an earlier EGL/DRM error is a failure to
investigate. Run it from the serial shell when no other application owns the
DRM display; it temporarily modesets the built-in screen.

The script also runs a small SDL2 test program through `SDL_VIDEODRIVER=kmsdrm`.
If successful, the internal screen should display red, green, blue and dark
screens for about eight seconds. It prints the actual SDL video backend,
display mode, GLES renderer and version, then exits cleanly. This is the
next milestone for frontend compatibility; it still does not prove frontend or
frontend itself can run.

For the earlier KMS cube test, BusyBox `timeout` may report exit code 143
after stopping `kmscube` with SIGTERM (rather than the more common 124).
Either can be expected if the cube stayed on screen for the timed interval and
there were no earlier DRM/EGL errors. EGL warnings for unavailable Wayland/X11
are not, by themselves, evidence that the headless GBM/KMS path failed.

The October 2026 report also showed the device clock about 10 days ahead of the
current date; check `date -u` and fix time synchronization before diagnosing
TLS/download errors.

## Build the U-Boot milestone

Host prerequisites: Docker, Git, curl, and the host's usual shell utilities.
From the repository root:

```sh
./platforms/rg353ps/build-uboot.sh
```

The script pins U-Boot v2026.01 by SHA-256 and checks out a fixed Rockchip
`rkbin` revision for the DDR and BL31 binaries. It uses
`anbernic-rgxx3-rk3566_defconfig`, following the RK3566 Generic package in
[ROCKNIX](https://github.com/ROCKNIX/distribution/tree/next/projects/ROCKNIX/devices/RK3566/packages/u-boot-Generic).
The panel-power sequencing patch is based on ROCKNIX's
`0003-board-rockchip-Fix-panel-detection-logic-for-mainlin.patch`.

The generated combined bootloader follows ROCKNIX's layout helper:
`idbloader.img` at LBA 0 and `u-boot.itb` at LBA 16320 (512-byte sectors).
The script also saves the FIT and checksum/metadata alongside the combined
bootloader under `work/rg353ps/`.

Those two LBAs are **offsets inside `rg353ps-uboot.bin`**, not absolute card
sectors. `build-image.sh` writes that file at absolute LBA 64, so on the card
the idbloader lands at LBA 64 and the FIT at LBA 16384 — the start of the
`BASEOS_UBOOT` partition. The file is 9,991,680 bytes (16320 sectors of
idbloader region, then the FIT). It is **not** the 8 MiB `BASEOS_UBOOT`
partition image: that one begins with the FIT (`d0 0d fe ed`) and has no
idbloader, so writing it at LBA 64 produces a card that does not boot. Check
the first four bytes: `RKNS` is correct, `d00dfeed` means the wrong file.

### The SD clock patch is not optional

`patches/0008-clk-rk3568-sdmmc-internal-divider.patch` must stay in the
platform patch set. Without it the RK3568 dw_mmc still halves its input clock
(the driver maps the request straight onto the CRU, where px30/rk3308/rk3328/
rk3399 double it), so a 50 MHz request runs the card at 25 MHz: the kernel read
drops from ~24.6 MB/s to ~11.2 MB/s and `before Linux` goes 2.55 s → 3.55 s,
about 1.0 s of boot. `mmc info` reports 50 MHz either way, so the regression is
invisible there.

`.bosupd` never carries U-Boot — it only writes the boot and rootfs partitions
— so a U-Boot change has to be flashed separately, and it cannot be rolled back
over SSH.

### Reading the pre-kernel split

`CONFIG_BOOTSTAGE_FDT` (patch `0009`) records each stage in the tree U-Boot
hands to the kernel. After a boot, on the device:

```sh
for r in /proc/device-tree/bootstage/record@*; do
    n=$(tr -d '\000' < "$r/name")
    t=$(od -An -tx1 "$r/mark" | tr -d ' \n')
    printf '%-26s %d ms\n' "$n" "$(( 0x$t / 1000 ))"
done
```

`mark` is the arch counter in microseconds, so it is power-on-relative, the
same clock the kernel's printk uses. `start_kernel` should land near the
`before Linux` figure in `/mnt/SDCARD/Logs/boot.log`; the gaps between the
records are what the unmeasured residual in the boot budget is made of.

## Build the RG353PS BaseOS SD image

The scripts are deliberately separated from the Miyoo Flip build. From the
repository root, run:

```sh
./platforms/rg353ps/build-uboot.sh
./platforms/rg353ps/build-kernel.sh
./platforms/rg353ps/build-firmware.sh
./platforms/rg353ps/build-rootfs.sh
./platforms/rg353ps/build-image.sh
```

The build uses U-Boot v2026.01 / Anbernic RGxx3 defconfig, Linux 7.2.7 with the
ROCKNIX RK3566 configuration and hardware patches, and the matching RG353PS
Linux DTB. The RTL8821CS mainline Wi-Fi/Bluetooth firmware is collected
separately. Because built-in cfg80211 requests its signed regulatory database
early in boot, regulatory.db and its signature are also embedded in the kernel;
the current wireless-regdb signing certificate is included as an additional
trusted key. Kernel config/patch and certificate provenance is in
[kernel/UPSTREAM.md](kernel/UPSTREAM.md).

The result is `work/rg353ps/baseos-rg353ps.img.gz`, a complete 2 GiB RG353PS
**BaseOS system image**. It uses a 256 MiB FAT `BASEOS_BOOT` partition, a
bounded 1280 MiB ext4 `BASEOS_ROOT` partition, and a blank `BASEOS` partition.
The first-boot initializer expands the user partition to the actual TF-card end
and formats it as exFAT, then mounts it at `/mnt/SDCARD`. This allows the same
card to hold user-installed frontend packages, ROMs and saves.

The image boots the BaseOS userspace with system services, read-only A/B system
frontends, frontend discovery and an evdev-driven diagnostic UI as a fallback when
no supported frontend is found. The game frontend is installed separately on
a user-data TF card; it is not bundled into the BaseOS image. CI verifies the
image layout and update payload, while hardware support status is documented
separately in this guide and must not be inferred from a successful build.

After boot, run `/usr/sbin/rg353ps-v4l2-report` to capture driver status,
V4L2 capabilities, and advertised capture/output formats to
`/tmp/rg353ps-v4l2-report.txt` while also printing them to the console.
You can also inspect the nodes directly:

```sh
v4l2-ctl --list-devices
v4l2-ctl -d /dev/video0 --all
v4l2-ctl -d /dev/video0 --list-formats-ext
v4l2-ctl -d /dev/video0 --list-formats-out-ext
v4l2-ctl -d /dev/video1 --all
v4l2-ctl -d /dev/video1 --list-formats-ext
v4l2-ctl -d /dev/video1 --list-formats-out-ext
```

The V4L2 API compliance and one-frame hardware JPEG encode tests have passed.
The encode helper is `/usr/sbin/rg353ps-jpeg-encode-test`; it feeds one 96x32
YM12 frame to `/dev/video1`, captures the JPEG output, and checks the start/end
markers. A pass confirms a plausible bitstream was produced, but does not
replace decoding/viewing the image or longer-duration testing.

To inspect suspend and wakeup support without changing power state, create an empty file named `BASEOS-SUSPEND-AUDIT` in the FAT `BASEOS_BOOT` partition from a PC, then boot the device once. `rcS` consumes this one-shot request and writes a timestamped report named `rg353ps-suspend-audit-*.txt` to `BASEOS_BOOT`. You can also run `/usr/sbin/rg353ps-suspend-audit` manually from a shell. The audit is read-only and does not attempt suspend. It records `/sys/power/state`, `mem_sleep`, per-device wakeup attributes, input/power-key devices, CPU idle states, battery/RTC data, and relevant kernel messages.

**Runtime deep suspend is supported.** Use `/usr/sbin/rg353ps-sleep` for the product suspend path. On Slot cards it stops the frontend-owned Wi-Fi session through `System/slotnet.sh`, unbinds the Realtek SDIO Wi-Fi function so the MMC core can cut the Wi-Fi rail, selects `deep`, turns off the backlight and requests `mem`. A short press of the physical Power button wakes the device; after rebinding the radio, the helper asks the frontend script to reconnect using the card's `System/wifi.conf`. Other older frontends without that script use the legacy `rg353ps-wifi-connect` fallback. If the deep request fails after Wi-Fi was unbound, the helper attempts `s2idle` as a fallback. RTC self-wakeup is not supported, so the device must be woken by the Power button. This is suspend-to-RAM, not hibernation or poweroff.

For normal Wi-Fi use, BaseOS initializes the RTL8821CS radio and exposes `wlan0`; the frontend owns scanning, credentials, `wpa_supplicant` and DHCP through its card-side network helper. This matches upstream BaseOS/Slot separation. See [FRONTENDS.md](FRONTENDS.md) for the Slot contract.

BaseOS exports `BASEOS_SLEEP=/usr/sbin/rg353ps-sleep` to the selected frontend. Frontends that own the power key should invoke this helper for a user-requested suspend rather than using an idle timeout that later calls `poweroff`. The Slot RG353PS adapter uses this contract. See [POWER.md](POWER.md) for the sequence, frontend requirements and diagnostics.

The one-shot `BASEOS-SUSPEND-TEST-S2IDLE` helper remains available for diagnostic comparison. Save game progress and shut down the device. On a PC, create an empty file named `BASEOS-SUSPEND-TEST-S2IDLE` at the root of the FAT `BASEOS_BOOT` partition; safely eject the card, reinstall it, and boot normally. Keep USB data cables disconnected and do not enter USB storage mode. The frontend supervisor consumes this request only after the selected frontend has launched. It waits eight seconds, stores a pre-test report, selects `s2idle`, and requests the kernel `mem` state. When the backlight turns off, briefly press the physical Power button to wake the device. After resume, the helper restores the previous backlight brightness and `mem_sleep` selection, then writes `rg353ps-suspend-test-s2idle-*.txt` to `BASEOS_BOOT`. This test is not the product deep-suspend path. Do not run either test while USB storage mode is active or while files are transferring. A long Power-button hold may force a PMIC hard poweroff and discard unsaved progress; use it only as a last resort.

For the next hardware pass, run `/usr/sbin/rg353ps-hardware-audit`. It creates
a read-only inventory of display/backlight, input devices, audio, battery and
thermal sensors, storage, network, Bluetooth/USB, V4L2 formats/compliance, and
relevant kernel messages. It writes its report under `/mnt/boot` when writable,
otherwise under `/tmp`. It does not deliberately press buttons, play audio,
toggle radios, change power state or reboot.

The diagnostic image includes `evtest`, `alsa-utils` and `iw`. The interactive control UI is compiled as a static ARM64 executable during the rootfs build.
After reviewing the inventory, test controls interactively with
`evtest /dev/input/eventX` (replace `eventX` with the device name from the
report and press each physical button), inspect audio with `aplay -l` and
`amixer scontrols`, and check wireless interfaces with `iw dev`. Do not start
wireless associations or change mixer values as part of the passive inventory.

## Porting safety constraints

- Keep this target isolated from `build-all.sh` and `work/my355`; the existing
  Miyoo Flip target must continue to build unchanged.
- Never use the Miyoo preloader installer, `mtd5` patch, `miyoo355_fw.img`,
  Android boot image, stock harvest or `my355`-specific U-Boot commands on the RG353PS.
- Keep U-Boot's control DTB separate from the Linux DTB
  `rk3566-anbernic-rg353ps.dtb`.
- The image builder only writes a disk-image file. When testing, write the
  compressed image to a spare TF card and keep the original system card intact.
