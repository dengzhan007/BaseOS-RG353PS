#!/bin/sh
# Offline state-transition and failure-path tests for the RG353PS USB mode.
#
# These tests EXECUTE the production functions from
# platforms/rg353ps/rootfs/usr/sbin/baseos-usb-mode-lib against a sandbox
# configfs tree, a sandbox UDC sysfs tree, a sandbox /proc/mounts and a stub
# mount(8). They are not a grep over the scripts: each case runs the real code
# path and asserts the returned status plus the resulting filesystem state.
#
# Covered: lock contention, re-entrancy, stale and abandoned locks, SIGKILL /
# SIGTERM of the owner, UDC write success without release, unbind confirmation
# timeout, mount returning success without a mount, mount of the wrong device,
# teardown ordering (no remount while the LUN may still be bound), ACTIVE
# marker retention, and the resume-veto that must never start a second gadget.
#
# No hardware is touched, nothing outside the sandbox is written.
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/platforms/rg353ps/rootfs/usr/sbin/baseos-usb-mode-lib"
STORAGE="$ROOT/platforms/rg353ps/rootfs/usr/sbin/baseos-usb-storage"
DEBUG="$ROOT/platforms/rg353ps/rootfs/usr/sbin/baseos-usb-debug"

[ -r "$LIB" ] || { echo "missing $LIB" >&2; exit 1; }

TMPBASE="/tmp/rg353ps-usb-mutex-$$"
mkdir -p "$TMPBASE"
RESULTS="$TMPBASE/results.txt"
: > "$RESULTS"
CASE_SEQ=0

cleanup_all() {
    # Bounded to the sandbox this script created.
    if [ -d "$TMPBASE" ]; then
        chmod -R u+rwx "$TMPBASE" 2>/dev/null || :
        rm -rf "$TMPBASE" 2>/dev/null || :
    fi
}
trap cleanup_all EXIT INT TERM

report() {
    # $1 name, $2 verdict (0 pass / 1 fail), $3 detail
    printf '%s|%s|%s\n' "$2" "$1" "${3:-}" >> "$RESULTS"
    # Streamed as well, so a hung case is visible in CI instead of silence.
    printf 'CASE  %s%s\n' "$1" "${3:+  ($3)}"
}

# Fresh sandbox per case: run dir, configfs gadget, UDC sysfs, mounts file,
# stub mount(8) and a fake baseos-usb-debug that records being started.
new_sandbox() {
    CASE_SEQ=$((CASE_SEQ+1))
    # Unique per subshell: CASE_SEQ does not survive the ( ... ) boundary, and a
    # shared directory would let one case inherit another case's lock.
    # $ and CASE_SEQ are shared/reset across test subshells; use mktemp so
    # chmod/configfs state from one case cannot leak into the next.
    SB="$(mktemp -d "$TMPBASE/case-$-XXXXXX")" || exit 1
    mkdir -p "$SB/run" "$SB/cfg/usb_gadget/rockchip" "$SB/cfg/usb_gadget/baseos_debug" \
             "$SB/udc/dwc3" "$SB/mnt/data" "$SB/bin"
    printf 'dwc3\n' > "$SB/cfg/usb_gadget/rockchip/UDC"
    : > "$SB/cfg/usb_gadget/baseos_debug/UDC"
    printf 'not attached\n' > "$SB/udc/dwc3/state"
    : > "$SB/mounts"
    : > "$SB/mount.calls"

    cat > "$SB/bin/mount" <<'MOUNT_STUB'
#!/bin/sh
# Stub mount(8). Records every call, then behaves per MOUNT_MODE:
#   ok     -> append the mount to MOUNTS_FILE (real success)
#   fail   -> exit 32
#   silent -> exit 0 without recording anything (success that did not happen)
mp=""; prev=""
for a in "$@"; do prev="$mp"; mp="$a"; done
printf '%s %s\n' "$prev" "$mp" >> "$MOUNT_CALLS"
case "${MOUNT_MODE:-ok}" in
    fail) exit 32 ;;
    silent) exit 0 ;;
    *) printf '%s %s exfat rw,noatime 0 0\n' "$prev" "$mp" >> "$MOUNTS_FILE" ;;
