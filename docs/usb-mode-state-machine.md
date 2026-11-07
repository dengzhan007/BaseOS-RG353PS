# RG353PS USB mode state machine

Three programs drive one dwc3 UDC:

| Program | configfs gadget | `idProduct` | Owns |
| --- | --- | --- | --- |
| `baseos-usb-storage` | `usb_gadget/rockchip` | `0x0006` | the UDC, the raw data partition |
| `baseos-usb-debug` | `usb_gadget/baseos_debug` | `0x0007/0x0008/0x0009` | the UDC, network + FunctionFS |
| `baseos-usb-mtp` | (FunctionFS) | - | `/dev/ffs-mtp`, the `/mnt/SDCARD` tree |

Before this change each program wrote the UDC attribute directly and trusted
`write(2)` to report success. Two of them could be started at once (rcS starts
the manager, the hotkey daemon and the diagnostic UI both fork the storage
helper), the storage teardown remounted the data partition without proving the
LUN was released, and it started the normal gadget even when the teardown had
failed. `usb_mode_finish_session()` also now owns the exit ordering, so the
tests execute the same code the device runs.

## States

```
                  acquire lock
IDLE -----------------------------> CLAIMED (ACTIVE marker written)
                                        |
                     debug stop confirmed (UDC empty, state != configured)
                                        v
                                   MSC_READY (LUN bound to the partition)
                                        |
                cable pulled / error / timeout -> TEARDOWN
                                        v
                             unbind + confirm UDC released
                                        |
                     confirm /proc/mounts: mp backed by DEVICE
                                        |
                     both confirmed -> keep ACTIVE + lock -> debug start
                                        -> clear ACTIVE -> release lock
                     either failed  -> keep ACTIVE, keep debug down
```

## Invariants and where they are enforced

| Invariant | Mechanism |
| --- | --- |
| One UDC, one gadget | shared lock on storage and debug manager; foreign Gadget ownership re-checked immediately before the storage bind |
| No partition unmount while FunctionFS is alive | `do_stop`: unbind, `baseos-usb-mtp stop`, then `usb_mode_ffs_released`; failure refuses the hand-off |
| No local mount while the LUN is bound | `usb_mode_finish_session` only reaches the remount step after a confirmed UDC release |
| No remount before the UDC is confirmed free | same ordering; the remount block is unreachable on `UDC_RELEASED=0` |
| No MTP against an unmounted partition | `preflight_start` disables MTP (and refuses to start when MTP is the only function) if `/mnt/SDCARD` is not in `/proc/mounts` |
| Never report recovery that did not happen | remount counts only when `/proc/mounts` names the expected device; `mount(8)` exit 0 alone is not enough |
| Unknown state stays closed | `UDC_RELEASED=0` / `REMOUNT_OK=0` keep the ACTIVE marker, skip the manager start, and print `USB STORAGE FAILED` |
| UDC attribute/state unreadable | Read failure is distinct from an empty value; a possible foreign binding blocks a new claim, and teardown never remounts on an unreadable binding/state |

## Lock semantics

- Directory lock under `/run/baseos-usb-mode.lock`, created with `mkdir` (one
  atomic winner).
- The owner writes `pid`, `token`, `owner` and `since`.
- A nested call receives the token through `BASEOS_USB_LOCK_TOKEN`, re-enters
  immediately, and marks itself inherited, so it can never delete the owner's
  lock. This is what keeps `storage -> debug stop -> debug start` from
  deadlocking or orphaning the lock.
- A lock whose PID is gone is reclaimed, at most five times per acquire; if the
  directory still survives, the acquire gives up instead of spinning.
- `trap ... EXIT` in both programs releases the lock on every exit path,
  including `exit 1` inside `do_start`/`do_stop`. The ACTIVE marker is separate
  from the lock: a marker whose PID is gone is reaped by the next storage start
  or by `preflight_start`, so `usb-gadget-adb` cannot be locked out forever.

## Failure policy

| Failure | Result |
| --- | --- |
| UDC write returns 0 but the attribute still names the controller | treated as NOT released |
| Attribute empty but controller still `configured`/`suspended` | treated as NOT released |
| Confirmation window expires | treated as NOT released |
| `mount(8)` returns 0 without a `/proc/mounts` entry | treated as NOT mounted |
| Partition already mounted from a different device | refused, no write-through |
| FunctionFS still mounted after `umtprd` exits | hand-off refused |

## Test mapping

`tests/test-rg353ps-usb-mutual-exclusion.sh` executes these functions against a
sandbox configfs/UDC/mounts and asserts the results (36 cases, no hardware):

| Area | Cases |
| --- | --- |
| Lock | acquire/release, re-entrancy, contention, stale PID, SIGKILL, SIGTERM |
| UDC release | confirmed, write-ok-but-bound, empty-but-configured, timeout, missing, unreadable attribute/state and foreign binding |
| Remount | already mounted, wrong source, verified, silent success, mount error |
| Teardown | confirmed unbind/remount keep ACTIVE until replacement gadget starts under the same lock; failed unbind never remounts |
| Resume | synchronous start under lock, failed/unlocked start retains marker |
| Marker | dead owner reaped, live owner kept |
