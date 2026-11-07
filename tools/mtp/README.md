# MTP file-transfer integrity acceptance tool

Verifies that files survive a real MTP round trip byte for byte on the RG353PS.
It exists because "the device enumerated and a file appeared" is not evidence:
every PASS in the report comes from a size and SHA-256 comparison of the bytes
that actually arrived.

The tool is a test harness. It is not installed into the rootfs, does not run at
boot, and never changes kernel, USB PHY, Supervisor, DHCP, MTP-responder or
Mass Storage behaviour.

## Verification levels

Keep these three apart; only the last one is device acceptance.

| Level | What runs | What it proves |
|---|---|---|
| Local script tests | `tests/test_mtp_integrity.py` (35 cases) + `tests/test-rg353ps-mtp-integrity.sh` | manifests, digests, path containment, cleanup guards, device-script behaviour |
| Simulated MTP | `--backend local --root DIR` | the full dataset logic against a directory standing in for device storage. **No MTP transport is involved**; the report sets `mtp: false` |
| Real hardware | Windows WPD (or gvfs on Linux) against the handheld | the device actually moved the bytes. Results are recorded in `platforms/rg353ps/USB.md` |

## What it checks

| Stage | What happens |
|---|---|
| `prepare` | Creates one marked dataset directory under the MTP storage root |
| `pull` | Device -> host, every file compared against the device manifest |
| `push` | Host -> device, with fresh data; the arriving bytes are verified (see below) |
| `ops` | mkdir / create / overwrite / rename / delete inside the tool's tree, limited to the verbs the active backend can express — the rest are reported as SKIP |

How `push` is verified, per backend:

- **Filesystem-backed backends** (local simulation, gvfs mount): the file is
  copied back out through the same transport and its SHA-256 is compared with
  the host original — a true host -> device -> host round trip.
- **Windows WPD**: the object is uploaded over MTP, and the digests are then
  computed **on the device over SSH** (`--device-ssh`), reported as
  `push-device-hash`. This is deliberately **not** a post-upload MTP read-back:
  reading back an object that was written moments ago makes the Windows Shell
  raise a modal prompt (see Limitations), so the tool never attempts it.

Dataset (identical to `DATASET_FULL` in `mtp_common.py` and to
`device/mtp-prepare.sh`):

| Path | Size | Purpose |
|---|---|---|
| `small-4k.bin` | 4 KiB | small file |
| `medium-1m.bin` | 1 MiB | medium file |
| `large-128m.bin` | 128 MiB | large file |
| `中文文件名.txt` | 1 KiB | non-ASCII name |
| `name with spaces.txt` | 1 KiB | spaces in name |
| `中文 目录 with spaces/嵌套 子目录/深层 文件.txt` | 1 KiB | unicode + spaces + depth |
| `nested/sub/deep.bin` | 64 KiB | plain file in nested directories |

`--dataset-profile fast` keeps the same layout but caps the large payloads at
8 KiB so the automated suite stays quick. Real acceptance runs use `full`.

## Layout

```
tools/mtp/
├── mtp_integrity.py       CLI: prepare / pull / push / ops / run / cleanup / selftest
├── mtp_common.py          dataset spec, manifests, run ids, path containment
├── mtp_backends.py        local, gvfs and Windows WPD adapters
├── hosts/wpd.ps1          Windows Portable Devices helper (Shell/WPD stack)
├── device/mtp-prepare.sh  BusyBox generator, runs on the handheld
├── device/mtp-cleanup.sh  BusyBox cleanup, marker + run id checked first
└── tests/test_mtp_integrity.py
```

## Host requirements

- Python 3.8+ (standard library only, no third-party packages).
- One MTP adapter:
  - **Windows**: built-in WPD stack, driven through `hosts/wpd.ps1`. No drive
    letter is assumed; the device is located by name inside "This PC".
  - **Linux**: a gvfs MTP mount passed as `--gvfs-root` (e.g. under
    `/run/user/1000/gvfs/...`). This is the only Linux backend.
  - **local**: `--backend local --root DIR` substitutes a directory for the
    device storage. This is the simulation used by the automated tests and it
    is **not** a device acceptance result.
- **`linux-mtp-tools` is disabled.** libmtp's `mtp-tools` address objects by
  numeric file/folder/storage IDs, so a path-based adapter cannot be implemented
  reliably without re-verifying the ID mapping against a real libmtp build. The
  CLI refuses `--backend linux-mtp-tools` and `auto` never selects it.

## Handheld requirements

- The normal USB profile with MTP enabled (`usb_mtp=yes`), i.e. a stock
  development or release image. No diagnostic kernel is needed.
