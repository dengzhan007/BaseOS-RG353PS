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


## Slot frontend (experimental)

The RG353PS Slot device adapter uses SDL2 KMSDRM + GLES on Mesa/Panfrost and
ALSA direct output. This is a device-specific port of the Slot-6 fork; it is
not an upstream-supported RG353PS target.

**Ownership and documentation:** Slot source, RG353PS packaging workflow,
Dockerfile and build script are maintained in
[dengzhan007/slot-6](https://github.com/dengzhan007/slot-6). The maintained
porting guide is [slot-6/PORTING.md](https://github.com/dengzhan007/slot-6/blob/main/PORTING.md);
the fork-specific implementation and real-device checklist are in
[PORTING-RG353PS-SLOT640.md](https://github.com/dengzhan007/slot-6/blob/main/PORTING-RG353PS-SLOT640.md);
build details are in
[packaging/rg353ps/README.md](https://github.com/dengzhan007/slot-6/blob/main/packaging/rg353ps/README.md).
This BaseOS repository supplies only the device runtime adapter:
`fbdev.rs`, `launch.sh`, RG353PS input/power patches, sleep helper and system
integration. It no longer stores a duplicate Slot porting guide or builds Slot.

### Build and package

Run the **Slot-6 RG353PS package** workflow from the Slot-6 repository. The
workflow checks out Slot-6 source and the selected BaseOS device-adapter ref,
then produces a frontend install ZIP and SHA-256 file. It does not build a
BaseOS system image.

Routine builds default to `build_cores=false`: they compile the Slot frontend
but do not fetch or rebuild the unchanged mGBA/gpSP cores. The ZIP is a
frontend-only overlay; it does not include core `.so` files and does not delete
existing `System/mgba_libretro.so` or `System/gpsp_libretro.so` when extracted
over an existing installation. Set `build_cores=true` only when core revisions
or build recipes intentionally change. Cargo registry/toolchain/target caches
are maintained by the Slot-6 workflow.

### Current device scope

- The frontend starts through SDL2 KMSDRM + GLES and uses ALSA direct output.
- Ordinary physical buttons other than the analog sticks have been reported
  working; audio and Wi-Fi have also been reported working.
- RG353PS key mapping and left-stick digital menu navigation are applied by
  `slot-rg353ps.patch`; `slot-power.patch` returns `KEY_POWER` to Slot.
- Slot's power menu uses a roughly one-second hold; A confirms poweroff/restart
  and B cancels. A short press while music is actually playing blanks the panel
  but keeps playback alive; otherwise Slot calls
  `/usr/sbin/rg353ps-sleep` for system suspend.
- Boot-logo selection is in Slot-6 source. Candidate BMPs go in
  `Bootlogos/*.bmp`; Slot writes the selected 640×480, 24-bit, uncompressed
  BMP to `/mnt/boot/bootlogo.bmp` on the already-mounted `BASEOS_BOOT`
  partition. The original image is backed up once to
  `System/bootlogo-original.bmp`. Actual partition writeback and next-boot
  display still require RG353PS hardware verification.
- Game-level `RETRO_DEVICE_ANALOG` passthrough for left/right sticks and L3/R3
  are not included in the current package.

### Installation

To install Slot on TF2, extract the ZIP contents directly into the root of the
TF2 card (not into a containing folder, and not onto `BASEOS_BOOT`). To install
it on TF1 instead, extract the same contents into the root of the `BASEOS`
partition. No `baseos.conf` edits are required: BaseOS automatically chooses a
usable frontend on TF2 first, then falls back to TF1 user data.

Keep the original system card and saves backed up while testing. Adapter
scripts run with root privileges, so only use packages you trust. exFAT/Windows
extraction may not preserve Unix executable permissions; the Slot launcher
copies `System/slot` to writable `/tmp` before executing it.

The current port remains experimental. Successful compilation or menu launch
does not establish correctness of all inputs, sleep/wake, Bootlogo writeback,
emulator launch, saves or long-duration behavior. NextUI remains a separate
porting target and requires its own runtime adaptation.