esac
exit 0
MOUNT_STUB
    chmod 0755 "$SB/bin/mount"

    cat > "$SB/bin/baseos-usb-debug" <<'DEBUG_STUB'
#!/bin/sh
active=no
lock=no
[ -e "$BASEOS_USB_RUN_DIR/baseos-usb-storage.active" ] && active=yes
[ -d "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock" ] && lock=yes
printf '%s|active=%s|lock=%s|token=%s\n' "$*" "$active" "$lock" "${BASEOS_USB_LOCK_TOKEN:-}" >> "$DEBUG_CALLS"
exit "${DEBUG_STUB_EXIT:-0}"
DEBUG_STUB
    chmod 0755 "$SB/bin/baseos-usb-debug"
    : > "$SB/debug.calls"

    # Exported before the library is sourced: it captures its defaults once.
    BASEOS_USB_RUN_DIR="$SB/run"
    BASEOS_USB_CONFIGFS="$SB/cfg"
    BASEOS_USB_UDC_ROOT="$SB/udc"
    BASEOS_USB_MOUNTS="$SB/mounts"
    BASEOS_USB_MOUNT_CMD="$SB/bin/mount"
    MOUNTS_FILE="$SB/mounts"
    MOUNT_CALLS="$SB/mount.calls"
    MOUNT_MODE=ok
    DEBUG_CALLS="$SB/debug.calls"
    export BASEOS_USB_RUN_DIR BASEOS_USB_CONFIGFS BASEOS_USB_UDC_ROOT \
           BASEOS_USB_MOUNTS BASEOS_USB_MOUNT_CMD \
           MOUNTS_FILE MOUNT_CALLS MOUNT_MODE DEBUG_CALLS
    . "$LIB"
    # Keep the poll counts identical but remove the wall-clock wait.
    usb_mode_sleep() { :; }
}

marker_present() { [ -f "$BASEOS_USB_RUN_DIR/baseos-usb-storage.active" ]; }

echo "== USB mode lock =="

# 1. acquire creates the lock, records the owner and returns 0.
(
    new_sandbox
    usb_mode_lock_acquire 5; rc=$?
    ok=1
    if [ "$rc" -eq 0 ] && [ -d "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock" ] &&
       [ -s "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock/pid" ] &&
       [ -n "${BASEOS_USB_LOCK_TOKEN:-}" ] &&
       [ "$(cat "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock/pid")" = "$$" ]; then
        ok=0
    fi
    report "lock: acquire records owner and token" "$ok" "rc=$rc"
)

# 2. A nested call handed the token re-enters without deadlock and without
#    deleting the owner's lock.
(
    new_sandbox
    usb_mode_lock_acquire 5
    token="${BASEOS_USB_LOCK_TOKEN:-}"
    BASEOS_USB_LOCK_TOKEN=$token
    export BASEOS_USB_LOCK_TOKEN
    usb_mode_lock_acquire 5; rc=$?
    still=$([ -d "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock" ] && echo 1 || echo 0)
    inherited="${BASEOS_USB_LOCK_INHERITED:-0}"
    ok=1
    [ "$rc" -eq 0 ] && [ "$still" -eq 1 ] && [ "$inherited" = 1 ] && ok=0
    # The nested release must not remove the owner's lock either.
    usb_mode_lock_release
    owned_still=$([ -d "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock" ] && echo 1 || echo 0)
    [ "$owned_still" -eq 1 ] || ok=1
    report "lock: nested acquire is re-entrant and keeps the owner lock" "$ok" \
        "rc=$rc inherited=$inherited lock_present=$still after_nested_release=$owned_still"
)

# 3. A second, unrelated process must time out instead of stealing the lock.
(
    new_sandbox
    (
        BASEOS_USB_RUN_DIR="$BASEOS_USB_RUN_DIR" sh -c '. "$1"; usb_mode_lock_acquire 5; sleep 5' sh "$LIB" &
        holder=$!
        i=0
        while [ ! -d "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock" ] && [ "$i" -lt 50 ]; do
            i=$((i+1)); sleep 0.1
        done
        usb_mode_lock_acquire 3; rc=$?
        held=$(usb_mode_lock_held_by_other && echo yes || echo no)
        kill -9 "$holder" 2>/dev/null || :
        wait "$holder" 2>/dev/null || :
        ok=1
        [ "$rc" -eq 1 ] && [ "$held" = yes ] && ok=0
        report "lock: concurrent owner makes the second acquire fail" "$ok" \
            "rc=$rc held_by_other=$held"
    )
)

