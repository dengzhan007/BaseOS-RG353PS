# RG353PS frontend adapter contract

BaseOS is a device system layer, not a frontend-specific distribution. It owns
boot, hardware services, storage mounting, power management, USB modes, system
updates, frontend discovery and process supervision. A game frontend owns its
UI, game-library discovery, ROM identification, emulator selection and game
launching.

## Installation and discovery

For new installations, use the managed package layout under
`Frontends/<package-id>/` described below. Extract the archive with its one
top-level directory intact; do not place frontend files on the small
`BASEOS_BOOT` partition.

Legacy adapters remain supported at their historical paths. At boot, BaseOS
checks TF2 first and then TF1. Legacy discovery continues to check the card
root and one wrapper-directory level; managed packages are discovered directly
under each card's `Frontends/` directory.

A generic adapter is discovered at either path:

```text
<card>/
└── .baseos/
    └── frontends/
        └── <adapter-id>/
            ├── manifest.conf
            └── launch.sh
```

A visible alias is also accepted for extraction tools that omit dot-prefixed
directories:

```text
<card>/baseos/frontends/<adapter-id>/
```

The adapter ID is an identifier, not a product name. Use 1–48 ASCII letters,
digits, dots, underscores or hyphens; it must not start with a dot, hyphen or
underscore. BaseOS does not maintain a list of supported frontend names.

Every new adapter should include both `manifest.conf` and `launch.sh`.
For backward compatibility, an older adapter that has `launch.sh` but no
manifest is accepted with default capabilities. If a manifest exists but its
API version is unsupported or a value is invalid, that adapter is skipped.

## Manifest format

The manifest is plain `key=value` data. It is parsed as data and is never
sourced or evaluated as shell code.

```ini
adapter_api=1
priority=100
volume_owner=system
power_owner=system
```

| Key | Accepted values | Default | Meaning |
|---|---|---|---|
| `adapter_api` | `1` | `1` | Adapter contract version |
| `priority` | integer 0–9999 | `100` | Higher values win when multiple adapters are installed on the same card |
| `volume_owner` | `system`, `frontend` | `system` | Selects who owns volume-key behavior while the frontend runs |
| `power_owner` | `system`, `frontend` | `system` | Selects who owns the power key while the frontend runs |

When priorities are equal, the first adapter in lexical directory order wins.
The hidden canonical path is considered before the visible alias. TF2 still
takes precedence over TF1, regardless of adapter priority.

The card-side `/mnt/SDCARD/baseos.conf` may set `frontend_id=<adapter-id>`
to pin one adapter. The default `frontend_id=auto` selects the highest-priority
valid adapter. The legacy `frontends_order` setting is no longer used.

## Managed frontend packages and configuration profiles (package API 1)

New installations should use a managed package directory rather than placing
files in the DATA root:

```text
/mnt/SDCARD/
├── Games/                         # shared ROM library
└── Frontends/
    └── slot-rg353ps/               # package_id: slot-rg353ps
        ├── baseos-frontend.conf
        ├── launch.sh
        ├── payload/                # package-owned executable/resources
        └── profiles/
            ├── 640-native.conf     # profile_id: 640-native
            └── 640x480.conf       # profile_id: 640x480
```

Install by extracting the archive so its one top-level package directory is
directly inside `Frontends/`. Do not split the archive or copy individual
files into the DATA root. BaseOS discovers packages in `TF2/Frontends/` and
then `TF1/Frontends/`; TF2 wins if the same package/profile ID is present on
both cards.

The package directory name is its stable `package_id`. Each file name inside
`profiles/` (without `.conf`) is a separate `profile_id`. Both IDs use 1–22
ASCII letters, digits, dots, underscores or hyphens and cannot start with a
dot, hyphen or underscore. The combined runtime ID is:

```text
<package_id>--<profile_id>
slot-rg353ps--640-native
slot-rg353ps--640x480
```

This permits one program package to offer multiple configurations without
duplicating the executable payload. Each profile gets a separate BaseOS
instance directory at:

```text
/mnt/SDCARD/.baseos/instances/<package_id>--<profile_id>/
```

The package manifest is plain data, never sourced:

```ini
package_api=1
display_name=Slot
priority=100
volume_owner=frontend
power_owner=frontend
```

Each profile file is also plain data:

```ini
profile_api=1
display_name=640 Native
priority=100
```

Required keys are `package_api=1` and `profile_api=1`. Optional profile
values `priority`, `volume_owner` and `power_owner` override the package
defaults. Invalid IDs, unsupported API versions, invalid ownership values,
missing `launch.sh` or missing profile files are rejected.

The selected profile is exposed to the launch script through:

