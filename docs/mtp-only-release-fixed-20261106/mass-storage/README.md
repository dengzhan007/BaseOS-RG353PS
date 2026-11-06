# RG353PS Mass Storage host acceptance (preparation only)

These files prepare the **next** hardware acceptance step. They have NOT been
run against a real Mass Storage session yet. Entering Mass Storage mode is a
manual operator action; this directory only contains host-side checks.

## Files

| File | Purpose |
| --- | --- |
| `check-rg353ps-mass-storage.ps1` | Windows host, read-only verification |
| `Rg353psDeviceMap.ps1` | Injectable pure resolver: strict device identity mapping |
| `test-rg353ps-mass-storage-device-map.ps1` | Offline tests for the resolver |
| `offline-test-results.json` | Raw offline test results |
| `mass-storage-host-report.json` / `.md` | Produced only when the host check is run |

## Strict device identity (no fallback scanning)

The host check must prove that the volume it reads belongs to the RG353PS in
Mass Storage mode. It uses the single chain:

```
USB\VID_2207&PID_0006 (unique composite root)
  -> PnP children (DEVPKEY_Device_Children / USBSTOR)
  -> Win32_DiskDrive (exactly one matching disk)
  -> Win32_DiskDriveToDiskPartition (all partitions of THAT disk)
  -> Win32_LogicalDiskToPartition + Win32_Volume (exactly one accessible volume)
```

Hard-FAIL conditions: zero or multiple PID_0006 roots, no PnP children,
child-to-disk mapping that is not unique, a disk that is not USB/USBSTOR,
no partitions, a RAW/unknown filesystem on **any** partition of that disk
(including partitions without a drive letter), zero or multiple accessible
exFAT/FAT32 volumes, or non-unique volume metadata. There is deliberately no
"scan all USB disks" and no "scan all exFAT volumes" fallback.

## Read-only safeguards

- Only metadata reads and `Get-FileHash`; no writes to the device.
- No disk initialisation, no volume formatting, no repair utility, no
  partition/drive-letter changes, no deletion, no SSH.
- A Windows format prompt is a hard stop, but it is **only one layer**: the
  structural guards above (strict mapping + RAW/unknown filesystem detection)
  stop the script before any volume is accessed at all.
- Partitions without a drive letter are still enumerated and checked, so an
  anomaly cannot hide behind a missing letter.
- The 7-file dataset (`baseos-mtp-test-<run_id>`) and its device-produced
  manifest are read only from the uniquely mapped volume.

## Offline tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-rg353ps-mass-storage-device-map.ps1
```

Cases cover: correct device, another USB hard disk, multiple USB disks,
two PID_0006 roots, ambiguous child-to-disk mapping, RAW / unknown filesystem,
no-drive-letter partitions, missing PnP children, unmappable disk, missing
partitions, multiple accessible volumes, duplicate volume metadata, and a
non-USB mapped disk. Every case asserts that the other USB disk is never
selected. Results: `offline-test-results.json`.

## Real-hardware command (NOT run yet)

First, manually put the RG353PS into USB Mass Storage mode and wait for
Windows to enumerate `VID_2207&PID_0006`. Then:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "F:\workspace\2026-10-28-22-11-37\.tmp-doc\p0-fix\win\docs\mtp-only-release-fixed-20261106\mass-storage\check-rg353ps-mass-storage.ps1"
```

If Windows offers to format the volume, stop and do not continue: the script
will itself refuse to proceed on a RAW/unknown filesystem.