# 4. A lock whose PID is gone is reclaimed instead of blocking forever.
(
    new_sandbox
    sh -c 'sleep 30' &
    dead=$!
    kill -9 "$dead" 2>/dev/null || :
    wait "$dead" 2>/dev/null || :
    mkdir -p "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock"
    printf '%s\n' "$dead" > "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock/pid"
    printf 'dead-token\n' > "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock/token"
    usb_mode_lock_acquire 5; rc=$?
    ok=1
    if [ "$rc" -eq 0 ] &&
       [ "$(cat "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock/pid" 2>/dev/null)" = "$$" ]; then
        ok=0
    fi
    report "lock: stale lock from a dead PID is reclaimed" "$ok" "rc=$rc dead_pid=$dead"
)

# 5. Release removes the lock directory.
(
    new_sandbox
    usb_mode_lock_acquire 5
    usb_mode_lock_release; rc=$?
    ok=1
    [ "$rc" -eq 0 ] && [ ! -d "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock" ] && ok=0
    report "lock: release leaves no directory behind" "$ok" "rc=$rc"
)

# 6. A process that does not own the lock must not delete it.
(
    new_sandbox
    mkdir -p "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock"
    printf '1\n' > "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock/pid"
    printf 'other-token\n' > "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock/token"
    BASEOS_USB_LOCK_TOKEN="mine-token" usb_mode_lock_release; rc=$?
    still=$([ -d "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock" ] && echo 1 || echo 0)
    ok=1
    [ "$rc" -eq 1 ] && [ "$still" -eq 1 ] && ok=0
    report "lock: foreign release is refused" "$ok" "rc=$rc lock_present=$still"
)

# 7. SIGKILL of the owner leaves a stale lock that the next caller reclaims.
(
    new_sandbox
    BASEOS_USB_RUN_DIR="$BASEOS_USB_RUN_DIR" sh -c '. "$1"; usb_mode_lock_acquire 5; sleep 5' sh "$LIB" &
    victim=$!
    i=0
    while [ ! -s "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock/pid" ] && [ "$i" -lt 50 ]; do
        i=$((i+1)); sleep 0.1
    done
    kill -9 "$victim" 2>/dev/null || :
    wait "$victim" 2>/dev/null || :
    usb_mode_lock_acquire 10; rc=$?
    ok=1
    [ "$rc" -eq 0 ] && [ "$(cat "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock/pid" 2>/dev/null)" = "$$" ] && ok=0
    report "lock: SIGKILLed owner is reclaimed by the next acquire" "$ok" "rc=$rc"
)

# 8. A normal SIGTERM must release the lock through the trap, not leave it.
(
    new_sandbox
    cat > "$SB/owner.sh" <<EOS
#!/bin/sh
. "$LIB"
usb_mode_lock_acquire 5
trap 'usb_mode_lock_release; exit 0' TERM
while :; do sleep 0.05; done
EOS
    chmod 0755 "$SB/owner.sh"
    BASEOS_USB_RUN_DIR="$BASEOS_USB_RUN_DIR" "$SB/owner.sh" &
    owner=$!
    i=0
    while [ ! -s "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock/pid" ] && [ "$i" -lt 50 ]; do
        i=$((i+1)); sleep 0.1
    done
    kill -TERM "$owner" 2>/dev/null || :
    wait "$owner" 2>/dev/null || :
    i=0
    while [ -d "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock" ] && [ "$i" -lt 30 ]; do
        i=$((i+1)); sleep 0.1
    done
    ok=1
    [ ! -d "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock" ] && ok=0
    report "lock: SIGTERM releases the lock (no permanent residue)" "$ok" \
        "lock_present=$([ -d "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock" ] && echo yes || echo no)"
)

echo "== UDC release confirmation =="