- The MTP storage root must be `/mnt/SDCARD`. It is the only writable user-data
  mount: `/` is a read-only rootfs and `/mnt/boot` holds the boot partition.
  Both scripts and the host tool refuse any other root unless
  `--allow-nonstandard-storage` (device) or `--allow-nonstandard-device-root`
  (host) is passed explicitly.
- BusyBox userland. The device-side commands actually used are:

  `sh` `printf` `[` `date` `od` `tr` `grep` `cut` `head` `wc` `dd` `mkdir`
  `dirname` `sha256sum` `rm` `mv` `sync` `cat` `pwd`

  Verified present on the RG353PS itself with BusyBox v1.37.0
  (`command -v` for each name, plus `pwd -P`, `readlink -f`, `test -L`,
  `grep -Eq` and `sha256sum < file` exercised on the device). `mtp-prepare.sh`
  also falls back to `busybox sha256sum` when `sha256sum` is not on `PATH`.
  Nothing here needs coreutils' GNU extensions.

## Usage

### 1. Prepare the dataset on the handheld

Over SSH (preferred: fastest, and the tree is hashed on the device):

```sh
scp tools/mtp/device/mtp-prepare.sh root@192.168.42.1:/tmp/
ssh root@192.168.42.1 'sh /tmp/mtp-prepare.sh --storage /mnt/SDCARD --profile full'
# prints: run_id=..., test_dir=..., files=7
```

`--profile fast` produces the shrunken variant. The script refuses to replace an
existing directory unless `--force` is given **and** the existing marker proves
this tool created it with the same run id.

### 2. Verify over MTP from the host

Use the dataset that step 1 created, so pass `--skip-prepare` and point
`--device-ssh` at the handheld:

```sh
python3 tools/mtp/mtp_integrity.py run \
    --backend windows-wpd --mtp-device RG353PS --mtp-storage RG353PS \
    --run-id 20261106-120000-abcdef --dataset-profile full --skip-prepare \
    --device-ssh "ssh root@192.168.42.1" --device-storage-root /mnt/SDCARD \
    --timeout 300 \
    --out ./mtp-integrity-20261106-120000-abcdef
```

| Flag | Why |
|---|---|
| `--skip-prepare` | **required in practice**: the dataset already exists on the device (`mtp-prepare.sh` ran there); re-running prepare would either refuse or duplicate it |
| `--device-ssh` | records the handheld environment and, on Windows, verifies uploads with the device's own SHA-256 (`push-device-hash`) |
| `--device-storage-root` | where the MTP storage root lives on the device; `/mnt/SDCARD` is the only allowed value |
| `--timeout` | per-object wait in seconds; raise it for the 128 MiB payload over WPD |

On Windows under Git Bash, prefix the command with `MSYS_NO_PATHCONV=1` so MSYS
does not rewrite `/mnt/SDCARD` into a `C:/...` path before Python sees it.

Individual stages are also available: `prepare`, `pull`, `push`, `ops`,
`cleanup`. `pull`/`push`/`ops`/`cleanup` need `--run-id`.

Reports are written outside the repository by default, or wherever `--out`
points. Do not commit them.

### 3. Clean up

```sh
ssh root@192.168.42.1 'sh /tmp/mtp-cleanup.sh --run-id 20261106-120000-abcdef --confirm'
```

Cleanup is always a separate, explicit step. It re-checks the marker, the run id
and the resolved path before deleting, and it deletes exactly one directory:
`<storage>/baseos-mtp-test-<run_id>`.

The host `cleanup` subcommand only works on backends that can delete. On Windows
WPD it stops with an error and prints the device command above instead of
triggering a Shell delete confirmation dialog.

## Safety boundary

- Only `<storage>/baseos-mtp-test-<run_id>` is created or removed.
- Every path from a manifest passes `safe_relpath` (no absolute paths, no `..`,
  no drive letters, no NUL) and `contained_path` (real-path containment plus a
  symlink refusal). A symlink inside the tree — even one pointing at another
  directory inside the root — is refused, not followed.
- A directory without this tool's marker is never replaced or deleted, even
  with `--force`; a marker whose `run_id` does not match is refused too.
- Cleanup requires `--confirm` (device script) or `--confirm-cleanup` (host
  tool) and refuses a mismatched run id.
- A delete is never attempted through an adapter that reports
  `capabilities["delete"] = False`; the run fails with instructions instead, and
  a refused delete is never recorded as PASS.
