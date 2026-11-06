# RG353PS Mass Storage host acceptance (read-only)

Host-side checks for the Mass Storage hand-off. Entering Mass Storage mode is a
manual operator action; this directory contains no device-side logic.

## Status (2026-11-06)

- First real-hardware run: **FAIL** with `no partition is associated with the
  mapped disk`. Raw evidence: `mass-storage-host-report.json` / `.md`. That run
  did confirm a unique `VID_2207&PID_0006` root and no MTP (`PID_0009` and WPD
  `RG353PS` both absent), but the strict WMI partition chain found no partitions
  on the confirmed disk.
- Inspection of `baseos-usb-storage` showed why: the mounted partition
  `/dev/mmcblk0pN` is written directly into the mass_storage LUN, so Windows
  may see a **partitionless exFAT whole-disk volume ("superfloppy")** with no
  partition table and therefore no `Win32_DiskDriveToDiskPartition` entries.
- This revision adds a strictly bounded superfloppy ownership path. No
  device-side USB logic was changed, no image was rebuilt, no card was written.
  The earlier FAIL report is kept as history and is not a PASS.
- **Re-test with that revision: PASS.** 20/20 host checks, `failures` empty.
  Unique `VID_2207&PID_0006` root -> `USBSTOR` LUN -> the single
  `\\.\PHYSICALDRIVE3` (zero partition associations); 6 read-only
  `IOCTL_STORAGE_GET_DEVICE_NUMBER` records, exactly one matched
  (`Volume{4508079a-...}` -> `DeviceNumber 3`), zero unresolved, giving `G:`
  exFAT `BASEOS_DATA`; the other volumes (device numbers 0/1/2) were excluded.
  7/7 sizes and 7/7 SHA-256 matched, including `large-128m.bin` (134217728
  bytes), Chinese names, spaces and a three-level path. Raw evidence:
  `mass-storage-host-report.json` / `.md`.
- **Exit recovery (Mass Storage -> MTP): PASS.** After a safe eject, cable pull,
  wait for the frontend to recover and a re-plug, the device returned as
  MTP-only: exactly one `VID_2207&PID_0009` root, zero `PID_0006/0007/0008`
  roots, a live WPD node (`PNPClass=WPD`, `Service=WUDFWpdMtp`) plus a live
  `RG353PS` Shell item, and zero `VID_2207` network adapters. Raw evidence:
  `exit-recovery-host-report.json` / `.md`. No file-transfer retest was run.

## Files

| File | Purpose |
| --- | --- |
| `check-rg353ps-mass-storage.ps1` | Windows host, read-only verification |
| `check-rg353ps-exit-recovery.ps1` | Windows host, read-only exit-recovery verification |
| `Rg353psDeviceMap.ps1` | Injectable pure resolver + read-only IOCTL helper |
| `test-rg353ps-mass-storage-device-map.ps1` | Offline tests for the resolver |
| `offline-test-results.json` | Raw offline test results |
| `mass-storage-host-report.json` / `.md` | Produced by the real-hardware host check |
| `exit-recovery-host-report.json` / `.md` | Produced by the exit-recovery host check |

## Strict device identity (no fallback scanning)

```
USB\VID_2207&PID_0006 (unique composite root)
  -> PnP children (DEVPKEY_Device_Children / USBSTOR)
  -> Win32_DiskDrive (exactly one matching disk)
  -> [partitioned] Win32_DiskDriveToDiskPartition (all partitions of THAT disk)
                   -> Win32_LogicalDiskToPartition + Win32_Volume
  -> [superfloppy] Win32_Volume GUID -> IOCTL_STORAGE_GET_DEVICE_NUMBER
                   -> DeviceNumber == the confirmed PHYSICALDRIVE index
```

The partitioned path still hard-FAILs on: zero or multiple PID_0006 roots, no
PnP children, a non-unique child-to-disk mapping, a non-USB/USBSTOR disk, a
RAW/unknown filesystem on **any** partition of that disk (including partitions
without a drive letter), zero or multiple accessible exFAT/FAT32 volumes, or
non-unique volume metadata.