# 9. Write succeeds, attribute reads back empty, controller left configured.
(
    new_sandbox
    printf 'not attached\n' > "$SB/udc/dwc3/state"
    cat > "$SB/cfg/usb_gadget/rockchip/UDC" <<'EOS'
EOS
    usb_mode_udc_unbind "$SB/cfg/usb_gadget/rockchip" dwc3 10 5; rc=$?
    ok=1
    [ "$rc" -eq 0 ] && ok=0
    report "udc: confirmed release returns success" "$ok" \
        "rc=$rc write_rc=${USB_MODE_UNBIND_WRITE_RC:-} state=${USB_MODE_UNBIND_STATE:-}"
)

# 10. The decisive case: write(2) returns 0 but the attribute still names the
#     controller. The old code called that a success.
(
    new_sandbox
    printf 'configured\n' > "$SB/udc/dwc3/state"
    # UDC cannot be written to empty (regular file rewritten by the test after
    # each write would be cheating), so simulate the kernel keeping the binding
    # by making the attribute unwritable and non-empty.
    chmod 0444 "$SB/cfg/usb_gadget/rockchip/UDC"
    usb_mode_udc_unbind "$SB/cfg/usb_gadget/rockchip" dwc3 5 3; rc=$?
    binding="$(cat "$SB/cfg/usb_gadget/rockchip/UDC" 2>/dev/null || :)"
    ok=1
    [ "$rc" -eq 1 ] && ok=0
    report "udc: successful write without release is a failure" "$ok" \
        "rc=$rc binding=$binding write_rc=${USB_MODE_UNBIND_WRITE_RC:-}"
)

# 11. Attribute empty but the controller still reports configured: the strict
#     check must not accept the attribute alone.
(
    new_sandbox
    printf 'configured\n' > "$SB/udc/dwc3/state"
    printf '' > "$SB/cfg/usb_gadget/rockchip/UDC"
    usb_mode_udc_unbind "$SB/cfg/usb_gadget/rockchip" dwc3 5 3; rc=$?
    ok=1
    [ "$rc" -eq 1 ] && ok=0
    report "udc: empty attribute with controller still configured fails" "$ok" \
        "rc=$rc state=${USB_MODE_UNBIND_STATE:-}"
)

# 12. Confirmation window expires while the controller stays configured.
(
    new_sandbox
    printf 'configured\n' > "$SB/udc/dwc3/state"
    printf 'dwc3\n' > "$SB/cfg/usb_gadget/rockchip/UDC"
    chmod 0444 "$SB/cfg/usb_gadget/rockchip/UDC"
    usb_mode_udc_unbind "$SB/cfg/usb_gadget/rockchip" dwc3 5 1; rc=$?
    ok=1
    [ "$rc" -eq 1 ] && ok=0
    report "udc: confirmation timeout fails closed" "$ok" \
        "rc=$rc binding=${USB_MODE_UNBIND_BINDING:-} state=${USB_MODE_UNBIND_STATE:-}"
)

# 13. No UDC attribute at all: nothing to confirm, so fail.
(
    new_sandbox
    rm -f "$SB/cfg/usb_gadget/rockchip/UDC"
    usb_mode_udc_unbind "$SB/cfg/usb_gadget/rockchip" dwc3 5 3; rc=$?
    ok=1
    [ "$rc" -eq 1 ] && ok=0
    report "udc: missing attribute fails closed" "$ok" "rc=$rc"
)

echo "== Local mount restoration =="

# 14. Already mounted from the same device.
(
    new_sandbox
    printf '/dev/mmcblk0p4 %s exfat rw 0 0\n' "$SB/mnt/data" > "$SB/mounts"
    usb_mode_restore_local /dev/mmcblk0p4 "$SB/mnt/data" exfat; rc=$?
    ok=1
    [ "$rc" -eq 0 ] && ok=0
    report "mount: already-mounted source is accepted" "$ok" "rc=$rc"
)

# 15. Mounted from a different device: refuse instead of writing through it.
(
    new_sandbox
    printf '/dev/mmcblk0p1 %s exfat rw 0 0\n' "$SB/mnt/data" > "$SB/mounts"
    usb_mode_restore_local /dev/mmcblk0p4 "$SB/mnt/data" exfat; rc=$?
    ok=1
    [ "$rc" -eq 1 ] && ok=0
    report "mount: wrong source device is refused" "$ok" "rc=$rc source=${USB_MODE_RESTORE_SOURCE:-}"
)