- The device storage root is pinned to `/mnt/SDCARD` by default on both sides.
- The tool never touches `/dev/mmcblk*`, mounts, the UDC, configfs or the USB
  gadget state, never reboots and never flashes.
- SKIP is reported separately and is never counted as PASS. A `--backend local`
  run marks `mtp: false` in the report because no MTP transport was involved.

## Continuous integration

`.github/workflows/rg353ps-mtp-integrity.yml` runs on pull requests that touch
`tools/mtp/**` or the test wrapper: POSIX `sh` and `dash` syntax for both device
scripts, Python compilation, the unit/path-safety/cleanup-safety suite, and a
simulated full-dataset run (128 MiB, both directions) whose report is asserted
to be green **and** labelled `mtp: false`. CI has no MTP device, so it never
claims hardware acceptance.

## Status

| Level | Result |
|---|---|
| Local script tests | 35 cases: both directions, hash mismatch, missing file, unicode/space/nested names, rename/overwrite/delete, no clobber, traversal refusal, real symlink escape, forged/mismatched marker, delete-capability guard, device-script storage pinning, cleanup scope. All pass on Linux; the `auto`-adapter case skips on Windows and symlink cases skip where the platform refuses `os.symlink` |
| Simulated MTP (`--backend local`) | `--dataset-profile full`: 31 checks, 0 failures, including the 128 MiB file in both directions |
| RG353PS over real MTP (Windows WPD), `fast` | kernel `7.2.7-baseos-rg353ps`: **25 pass / 0 fail / 5 skip** in 68 s |
| RG353PS over real MTP (Windows WPD), `full` (128 MiB) | **25 pass / 0 fail / 5 skip** in 99 s |

What the two hardware runs actually did:

- **Device -> host**: every file was downloaded over MTP and compared byte for
  byte (size + SHA-256) against the device-side manifest, including
  `large-128m.bin` (134217728 bytes), a Chinese filename, a name with spaces and
  a three-level unicode/spaced path.
- **Host -> device**: seven files were uploaded over MTP; the digests were then
  computed on the device itself over SSH and compared with the host originals.
  These checks are reported with direction `push-device-hash`. **This is not a
  post-upload MTP read-back** — the tool never performs one over WPD.
- 5 checks were **SKIP**, never PASS: `ops:overwrite-file`, `ops:rename-file`,
  `ops:rename-dir`, `ops:delete-file`, `ops:delete-dir`. Each of those Shell
  verbs raises a modal confirmation dialog on Windows that no `CopyHere` flag
  suppresses, so the adapter declares them unsupported and the caller records
  SKIP.

Subsequent real-hardware reports on main have since completed the MTP-only
Release acceptance (14/14 host checks, 7/7 device-to-host size + SHA-256),
Mass Storage identification (20/20), Mass Storage -> MTP exit recovery,
30-minute Mass Storage stability (166/166) and Mass Storage write integrity
(Prepare 10/10, Verify 10/10). See
../../docs/mtp-only-release-fixed-20261106/README.md for the reports.

Still not covered on hardware: Linux GVFS operation, the five WPD mutating
operations listed above, MTP long-duration/repeated-unplug stability, and
MTP <-> Mass Storage mutual exclusion under load. The Mass Storage stability
report is not an MTP stability test; Mass Storage exit recovery is not an
under-load mutual-exclusion test.

## Limitations

- **Windows WPD cannot read back a just-written object.** The Shell namespace
  raises a modal prompt for it, and `CopyHere` reports no error when its UI is
  suppressed, so the call simply blocks. The tool therefore never performs that
  read-back: with `--device-ssh` it hashes the uploaded files on the device and
  labels the check `push-device-hash`, explicitly not an MTP read-back.
- **WPD cannot delete, rename or overwrite.** Those verbs always prompt, so they
  are declared unsupported, reported as SKIP, and `hosts/wpd.ps1` throws instead
  of invoking the Shell verb; `cleanup` refuses to run. Use
  `--backend linux-gvfs` for the full operation matrix, or delete on the device
  with `device/mtp-cleanup.sh --run-id <id> --confirm`.
- **Never overwrite a name over WPD.** `wpd.ps1` refuses instead of triggering a
  replace prompt, and every run uses a unique `_upload-<run-id>-<rand>` /
  `_ops-<run-id>-<rand>` directory, so repeated runs cannot collide.
- **`linux-mtp-tools` is disabled** (see Host requirements). `--backend auto`
  therefore resolves to Windows WPD or gvfs only.
- Device-side hashing needs SSH (`--device-ssh`) and a shell on the handheld. It
  is a different evidence path from an MTP read-back and is reported as such.
