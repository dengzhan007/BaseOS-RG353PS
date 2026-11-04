# RG353PS frontends

Normal boot does not require editing `baseos.conf` to select a frontend. BaseOS probes the second TF card (TF2) first, normally `/dev/mmcblk2p1`, and mounts it at `/mnt/TF2`. It scans the card root for a usable adapter at `.baseos/frontends/<name>/launch.sh`; if one is present, TF2 wins.

If TF2 is absent, cannot be mounted, or has no usable frontend adapter, BaseOS scans the first/system TF card's `BASEOS` user partition at `/mnt/SDCARD`. If neither card provides a usable frontend, the built-in diagnostic UI starts. The compatibility path `/mnt/sdcard` follows whichever card supplied the selected frontend.

Install frontend ZIP contents at the root of the card you want to use. TF2 has priority whenever it contains a usable frontend, so a frontend installed on TF1 will only be selected when TF2 is absent or has no usable adapter. Do not place frontend payloads on `BASEOS_BOOT`; that small FAT partition is for boot files and maintenance.

Automatic discovery recognizes `nextui`, `slot`, and `custom` adapters in the order listed by `frontends_order` (default: `nextui,slot,custom`). The old `frontend=...` and `allow_external_frontend_adapters=...` settings are ignored by the automatic selector; no manual opt-in is needed. Adapter scripts are executed with root privileges, so only use frontend packages you trust.

The intended system-card layout is `BASEOS_BOOT` (FAT boot files), `BASEOS_ROOT` (fixed-size Linux system partition), and `BASEOS` (exFAT user space). The first-boot initializer expands a blank `BASEOS` partition to the end of the physical card, formats it as exFAT and mounts it at `/mnt/SDCARD`. On cards larger than the 2 GiB image, the user partition is extended to use the rest of the card. If no free space exists, the initializer logs a warning rather than shrinking the root partition. Before tty1 starts either a frontend or the diagnostic UI, BaseOS waits until this user area is mounted and the persistent initialization marker is written. If initialization fails, a full-screen recovery prompt blocks normal UI startup and lets the user retry. After the first successful initialization, a full-screen confirmation asks for A/Enter once before automatic frontend discovery continues; the acknowledgement is persisted on `BASEOS_BOOT`. Storage failures are written to `BASEOS_BOOT/baseos-userdata-init.txt`, and frontend selection results to `BASEOS_BOOT/baseos-frontend-detection.txt`; both can be inspected from a PC without a serial console.

The adapter environment includes `PLATFORM=rg353ps` and `BASEOS_BOOT=/mnt/boot`. `BASEOS_FRONTEND_ROOT` points to the selected card root (`/mnt/TF2` or `/mnt/SDCARD`); `BASEOS_DATA_DIR` and `BASEOS_USERDATA_DIR` are created under that selected root.

**Important:** images built before the three-partition layout have no dedicated
user-data partition. Back up the card and flash a new image before expecting
same-card frontend installation. The boot partition remains a small maintenance
partition and is still visible to a PC; the Linux root partition is separate
from user files. A read-only root and A/B updater remain future work.

The RG353PS global hotkey service is independent of the UI process. It moves the
`BaseOS Master` softvol control on whichever card sysfs reports as `rk817` (not
a hard-coded index) for volume +/-, and turns a 2-second power-key hold into a
clean shutdown. The diagnostic UI only displays those input events.

Volume ownership follows the UI, not the daemon. A frontend draws the bar in its
own style, so its bar has to be the thing the keys move: while such a frontend
runs, `baseos-frontend-session` pins `BaseOS Master` at a fixed level
(`FRONTEND_MIXER_LEVEL`, 90/99) and writes the frontend pid to
`/run/baseos-volume-frontend`. `rg353ps-hotkeyd` reads that marker and leaves the
mixer alone, so one press changes exactly one control and the on-screen
percentage is the loudness. The previous mixer level is kept in
`/run/baseos-volume-mixer-saved` and restored when the frontend exits, so the
diagnostic UI and a plain shell still have a working volume. Frontends that do
not handle volume themselves (nextui, custom adapters) keep the daemon in
charge; `volume_owner=system` in `baseos.conf` forces that for Slot as well.