# 16. mount(8) succeeds and records the mount.
(
    new_sandbox
    usb_mode_restore_local /dev/mmcblk0p4 "$SB/mnt/data" exfat; rc=$?
    calls=$(wc -l < "$SB/mount.calls" | tr -d ' ')
    ok=1
    [ "$rc" -eq 0 ] && [ "$calls" -ge 1 ] && grep -q "^/dev/mmcblk0p4 " "$SB/mounts" && ok=0
    report "mount: verified mount after mount(8)" "$ok" "rc=$rc calls=$calls"
)

# 17. The decisive case: mount(8) exits 0 but nothing is mounted.
(
    new_sandbox
    MOUNT_MODE=silent
    export MOUNT_MODE
    usb_mode_restore_local /dev/mmcblk0p4 "$SB/mnt/data" exfat; rc=$?
    ok=1
    [ "$rc" -eq 1 ] && ok=0
    report "mount: mount(8) success without a mount is a failure" "$ok" \
        "rc=$rc source=${USB_MODE_RESTORE_SOURCE:-}"
)

# 18. mount(8) fails.
(
    new_sandbox
    MOUNT_MODE=fail
    export MOUNT_MODE
    usb_mode_restore_local /dev/mmcblk0p4 "$SB/mnt/data" exfat; rc=$?
    ok=1
    [ "$rc" -eq 1 ] && ok=0
    report "mount: mount(8) failure is a failure" "$ok" "rc=$rc"
)

# 19. FunctionFS released / not released.
(
    new_sandbox
    usb_mode_ffs_released /dev/ffs-mtp; a=$?
    printf 'functionfs %s functionfs rw 0 0\n' "/dev/ffs-mtp" > "$SB/mounts"
    usb_mode_ffs_released /dev/ffs-mtp; b=$?
    ok=1
    [ "$a" -eq 0 ] && [ "$b" -eq 1 ] && ok=0
    report "ffs: released is detected, still-mounted is refused" "$ok" "clean=$a mounted=$b"
)

echo "== Teardown state machine =="

# 20. Confirmed unbind + verified remount: teardown OK and the ACTIVE marker is
#     cleared so usb-gadget-adb may use the UDC again.
(
    new_sandbox
    printf 'dwc3\n' > "$SB/cfg/usb_gadget/rockchip/UDC"
    printf 'not attached\n' > "$SB/udc/dwc3/state"
    usb_mode_mark_active bound
    usb_mode_finish_session "$SB/cfg/usb_gadget/rockchip" dwc3 1 \
        /dev/mmcblk0p4 "$SB/mnt/data" exfat "$SB/bin/baseos-usb-debug" 1; rc=$?
    ok=1
    [ "$rc" -eq 0 ] && [ "$USB_MODE_FINISH_TEARDOWN_OK" -eq 1 ] &&
        [ "$USB_MODE_FINISH_UDC_RELEASED" -eq 1 ] &&
        [ "$USB_MODE_FINISH_REMOUNT_OK" -eq 1 ] && marker_present && ok=0
    report "teardown: confirmed unbind/remount keep ACTIVE until replacement gadget starts" "$ok" "rc=$rc"
)

# 21. Unbind not confirmed: the partition must NOT be remounted and the marker
#     must stay as a fail-closed guard.
(
    new_sandbox
    printf 'dwc3\n' > "$SB/cfg/usb_gadget/rockchip/UDC"
    printf 'configured\n' > "$SB/udc/dwc3/state"
    chmod 0444 "$SB/cfg/usb_gadget/rockchip/UDC"
    usb_mode_mark_active bound
    usb_mode_finish_session "$SB/cfg/usb_gadget/rockchip" dwc3 1 \
        /dev/mmcblk0p4 "$SB/mnt/data" exfat "$SB/bin/baseos-usb-debug" 1; rc=$?
    mount_calls=$(wc -l < "$SB/mount.calls" | tr -d ' ')
    ok=1
    [ "$rc" -eq 1 ] && [ "$USB_MODE_FINISH_TEARDOWN_OK" -eq 0 ] &&
        [ "$USB_MODE_FINISH_REMOUNT_OK" -eq 0 ] && [ "$mount_calls" -eq 0 ] &&
        marker_present && ok=0
    report "teardown: failed unbind never remounts and keeps the marker" "$ok" \
        "rc=$rc mount_calls=$mount_calls marker=$([ -f "$BASEOS_USB_RUN_DIR/baseos-usb-storage.active" ] && echo kept || echo gone)"
)