| Variable | Meaning |
|---|---|
| `BASEOS_FRONTEND_ID` | Combined package/profile ID |
| `BASEOS_PACKAGE_ID` | Package identity |
| `BASEOS_PROFILE_ID` | Configuration profile identity |
| `BASEOS_PACKAGE_DIR` | Package directory |
| `BASEOS_PROFILE_CONFIG` | Selected profile's default config file |
| `BASEOS_INSTANCE_ID` | Combined instance ID |
| `BASEOS_INSTANCE_DIR` | Per-profile persistent instance directory |
| `BASEOS_DATA_DIR` | Per-profile private data directory |
| `BASEOS_USERDATA_DIR` | Per-profile private user-data directory |
| `BASEOS_CARD_ROOT` | TF1 user-data root |
| `BASEOS_GAMES_DIR` | Canonical shared game directory (`Games/`) |

`BASEOS_FRONTEND_ROOT` continues to mean the selected card root for backward
compatibility. New package launchers should use `BASEOS_PACKAGE_DIR` for
program files and `BASEOS_CARD_ROOT` / `BASEOS_GAMES_DIR` for shared card
content. Read the selected profile file as configuration data; do not source
it as shell code.

### Boot selector and uninstall

Hold **L1 or R1 while powering on** to open the BaseOS frontend selector.
Function-triggered USB storage keeps priority over the selector. In the
selector:

- **A** launches the highlighted profile once.
- **Start** saves the highlighted profile as `frontend_id` and launches it.
- **Y** opens a confirmation to remove only the selected profile/configuration.
- **X** opens a confirmation to uninstall the entire frontend package.
- **B** cancels and continues with the configured default frontend.

Profile removal deletes only the selected `profiles/<profile-id>.conf`. If
other profiles remain, the common program payload stays installed and those
profiles remain selectable. If the removed profile was the last one, BaseOS
also removes the now-unused package directory.

Full frontend uninstall removes the complete
`Frontends/<package-id>/` directory, including every profile and the shared
program payload. Both removal operations preserve
`.baseos/instances/<package-id>--<profile-id>/`, `Games/`, shared saves,
cores and all other shared data. Reinstalling the same package/profile IDs can
therefore reuse their previous settings. If a removed profile/package supplied
the configured default, BaseOS selects another discovered managed profile as
the new default; if none remain, it changes `frontend_id` back to `auto`.

The selector manages the new `Frontends/<package-id>/` package format,
including multiple profiles within one package. A profile is an independent
user configuration, not a second copy of the executable. Legacy
`.baseos/frontends/<adapter-id>/` adapters remain supported for automatic and
pinned startup, but are not removable through this managed-package selector.

### Shared Games directory

The canonical ROM directory is `/mnt/SDCARD/Games/`. The old `Roms/`
directory is renamed to `Games/` at startup only when `Games/` does not
already exist. If both exist, BaseOS preserves both and does not attempt an
automatic merge; merge their contents manually before removing the old
directory. Frontend-specific system names and internal ROM paths are mapped
by the package's adapter configuration; BaseOS does not require each frontend
to use the same internal system labels.


### Runtime data ownership in the RG353PS Slot package

The managed Slot adapter applies the following ownership boundaries:

| Data | Location while Slot runs | Ownership |
|---|---|---|
| ROM library | `Games/` | Shared by all frontends and profiles |
| Battery saves (`.sav`) | `Saves/` | Shared by all frontends and profiles |
| Emulator cores | DATA-root `System/` or the BaseOS shared-core directory | Shared |
| Slot user data | Per-profile `.userdata/` | Private to the selected profile |
| Favorites and Slot preferences | Per-profile `System/slot.state` | Private to the selected profile |
| Display/theme and other mutable Slot settings | Per-profile `System/*.txt` state files | Private to the selected profile |
| Save-state snapshots / resume states | Per-profile `States/` | Private to the selected profile |

The launcher seeds profile-owned state once from an existing card-root Slot
installation when present, then bind-mounts the profile copy for subsequent
sessions. Battery saves under `Saves/` remain shared; save-state snapshots
under `States/` are intentionally separate. Removing a profile does not
remove its instance data, so reinstalling the same package/profile identity
can reuse it.

The current RG353PS Slot source does not implement a recently-played list.
The API ownership rule for recent-play history is nevertheless profile-private:
frontends that add this feature must persist it below
`BASEOS_USERDATA_DIR` or another profile-owned path, never in the shared
package payload.

### Per-category asset-sharing extension (design only; not active in this test)

The API reserves per-profile policy keys in the persistent
`BASEOS_PROFILE_CONFIG` file:

```ini
asset_cartridge_art=shared
asset_overlays=separate
asset_wallpapers=shared
asset_bootlogos=separate
asset_music=shared
asset_fonts=shared
asset_bios=separate
```

Accepted values are `shared` and `separate`. The intended roots are
`/mnt/SDCARD/.baseos/shared/assets/<category>/` for shared assets and
`/mnt/SDCARD/.baseos/instances/<package-id>--<profile-id>/assets/<category>/`
for profile-private assets. Categories are independent; a frontend may support
only the categories it actually consumes. Program binaries, package resources,
ROMs and battery saves are not moved by this policy.

This is a design reservation, not an implemented runtime feature in the
1.2.10 test build. In particular, the current Slot package still reads its
artwork and media from its established card-root paths; it does not yet apply
the `asset_*` keys or merge shared/private overlays with package defaults.
Do not add these keys expecting the current test build to change asset
visibility. The adapter implementation and migration tests must land before
this extension is considered supported.

## Launch contract

BaseOS runs `launch.sh` using `/bin/sh`. For a managed package, its package
directory is the current working directory; for a legacy adapter, the selected
card or wrapper directory remains the current working directory. Scripts do
not need the executable bit, which is important for exFAT cards and Windows
extraction tools.

BaseOS exports:

| Variable | Meaning |
|---|---|
| `PLATFORM` | Device platform identifier (`rg353ps`) |
| `BASEOS_FRONTEND_ID` | Selected adapter ID |
| `BASEOS_FRONTEND_ROOT` | Selected card root (kept compatible with legacy launchers) |
| `BASEOS_PACKAGE_DIR` | Managed package directory; empty for legacy adapters |
| `BASEOS_PACKAGE_ID` | Stable package identity |
| `BASEOS_PROFILE_ID` | Selected configuration profile identity |
| `BASEOS_PROFILE_CONFIG` | Persistent per-profile config, seeded once from package defaults |
| `BASEOS_PROFILE_DEFAULTS` | Read-only profile defaults shipped by the package |
| `BASEOS_INSTANCE_ID` | Combined package/profile identity |
| `BASEOS_INSTANCE_DIR` | Per-profile persistent instance directory |
| `BASEOS_CARD_ROOT` | TF1 user-data root |
| `BASEOS_GAMES_DIR` | Canonical shared game root (`Games/`) |
| `BASEOS_DATA_DIR` | Persistent adapter/profile-private data directory |
| `BASEOS_USERDATA_DIR` | Persistent adapter/profile-private user-data directory |
| `BASEOS_BOOT` | Mounted boot partition |
| `BASEOS_SYSTEM_ROOT` | System root (`/`) |
| `BASEOS_LAUNCHER` | Adapter launch-script path |
| `BASEOS_SLEEP` | RG353PS suspend helper (`/usr/sbin/rg353ps-sleep`) |

Legacy adapters receive private directories under
`<frontend-root>/.baseos/data` and `<frontend-root>/.baseos/userdata`.
Managed package profiles receive independent directories under
`/mnt/SDCARD/.baseos/instances/<package-id>--<profile-id>/`. Their
`config/profile.conf` is copied from package defaults only on first use, so
user settings survive package updates and uninstall/reinstall. A launch script
should use these exported paths rather than writing persistent settings into
the read-only system root.

On RG353PS, `BASEOS_SLEEP` is the supported suspend entry point. A frontend
that declares `power_owner=frontend` should invoke this helper on an explicit
user suspend action. It selects deep suspend-to-RAM, handles the SDIO Wi-Fi
power sequence, and returns after the physical Power key wakes the device.
**Do not blank the backlight or write brightness=0 before calling it, and do
not overwrite the restored brightness with a cached frontend level after it
returns**: BaseOS owns backlight capture, blanking and restoration for this
native suspend path. Frontend on_close/on_open backlight handling is reserved
for platforms without this helper or a fallback when it cannot start. Do not
replace this with an idle poweroff timer. The helper is not hibernation and
does not provide RTC self-wakeup; see [POWER.md](POWER.md).

BaseOS follows the upstream ownership boundary for RG353PS Wi-Fi:
it loads the `rtw88_8821cs` driver asynchronously during boot, waits for
`wlan0`, unblocks Wi-Fi through `rfkill` and raises the interface. It does
not associate with an access point or run the frontend's DHCP session.

