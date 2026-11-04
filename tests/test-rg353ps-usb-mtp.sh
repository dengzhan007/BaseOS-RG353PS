#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
USB="$ROOT/platforms/rg353ps"

sh -n "$USB/rootfs/usr/sbin/baseos-usb-debug"
sh -n "$USB/rootfs/usr/sbin/baseos-usb-mtp"
sh -n "$USB/rootfs/etc/init.d/rcS"
sh -n "$USB/build-rootfs.sh"

# build-rootfs.sh sends a nested Alpine script as one single-quoted argument.
# Parse that inner script too; outer sh -n cannot detect quote damage.
python3 - "$USB/build-rootfs.sh" <<'PY'
from pathlib import Path
import subprocess
import sys

source = Path(sys.argv[1]).read_text()
begin_marker = "alpine:3.22 sh -euc '"
begin = source.find(begin_marker)
if begin < 0:
    raise SystemExit("could not find Alpine rootfs command")
body_start = begin + len(begin_marker)
if source[body_start:body_start + 1] != "\n":
    raise SystemExit("Alpine rootfs script is not on the expected next line")
end_marker = "\n  '\n\nfor file in "
end = source.find(end_marker, body_start)
if end < 0:
    raise SystemExit("could not find end of Alpine rootfs script")
body = source[body_start + 1:end]
if "'" in body:
    raise SystemExit("single quote found inside Docker single-quoted script")
result = subprocess.run(["sh", "-n"], input=body, text=True, capture_output=True)
if result.returncode:
    sys.stderr.write(result.stderr)
    raise SystemExit("embedded Alpine rootfs script has invalid shell syntax")
print("Embedded Alpine rootfs script syntax passed")
PY

grep -q '^CONFIG_USB_F_FS=y$' "$USB/kernel/config/linux.aarch64.conf"
grep -q '^CONFIG_USB_CONFIGFS_F_FS=y$' "$USB/kernel/config/linux.aarch64.conf"
grep -q '^usb_debug=yes$' "$USB/rootfs/etc/baseos.conf"
grep -q '^usb_mtp=yes$' "$USB/rootfs/etc/baseos.conf"
grep -Fqx 'storage "/mnt/SDCARD" "RG353PS" "rw"' "$USB/rootfs/etc/umtprd/umtprd.conf"
storage_count="$(grep -c '^storage ' "$USB/rootfs/etc/umtprd/umtprd.conf")"
[ "$storage_count" -eq 1 ] || {
    echo "MTP config must expose exactly one storage entry" >&2
    exit 1
}
grep -Fq '/usr/sbin/baseos-usb-mtp start' "$USB/rootfs/usr/sbin/baseos-usb-debug"
grep -Fq '/usr/sbin/baseos-usb-mtp stop' "$USB/rootfs/usr/sbin/baseos-usb-debug"
grep -Fq 'refusing Mass Storage hand-off' "$USB/rootfs/usr/sbin/baseos-usb-debug"
stop_line="$(grep -n 'releasing the normal USB gadget' "$USB/rootfs/usr/sbin/baseos-usb-storage" | cut -d: -f1)"
unmount_line="$(grep -n '^umount_msg=' "$USB/rootfs/usr/sbin/baseos-usb-storage" | cut -d: -f1)"
[ -n "$stop_line" ] && [ -n "$unmount_line" ] && [ "$stop_line" -lt "$unmount_line" ] || {
    echo "Mass Storage must stop MTP before unmounting the user-data volume" >&2
    exit 1
}
grep -Fq 'BASEOS_USB_PROFILE' "$USB/build-rootfs.sh"
grep -Fq 'BASEOS_USB_PROFILE="$profile"' "$ROOT/.github/workflows/rg353ps-release.yml"

# Reconnect supervisor: sub-second sampling, short fault confirmation, and
# asynchronous recovery so driver re-probes cannot block cable detection.
grep -Fq 'sleep 0.5' "$USB/rootfs/usr/sbin/baseos-usb-debug"
grep -Fq '[ $((tick - stuck_since)) -ge 4 ]' "$USB/rootfs/usr/sbin/baseos-usb-debug"
grep -Fq 'RECOVERY_LOCK=/run/baseos-usb-debug.recovery.lock' "$USB/rootfs/usr/sbin/baseos-usb-debug"
grep -Fq 'refusing controller hand-off' "$USB/rootfs/usr/sbin/baseos-usb-debug"

echo "RG353PS USB MTP static checks passed"