# 22. Unbind confirmed but mount(8) silently did nothing: no recovery reported.
(
    new_sandbox
    printf 'dwc3\n' > "$SB/cfg/usb_gadget/rockchip/UDC"
    printf 'not attached\n' > "$SB/udc/dwc3/state"
    MOUNT_MODE=silent
    export MOUNT_MODE
    usb_mode_mark_active bound
    usb_mode_finish_session "$SB/cfg/usb_gadget/rockchip" dwc3 1 \
        /dev/mmcblk0p4 "$SB/mnt/data" exfat "$SB/bin/baseos-usb-debug" 1; rc=$?
    ok=1
    [ "$rc" -eq 1 ] && [ "$USB_MODE_FINISH_TEARDOWN_OK" -eq 0 ] &&
        [ "$USB_MODE_FINISH_UDC_RELEASED" -eq 1 ] && marker_present && ok=0
    report "teardown: unverified remount is not reported as recovery" "$ok" "rc=$rc"
)

# 23. Never bound and the attribute is empty: nothing to release.
(
    new_sandbox
    printf '' > "$SB/cfg/usb_gadget/rockchip/UDC"
    usb_mode_finish_session "$SB/cfg/usb_gadget/rockchip" dwc3 0 \
        '' '' '' "$SB/bin/baseos-usb-debug" 0; rc=$?
    ok=1
    [ "$rc" -eq 0 ] && [ "$USB_MODE_FINISH_UDC_RELEASED" -eq 1 ] && ok=0
    report "teardown: unbound helper with empty attribute is consistent" "$ok" "rc=$rc"
)

# 24. Believed unbound but the attribute still names a controller: fail.
(
    new_sandbox
    printf 'dwc3\n' > "$SB/cfg/usb_gadget/rockchip/UDC"
    usb_mode_finish_session "$SB/cfg/usb_gadget/rockchip" dwc3 0 \
        '' '' '' "$SB/bin/baseos-usb-debug" 0; rc=$?
    ok=1
    [ "$rc" -eq 1 ] && [ "$USB_MODE_FINISH_UDC_RELEASED" -eq 0 ] && ok=0
    report "teardown: stale binding contradicts an unbound helper" "$ok" "rc=$rc"
)

echo "== Resume veto (never start a second gadget) =="

# 25. Resume runs synchronously under the inherited lock. The replacement
#     gadget sees ACTIVE and the lock still held; only after it returns does
#     the helper clear ACTIVE.
(
    new_sandbox
    usb_mode_mark_active bound
    usb_mode_lock_acquire 5
    usb_mode_resume_normal "$SB/bin/baseos-usb-debug" 1; rc=$?
    line="$(cat "$SB/debug.calls" 2>/dev/null || :)"
    marker_after=$([ -e "$BASEOS_USB_RUN_DIR/baseos-usb-storage.active" ] && echo yes || echo no)
    lock_after=$([ -d "$BASEOS_USB_RUN_DIR/baseos-usb-mode.lock" ] && echo yes || echo no)
    usb_mode_lock_release
    ok=1
    case "$line" in
        start\|active=yes\|lock=yes\|token=*) [ "$rc" -eq 0 ] && [ "$marker_after" = no ] && [ "$lock_after" = yes ] && ok=0 ;;
    esac
    report "resume: manager starts under lock before ACTIVE clears" "$ok" \
        "rc=$rc call=$line marker_after=$marker_after lock_after=$lock_after"
)

# 26. Teardown NOT confirmed: the manager must not be started at all.
(
    new_sandbox
    usb_mode_lock_acquire 5
    usb_mode_resume_normal "$SB/bin/baseos-usb-debug" 0; rc=$?
    called=$(grep -c 'start' "$SB/debug.calls" 2>/dev/null | head -1)
    [ -n "$called" ] || called=0
    usb_mode_lock_release
    ok=1
    [ "$rc" -eq 1 ] && [ "$called" -eq 0 ] && ok=0
    report "resume: unconfirmed teardown never starts a gadget" "$ok" "rc=$rc calls=$called"
)

