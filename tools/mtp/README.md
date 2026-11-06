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
    --backend auto \
    --run-id 20261106-120000-abcdef \
    --dataset-profile full \
    --device-ssh "ssh root@192.168.42.1" \
    --out ./mtp-integrity-20261106-120000-abcdef
```

`--device-ssh` is optional: when given, its output (`uname`, release, UDC state)
is recorded as the device environment so the report describes both ends. Without
it the report says the device side was not identified rather than guessing.

`run` executes prepare (idempotent check), pull, push and ops, then writes:

- `report.json` — machine readable: run id, timestamps, host/device environment,
  backend, per-file direction, sizes, digests, operation results, failure
  reasons, duration, totals.
- `report.md` — the same content as tables for a human reviewer.

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

Verified in this repository:

- Local script tests: the automated suite (16 cases) passes, covering both
  transfer directions, hash mismatch, missing files, unicode/space names,
  nested paths, rename/overwrite/delete, refusal to overwrite an existing tree,
  path-traversal refusal, and cleanup scope.
- Simulated MTP run: `--backend local` with `--dataset-profile full` completes
  31 checks with 0 failures, including the 128 MiB file in both directions.

Not yet verified (real hardware must confirm, and must not be reported as
passed before it is run):

- RG353PS over real MTP with the Windows WPD adapter and with `mtp-tools`.
- MTP-only sessions, Mass Storage hand-off and long-running stability are
  separate acceptance items and are out of scope for this tool.

## Limitations

- The Windows adapter drives the same Shell/WPD stack Explorer uses.
  `rename` has no dependable scriptable verb there, so it is reported as SKIP
  (never PASS). `delete` goes through the shell verb and is verified by
  re-listing the folder.
- `linux-mtp-tools` cannot rename either; use `--gvfs-root` when a full
  operation matrix is required.
- The WPD helper must run in a normal Windows session. Sandboxes that block COM
  object creation cannot execute it; the Python layer reports that as a backend
  error instead of a fake success.
