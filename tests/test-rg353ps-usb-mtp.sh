#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
USB="$ROOT/platforms/rg353ps"

sh -n "$USB/rootfs/usr/sbin/baseos-usb-debug"
sh -n "$USB/rootfs/usr/sbin/baseos-usb-mtp"
sh -n "$USB/rootfs/etc/init.d/rcS"
sh -n "$USB/build-rootfs.sh"

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

echo "RG353PS USB MTP static checks passed"
