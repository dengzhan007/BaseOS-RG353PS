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
grep -Fq 'storage "/mnt/SDCARD" "RG353PS" "rw"' "$USB/rootfs/etc/umtprd/umtprd.conf"
if grep -Eq '^storage "/"|^storage "/mnt"|^storage "/mnt/boot"' "$USB/rootfs/etc/umtprd/umtprd.conf"; then
    echo "MTP config exposes a path broader than /mnt/SDCARD" >&2
    exit 1
fi
grep -Fq '/usr/sbin/baseos-usb-mtp start' "$USB/rootfs/usr/sbin/baseos-usb-debug"
grep -Fq '/usr/sbin/baseos-usb-mtp stop' "$USB/rootfs/usr/sbin/baseos-usb-debug"
grep -Fq 'BASEOS_USB_PROFILE' "$USB/build-rootfs.sh"
grep -Fq 'BASEOS_USB_PROFILE="$profile"' "$ROOT/.github/workflows/rg353ps-release.yml"

echo "RG353PS USB MTP static checks passed"
