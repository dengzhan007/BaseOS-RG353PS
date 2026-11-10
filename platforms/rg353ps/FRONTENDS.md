# RG353PS frontend adapter contract

BaseOS is a device system layer, not a frontend-specific distribution. It owns
boot, hardware services, storage mounting, power management, USB modes, system
updates, frontend discovery and process supervision. A game frontend owns its
UI, game-library discovery, ROM identification, emulator selection and game
launching.

## Installation and discovery

Install a frontend package on the root of a user-data card. Do not install
frontend files on the small `BASEOS_BOOT` partition.

At boot, BaseOS checks TF2 first. If TF2 has no usable adapter, it checks the
TF1 `BASEOS` user-data partition. On each card it checks the card root and one
wrapper-directory level, so archives extracted into a single containing folder
remain discoverable.

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

## Launch contract

BaseOS runs `launch.sh` using `/bin/sh`, with the selected frontend card as
the current working directory. Scripts do not need the executable bit, which
is important for exFAT cards and Windows extraction tools.

BaseOS exports:

| Variable | Meaning |
|---|---|
| `PLATFORM` | Device platform identifier (`rg353ps`) |
| `BASEOS_FRONTEND_ID` | Selected adapter ID |
| `BASEOS_FRONTEND_ROOT` | Card or wrapper directory containing the frontend |
| `BASEOS_DATA_DIR` | Persistent adapter-private data directory |
| `BASEOS_USERDATA_DIR` | Persistent adapter-private user-data directory |
| `BASEOS_BOOT` | Mounted boot partition |
| `BASEOS_SYSTEM_ROOT` | System root (`/`) |
| `BASEOS_LAUNCHER` | Adapter launch-script path |
| `BASEOS_SLEEP` | RG353PS suspend helper (`/usr/sbin/rg353ps-sleep`) |

The two private directories are created under
`<frontend-root>/.baseos/data` and `<frontend-root>/.baseos/userdata`.
The adapter may use its own existing storage layout instead, but should not
write persistent settings into the read-only system root.

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
It does not impose a universal ROM directory, save directory or multi-card
layout. A frontend may use its own card, TF1, TF2, or multiple game roots,
provided its adapter configures and documents those paths.

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
