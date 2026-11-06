# MTP file-transfer integrity acceptance tool

Verifies that files survive a real MTP round trip byte for byte on the RG353PS.
It exists because "the device enumerated and a file appeared" is not evidence:
every PASS in the report comes from a size and SHA-256 comparison of the bytes
that actually arrived.

The tool is a test harness. It is not installed into the rootfs, does not run at
boot, and never changes kernel, USB PHY, Supervisor, DHCP, MTP-responder or
Mass Storage behaviour.

## What it checks

| Stage | What happens |
|---|---|
| `prepare` | Creates one marked dataset directory under the MTP storage root |
| `pull` | Device -> host, every file compared against the device manifest |
| `push` | Host -> device -> host with fresh data, digests compared |
| `ops` | mkdir / create / overwrite / rename / delete inside the tool's tree |

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
├── mtp_backends.py        local, gvfs, libmtp and Windows WPD adapters
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
  - **Linux**: `mtp-tools` (`mtp-getfile`, `mtp-sendfile`, ...) or a gvfs MTP
    mount passed as `--gvfs-root`.
  - **local**: `--backend local --root DIR` substitutes a directory for the
    device storage. This is the simulation used by the automated tests and it
    is **not** a device acceptance result.

## Handheld requirements

- The normal USB profile with MTP enabled (`usb_mtp=yes`), i.e. a stock
  development or release image. No diagnostic kernel is needed.
- The MTP storage root must be `/mnt/SDCARD`.
- The device side scripts only need BusyBox `sh`, `dd`, `mkdir`, `wc`,
  `sha256sum`, `date` and `od`. Nothing from coreutils beyond that.

## Usage

### 1. Prepare the dataset on the handheld

Over SSH (preferred, fastest, and the tree is hashed on the device):

```sh
scp tools/mtp/device/mtp-prepare.sh root@192.168.42.1:/tmp/
ssh root@192.168.42.1 'sh /tmp/mtp-prepare.sh --storage /mnt/SDCARD --profile full'
# prints: run_id=..., test_dir=..., files=7
```

`--profile fast` produces the shrunken variant. The script refuses to replace an
existing directory unless `--force` is given **and** the existing marker proves
this tool created it with the same run id.

### 2. Verify over MTP from the host

```sh
python3 tools/mtp/mtp_integrity.py run \
    --backend windows-wpd --mtp-device RG353PS --mtp-storage RG353PS \
    --run-id 20261106-120000-abcdef --dataset-profile full --skip-prepare \
    --device-ssh "ssh root@192.168.42.1" --device-storage-root /mnt/SDCARD \
    --out ./mtp-integrity-20261106-120000-abcdef
```

| Flag | Why |
|---|---|
| `--skip-prepare` | the dataset already exists on the device (`mtp-prepare.sh` ran there) |
| `--device-ssh` | record the handheld environment and, on Windows, verify uploads with the device's own SHA-256 |
| `--device-storage-root` | where the MTP storage root lives on the device (default `/mnt/SDCARD`) |
| `--timeout` | per-object wait in seconds; raise it for the 128 MiB payload over WPD |

Individual stages are also available: `prepare`, `pull`, `push`, `ops`,
`cleanup`. `pull`/`push`/`ops` need `--run-id`.

Reports are written outside the repository by default, or wherever `--out`
points. Do not commit them.

### 3. Clean up

```sh
ssh root@192.168.42.1 'sh /tmp/mtp-cleanup.sh --run-id 20261106-120000-abcdef --confirm'
```

Cleanup is always a separate, explicit step. It re-checks the marker, the run id
and the resolved path before deleting, and it deletes exactly one directory:
`<storage>/baseos-mtp-test-<run_id>`.

## Safety boundary

- Only `<storage>/baseos-mtp-test-<run_id>` is created or removed.
- Every path from a manifest passes `safe_relpath` (no absolute paths, no `..`,
  no drive letters, no NUL) and `contained_path` (real-path containment plus a
  symlink refusal).
- A directory without this tool's marker is never replaced or deleted, even
  with `--force`.
- Cleanup requires `--confirm` (device script) or `--confirm-cleanup` (host
  tool) and refuses a mismatched run id.
- The tool never touches `/dev/mmcblk*`, mounts, the UDC, configfs or the USB
  gadget state, never reboots and never flashes.
- SKIP is reported separately and is never counted as PASS. A `--backend local`
  run marks `mtp: false` in the report because no MTP transport was involved.

## Status

| Level | Result |
|---|---|
| Local script tests | 16/16 pass (both directions, hash mismatch, missing file, unicode/space/nested names, rename/overwrite/delete, no clobber, traversal refusal, cleanup scope, hostile manifest) |
| Simulated MTP (`--backend local`) | `--dataset-profile full`: 31 checks, 0 failures, including the 128 MiB file in both directions |
| RG353PS over real MTP (Windows WPD), `fast` | kernel `7.2.7-baseos-rg353ps`: **25 pass / 0 fail / 5 skip** in 68 s |
| RG353PS over real MTP (Windows WPD), `full` (128 MiB) | **25 pass / 0 fail / 5 skip** in 99 s, including `large-128m.bin` (134217728 bytes) downloaded over MTP and re-uploaded with its device-side SHA-256 matched |

The 5 skips are WPD platform limits, not failures: `overwrite`, `rename-file`,
`rename-dir`, `delete-file`, `delete-dir` each make the Windows Shell raise a
modal confirmation dialog that no `CopyHere` flag suppresses.

Still open on hardware: the Mass Storage hand-off, MTP-only sessions and
long-running stability; those are separate acceptance items.

## Limitations

- **Windows WPD cannot read back a just-written object.** The Shell namespace
  raises a modal prompt for it, and `CopyHere` reports no error when its UI is
  suppressed, so the call simply blocks. The tool therefore never performs that
  read-back over WPD: with `--device-ssh` it hashes the uploaded files on the
  device instead and labels the check `push-device-hash`, explicitly not an MTP
  read-back.
- **WPD delete / rename / overwrite always prompt**, so those verbs are declared
  unsupported and reported as SKIP. Use `--backend linux-gvfs` or
  `linux-mtp-tools` for the full operation matrix, or perform them by hand.
- **Never overwrite a name over WPD.** `wpd.ps1` refuses instead of triggering a
  replace prompt, and every run uses a unique `_upload-<run-id>-<rand>` /
  `_ops-<run-id>-<rand>` directory, so repeated runs cannot collide.
- `linux-mtp-tools` has no rename either; use `--gvfs-root` when a full matrix is
  required.
- Device-side hashing needs SSH (`--device-ssh`) and a shell on the handheld. It
  is a different evidence path from an MTP read-back and is reported as such.