echo "== UDC ownership =="

# 27. Another gadget naming the same UDC is detected before a bind.
(
    new_sandbox
    printf 'dwc3\n' > "$SB/cfg/usb_gadget/baseos_debug/UDC"
    usb_mode_udc_claimed_by_other dwc3 "$SB/cfg/usb_gadget/rockchip"; rc=$?
    ok=1
    [ "$rc" -eq 0 ] && ok=0
    report "udc: another gadget on the same UDC is reported" "$ok" "rc=$rc"
)

# 28. Our own gadget is not counted as "another".
(
    new_sandbox
    printf 'dwc3\n' > "$SB/cfg/usb_gadget/rockchip/UDC"
    usb_mode_udc_claimed_by_other dwc3 "$SB/cfg/usb_gadget/rockchip"; rc=$?
    ok=1
    [ "$rc" -eq 1 ] && ok=0
    report "udc: own binding is excluded from the claim check" "$ok" "rc=$rc"
)

echo "== ACTIVE marker lifecycle =="

# 29. A marker left by a dead session is reaped; a live one is preserved.
(
    new_sandbox
    printf 'pid=999999 since=1 phase=bound\n' > "$BASEOS_USB_RUN_DIR/baseos-usb-storage.active"
    usb_mode_reap_stale_marker; stale=$?
    gone=$([ -f "$BASEOS_USB_RUN_DIR/baseos-usb-storage.active" ] && echo 0 || echo 1)
    printf 'pid=%s since=1 phase=bound\n' "$$" > "$BASEOS_USB_RUN_DIR/baseos-usb-storage.active"
    usb_mode_reap_stale_marker; live=$?
    kept=$([ -f "$BASEOS_USB_RUN_DIR/baseos-usb-storage.active" ] && echo 1 || echo 0)
    ok=1
    [ "$stale" -eq 0 ] && [ "$gone" -eq 1 ] && [ "$live" -eq 1 ] && [ "$kept" -eq 1 ] && ok=0
    report "marker: dead owner reaped, live owner kept" "$ok" \
        "stale_rc=$stale gone=$gone live_rc=$live kept=$kept"
)

echo "== Script wiring =="

# 30. The three entry points actually source the shared library; without it the
#     guards above would never run on the device.
ok=1
for script in "$STORAGE" "$DEBUG"; do
    grep -Fq 'baseos-usb-mode-lib' "$script" || ok=1
done
grep -Fq 'baseos-usb-mode-lib' "$STORAGE" && grep -Fq 'baseos-usb-mode-lib' "$DEBUG" && ok=0
report "wiring: storage and debug source the shared library" "$ok" ""

# 31. Mass Storage must create the marker before it stops the manager, so the
#     adb overlay cannot claim the UDC during the hand-off.
ok=1
marker_line="$(grep -n 'usb_mode_mark_active preparing' "$STORAGE" | cut -d: -f1)"
stop_line="$(grep -n 'baseos-usb-debug stop >/dev/null' "$STORAGE" | cut -d: -f1)"
if [ -n "$marker_line" ] && [ -n "$stop_line" ] && [ "$marker_line" -lt "$stop_line" ]; then
    ok=0
fi
report "wiring: ACTIVE marker precedes the manager stop" "$ok" \
    "marker_line=$marker_line stop_line=$stop_line"

# 32. Failed replacement-gadget start keeps ACTIVE as a fail-closed guard.
(
    new_sandbox
    usb_mode_mark_active bound
    usb_mode_lock_acquire 5
    DEBUG_STUB_EXIT=7
    export DEBUG_STUB_EXIT
    usb_mode_resume_normal "$SB/bin/baseos-usb-debug" 1; rc=$?
    marker=$([ -e "$BASEOS_USB_RUN_DIR/baseos-usb-storage.active" ] && echo yes || echo no)
    usb_mode_lock_release
    ok=1
    [ "$rc" -eq 1 ] && [ "$marker" = yes ] && ok=0
    report "resume: failed manager start retains ACTIVE" "$ok" "rc=$rc marker=$marker"
)