## Superfloppy path (partitionless whole-disk volume)

Used **only** when WMI reports zero partition associations for the already
confirmed physical disk. For each `Win32_Volume` GUID the host opens a
zero-desired-access handle (`CreateFile` with `dwDesiredAccess = 0`) and sends
only the read-only `IOCTL_STORAGE_GET_DEVICE_NUMBER` (`0x2D1080`). The returned
`DeviceNumber` must equal the `PHYSICALDRIVE` number of that confirmed disk.

Hard-FAIL, before any test file is read: no IOCTL mapping data; any unresolved
volume GUID; zero or more than one volume mapped to the target disk; a RAW,
unknown or non-exFAT/FAT32 filesystem; a volume without a drive letter;
non-unique WMI volume metadata; or an undeterminable physical drive number.
Volumes belonging to other USB disks are ignored by exact device-number match —
there is no "scan all USB disks" and no "guess by exFAT" fallback.

The report keeps `diagnostics` with: `target_disk`, `target_disk_index`,
`partition_associations`, `volumes`, `ioctl_map`, `ioctl_matched_volumes` and
`unresolved_ioctl_volumes`.

## Exit recovery (Mass Storage -> MTP)

Run only after the operator has safely ejected the Mass Storage volume, pulled
the cable, given the frontend time to recover and re-plugged it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "F:\workspace\2026-10-28-22-11-37\.tmp-doc\p0-fix\win\docs\mtp-only-release-fixed-20261106\mass-storage\check-rg353ps-exit-recovery.ps1"
```

It polls for up to 30 seconds and passes only when all four conditions hold:

1. exactly one `USB\VID_2207&PID_0009\...` root node;
2. zero `VID_2207&PID_0006`, `PID_0007` and `PID_0008` root nodes;
3. WPD recognises `RG353PS`, proven by a **live** node with `PNPClass=WPD` /
   `Service=WUDFWpdMtp`, or a live `RG353PS` item in the Shell "This PC"
   namespace. Registry keys left behind by the older composite mode (for
   example `USB#VID_2207&PID_0008&MI_02#...`) are recorded as legacy entries
   and never count towards PASS;
4. no `VID_2207` network adapter, therefore no device-provided RNDIS/NCM
   interface.

The report also records, informationally, whether any `BASEOS_DATA`/exFAT
volume is still mounted; that field never changes the verdict. A failing run
keeps its raw diagnostics and attempts nothing: no restart, no configuration
change, no repair, no retry against another device.

## Read-only safeguards

- Only metadata reads and `Get-FileHash`; no writes to the device.
- No disk initialisation, no volume formatting, no repair utility, no
  partition/drive-letter changes, no deletion, no SSH.
- A Windows format prompt is a hard stop, but it is **only one layer**: strict
  mapping, RAW/unknown filesystem detection and exact IOCTL ownership stop the
  script before any volume is accessed at all.
- The 7-file dataset (`baseos-mtp-test-<run_id>`) and its device-produced
  manifest are read only from the uniquely owned volume.

## Offline tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-rg353ps-mass-storage-device-map.ps1
```

28 cases: the original partitioned-path regressions plus superfloppy success,
an unrelated USB exFAT disk that must never be selected, multiple volumes on
the target disk, device-number mismatch, RAW/unknown/non-exFAT filesystems,
missing or unresolved IOCTL data, missing drive letter, duplicate volume
metadata and an undeterminable drive index. One case compiles the IOCTL helper
offline without calling any P/Invoke. Every case asserts that neither the other
USB disk nor its volume is selected. Results: `offline-test-results.json`.

## Real-hardware re-test command

First, manually put the RG353PS into USB Mass Storage mode and wait for Windows
to enumerate `VID_2207&PID_0006`. Then run once:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "F:\workspace\2026-10-28-22-11-37\.tmp-doc\p0-fix\win\docs\mtp-only-release-fixed-20261106\mass-storage\check-rg353ps-mass-storage.ps1"
```

If Windows offers to format the volume, stop and do not continue: the script
also refuses to proceed on a RAW/unknown filesystem or ambiguous ownership.
