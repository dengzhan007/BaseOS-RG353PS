#!/bin/sh
# Build the RG353PS `.bosupd` payload from the composed image.
#
# The payload carries the boot and rootfs slots, each gzipped whole, plus a
# manifest. Applying it writes those exact bytes into the inactive half of each
# region and flips the GPT, so an updated card ends up byte-identical to a
# freshly flashed one — ROMs, saves and settings are never touched.
#
# uboot is deliberately not a region: Rockchip's SPL loads u-boot.itb from a
# fixed sector, so there is no second half to write. Upgrading the loader itself
# still needs a reflash (see docs/07 in the upstream repository).
#
# Usage: ./platforms/rg353ps/build-update.sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
. "$REPO_ROOT/tools/common.sh"

WORK="${RG353PS_WORK:-$REPO_ROOT/work/rg353ps}"
IMAGE="$WORK/baseos-rg353ps-smoke.img"
[ -f "$IMAGE" ] || { echo "missing $IMAGE (run ./platforms/rg353ps/build-image.sh)" >&2; exit 1; }

VERSION="$(tr -d ' \n' < "$REPO_ROOT/VERSION")"
[ -n "$VERSION" ] || { echo "VERSION is empty" >&2; exit 1; }
# Stamped into the rootfs by build-rootfs.sh; the manifest must carry the same
# value or every boot would decide the card still disagrees with itself.
BUILD="$(cat "$WORK/build-id" 2>/dev/null)" || { echo "missing $WORK/build-id (run build-rootfs.sh)" >&2; exit 1; }
OUT="$WORK/baseos-rg353ps-$VERSION.bosupd"

python3 "$REPO_ROOT/tools/mkupdate.py" "$IMAGE" rg353ps "$VERSION" "$BUILD" "$OUT" \
  --regions boot=BASEOS_BOOT,rootfs=BASEOS_ROOT \
  --data-partition BASEOS

echo
echo "Copy $(basename "$OUT") to the root of either card volume and power on."