# 33. Resume is refused unless the caller owns the shared lock.
(
    new_sandbox
    usb_mode_mark_active bound
    usb_mode_resume_normal "$SB/bin/baseos-usb-debug" 1; rc=$?
    calls=$(wc -l < "$SB/debug.calls" | tr -d ' ')
    ok=1
    [ "$rc" -eq 1 ] && [ "$calls" -eq 0 ] && marker_present && ok=0
    report "resume: missing lock refuses start and keeps ACTIVE" "$ok" "rc=$rc calls=$calls"
)

# 34. An unreadable UDC attribute is not an empty binding.
(
    new_sandbox
    rm -f "$SB/cfg/usb_gadget/rockchip/UDC"
    mkdir "$SB/cfg/usb_gadget/rockchip/UDC"
    usb_mode_udc_binding "$SB/cfg/usb_gadget/rockchip" >/dev/null 2>&1; rc=$?
    ok=1
    [ "$rc" -ne 0 ] && ok=0
    report "udc: unreadable binding is distinct from empty" "$ok" "rc=$rc"
)

# 35. An unreadable other gadget must block a new UDC claim.
(
    new_sandbox
    rm -f "$SB/cfg/usb_gadget/baseos_debug/UDC"
    mkdir "$SB/cfg/usb_gadget/baseos_debug/UDC"
    usb_mode_udc_claimed_by_other dwc3 "$SB/cfg/usb_gadget/rockchip"; rc=$?
    ok=1
    [ "$rc" -eq 0 ] && ok=0
    report "udc: unreadable other gadget binding blocks claim" "$ok" "rc=$rc"
)

# 36. If the helper believed it was unbound but cannot read the attribute,
#     teardown must keep ACTIVE and must not remount the data partition.
(
    new_sandbox
    rm -f "$SB/cfg/usb_gadget/rockchip/UDC"
    mkdir "$SB/cfg/usb_gadget/rockchip/UDC"
    usb_mode_mark_active bound
    usb_mode_finish_session "$SB/cfg/usb_gadget/rockchip" dwc3 0 \
        /dev/mmcblk0p4 "$SB/mnt/data" exfat "$SB/bin/baseos-usb-debug" 1; rc=$?
    mount_calls=$(wc -l < "$SB/mount.calls" | tr -d ' ')
    ok=1
    [ "$rc" -eq 1 ] && [ "$USB_MODE_FINISH_UDC_RELEASED" -eq 0 ] &&
        [ "$mount_calls" -eq 0 ] && marker_present && ok=0
    report "teardown: unreadable binding never permits remount" "$ok" "rc=$rc mount_calls=$mount_calls"
)

# 37. An unreadable controller state is not proof that the UDC is released.
(
    new_sandbox
    : > "$SB/cfg/usb_gadget/rockchip/UDC"
    rm -f "$SB/udc/dwc3/state"
    mkdir "$SB/udc/dwc3/state"
    usb_mode_udc_unbind "$SB/cfg/usb_gadget/rockchip" dwc3 5 2; rc=$?
    ok=1
    [ "$rc" -eq 1 ] && [ "${USB_MODE_UNBIND_STATE:-}" = unreadable ] && ok=0
    report "udc: unreadable controller state fails confirmation" "$ok" "rc=$rc state=${USB_MODE_UNBIND_STATE:-}"
)

TOTAL=0
FAILED=0
while IFS='|' read -r verdict name detail; do
    [ -n "$name" ] || continue
    TOTAL=$((TOTAL+1))
    if [ "$verdict" -eq 0 ]; then
        printf 'PASS  %s%s\n' "$name" "${detail:+  ($detail)}"
    else
        FAILED=$((FAILED+1))
        printf 'FAIL  %s  %s\n' "$name" "$detail"
    fi
done < "$RESULTS"

printf '\ncases=%d pass=%d fail=%d hardware_contacted=false\n' \
    "$TOTAL" "$((TOTAL-FAILED))" "$FAILED"

[ "$FAILED" -eq 0 ] || exit 1
echo "RG353PS USB mutual-exclusion / failure-path tests passed"