The codec gain itself is never used as the user volume: RK817 maps its 0..255
register linearly onto -95.5 dB..0 dB, so ALSA's percent of that register is
unusable as a volume scale (50% is -47 dB). `baseos-audio-init` pins the hardware
at 0 dB and exposes `pcm.!default` as `plug -> baseos_vol (softvol) -> baseos_hw`,
giving every frontend one predictable 0..100 = -48 dB..0 dB curve. The layer is
re-asserted after resume and before a frontend launches, so a codec re-probe
cannot silently change the level.


## First frontend target: Slot-6 (experimental)

The first Slot target is now the private `dengzhan007/slot-6` fork, pinned at
`acc4e91708cc21abf2321a3af279aae1b2f26d47`. Its Cargo workspace is nested
under `slot-main-640/`; the build script accounts for that layout and builds
the device binary in an AArch64 Alpine/musl container. The original H700 Mali
fbdev EGL window is replaced by this port's SDL2 KMSDRM + Mesa/Panfrost
surface. The BaseOS GPU stack is not changed.

The current milestone is intentionally frontend-only:

- RG353PS physical face buttons, shoulders, triggers, Select/Start, Function,
  D-pad and volume keys are mapped from the RG353PS input codes. KEY_POWER is
  deliberately not consumed by Slot; `rg353ps-hotkeyd` retains suspend and
  shutdown ownership.
- Boot-logo validation is changed to **640x480, 24-bit, uncompressed BMP**.
  The boot resource remains TF1's `BASEOS_BOOT` partition
  (`/dev/mmcblk0p2`, mounted at `/mnt/boot`).
- Audio tries only `plug:default` and `default`, preserving the RK817
  `plug -> softvol -> codec` path. It no longer falls back to card-number-
  specific `plughw` or `hw` devices that can bypass BaseOS volume control.
- Wi-Fi, Bluetooth, firmware loading, and system network services remain
  BaseOS-owned. This port does not add H700 radio scripts or alter the
  platform's radio configuration.
- Emulator cores, BIOS files, stick/analog support, sleep/doze integration,
  and the external deploy art/overlay pack are not part of this first bundle.

Build on a host with Docker and a local authenticated checkout of the private
Slot-6 repository:

```sh
SLOT_SRC=/path/to/slot-6 ./platforms/rg353ps/build-slot.sh
```

The local checkout must contain the pinned commit above. The script writes
`work/rg353ps/frontends/baseos-rg353ps-slot.zip` and its SHA-256 file. It does
not inject Slot into the OS image or alter the Miyoo Flip build. The package
contains the Slot executable, adapter, source archive and main-program
license; it intentionally does not claim to be a playable emulator bundle.

Install the ZIP contents directly at the root of TF2 for priority use, or at
the root of TF1's `BASEOS` user partition for fallback use. Do not put the
package on `BASEOS_BOOT`. The frontend adapter stages the executable to
`/tmp` before launch because exFAT does not preserve POSIX executable bits.
BaseOS continues to own the power key and its Wi-Fi/Bluetooth services; the
frontend session continues to manage the RK817 softvol handoff.

This is a source/build adaptation, not yet a successful build or a hardware
validation. The first device test should establish that the UI opens, the
listed physical keys navigate correctly, audio is audible and volume changes
work, and Wi-Fi/Bluetooth remain available. Only after that baseline should
we add game cores, stick support, power/doze integration or optional assets.
Keep the original system card and saves backed up while testing.

NextUI remains a separate porting target; its H700 launcher currently assumes
an H700-specific `mali` SDL backend and stock-OS services, so it needs its own
adapter/runtime work rather than reusing the H700 zip as-is.