The frontend owns scanning, saved credentials, association, `wpa_supplicant`
and DHCP through its card-side `System/slotnet.sh` and `System/wifi.conf`.
The RG353PS Slot launcher passes `AGS_ROOT` as the selected card root and
overrides `AGS_NET_MODULE=rtw88_8821cs`: the upstream helper defaults to the
H700 vendor module name `8821cs`, while this target uses the mainline rtw88
SDIO driver. Normally BaseOS has already loaded it asynchronously before the
Wi-Fi UI is opened; the module override is a recovery fallback if `wlan0`
has not appeared yet. The RG353PS Slot package otherwise uses the upstream
script without translating its connection lifecycle into a BaseOS-specific
API. During deep suspend, BaseOS passes the active card root to the script,
takes the network down, and starts it again after the SDIO driver has rebound;
older packages without the script retain a legacy BaseOS-helper fallback.

A minimal adapter:

```sh
#!/bin/sh
set -eu

FRONTEND_ROOT=$BASEOS_FRONTEND_ROOT
exec "$FRONTEND_ROOT/System/frontend"
```

The adapter is trusted code and runs with root privileges. BaseOS does not
attempt to sandbox it. Only install packages from sources you trust.

## System-service ownership

BaseOS remains responsible for hardware-level services. A frontend should use
the provided system interfaces rather than independently reinitializing shared
hardware:

- Audio device initialization and the RK817 hardware gain layer.
- Wi-Fi and Bluetooth device initialization and connection helpers.
- Power-key sampling, clean shutdown and suspend/resume helpers.
- USB MTP and exclusive USB Mass Storage transitions.
- Persistent boot-logo restoration across A/B system updates.

A frontend with its own volume bar should declare `volume_owner=frontend`.
BaseOS then holds the system mixer at a fixed level while the frontend runs and
restores the prior mixer level when it exits. Otherwise use `system`.

A frontend that must process the power key itself should declare
`power_owner=frontend`. Otherwise BaseOS's hotkey daemon remains responsible
for short-press suspend and long-press shutdown.

When `power_owner=frontend` is declared, the frontend must provide both
short-press suspend and an explicit shutdown path. On RG353PS, short-press
suspend should use `BASEOS_SLEEP`; long-press shutdown remains a real
poweroff/reboot action chosen by the frontend.

Older adapters without a manifest may still use the transitional
`# baseos: volume-owned` and `# baseos: power-owned` markers. New adapters
should declare these capabilities in the manifest instead.

## Boot-logo contract

BaseOS owns boot-logo restoration and display; the frontend owns only the
selection UI and persistent selection record. The shared durable image path is
`/mnt/SDCARD/Bootlogos/<filename>.bmp`, and the selected basename is stored in
`/mnt/SDCARD/System/bootlogo.txt`. The active copy on `/mnt/boot/bootlogo.bmp`
belongs to the A/B-updated boot partition and must not be treated as the only
saved copy.

The current RG353PS image format is 640×480, 24-bit, uncompressed BMP. A
frontend must reuse the already-mounted boot partition, preserve the original
image once, verify writes, and save the selection record only after a
successful install. The restore path reads persistent TF1 user data, so a
frontend launched from TF2 must write shared selection state to
`/mnt/SDCARD`, not only to its own `/mnt/sdcard` alias.

See [BOOTLOGO.md](BOOTLOGO.md) for the partition model, write/verify sequence
and update lifecycle.

## Storage and multi-card behavior

BaseOS exposes the selected frontend card as `/mnt/sdcard` for compatibility.
Managed packages use `/mnt/SDCARD/Games/` as the canonical shared ROM library;
the frontend still owns its system names, scanning rules and internal paths.
The old `Roms/` directory is renamed to `Games/` only when `Games/` is
absent. If both exist, BaseOS preserves both and does not merge them
automatically. Legacy adapters may continue using their historical layout.

The system user-data partition is mounted at `/mnt/SDCARD`. Keep frontend
packages and game data on user-data partitions, not on `BASEOS_BOOT`.

## Legacy package compatibility

For older package layouts that place an updater at `.tmp_update/updater`,
BaseOS retains a compatibility fallback. A valid generic adapter always takes
precedence over this fallback. New frontend ports should use the adapter
contract above rather than depending on legacy updater staging.

## Diagnostics and performance

If no valid adapter is found, BaseOS starts the built-in diagnostic UI and,
when debugging is enabled, persists the discovery trace to
`BASEOS_BOOT/baseos-frontend-detection.txt`.

BaseOS caches the last successful selection for both automatic and pinned
modes. On an ordinary boot, it validates the selected launcher and checks only
adapter-directory/file timestamps using shell builtins; it does not reopen all
manifests or spawn a process per adapter. A new, removed or modified adapter
invalidates the cache and triggers one dynamic scan of the affected card. TF2
is still checked before TF1, and a newly mounted TF2 card invalidates a TF1
selection.
