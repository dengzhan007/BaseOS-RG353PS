#!/bin/sh
# Assemble the complete 2 GiB RG353PS BaseOS SD image.
# This writes a disk image file only; it never opens a physical block device.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
. "$REPO_ROOT/tools/common.sh"

WORK="${RG353PS_WORK:-$REPO_ROOT/work/rg353ps}"
KERNEL_OUT="$WORK/kernel/output"
KERNEL_META="$KERNEL_OUT/kernel-build.json"
ROOTFS="$WORK/rootfs"
UBOOT="$WORK/rg353ps-uboot.bin"
OUTPUT="$WORK/baseos-rg353ps.img"
# A/B layout. Every region that an update may write reserves twice the space it
# needs, and only one half is a partition at a time — the spare is deliberately
# left unallocated so no desktop offers to format it and no partition number
# shifts when the slots flip. See src/gptslot.c for the invariants this must
# satisfy: the regions tile forward from LBA 16384 and BASEOS_DATA starts
# exactly where the last spare ends.
#
# BASEOS_UBOOT is the exception: Rockchip's SPL loads u-boot.itb from a fixed
# sector, so that region has no second half and never moves.
UBOOT_START=16384
UBOOT_SECTORS=16384          # 8 MiB
BOOT_START=$((UBOOT_START + UBOOT_SECTORS))
BOOT_SECTORS=262144          # 128 MiB per half
ROOT_START=$((BOOT_START + BOOT_SECTORS * 2))
ROOT_SECTORS=1048576         # 512 MiB per half
DATA_START=$((ROOT_START + ROOT_SECTORS * 2))
TOTAL_SIZE=2G
ROOT_PARTUUID="d462d29a-c5ca-4a4f-90c1-8d9423dd3535"

for cmd in docker python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 1; }
done
[ -s "$UBOOT" ] || { echo "missing $UBOOT (run ./platforms/rg353ps/build-uboot.sh)" >&2; exit 1; }
[ -s "$KERNEL_OUT/Image" ] || { echo "missing kernel Image (run ./platforms/rg353ps/build-kernel.sh)" >&2; exit 1; }
[ -s "$KERNEL_OUT/rk3566-anbernic-rg353ps.dtb" ] || { echo "missing RG353PS Linux DTB" >&2; exit 1; }
[ -s "$KERNEL_META" ] || { echo "missing kernel metadata" >&2; exit 1; }
[ -x "$ROOTFS/usr/bin/busybox" ] || { echo "missing rootfs (run ./platforms/rg353ps/build-rootfs.sh)" >&2; exit 1; }

# Keep the boot partition's default splash identical to upstream BaseOS.
# rootfs/etc/baseos/bootlogo.bmp is only a legacy fallback and may carry a
# platform-specific/custom image; the canonical upstream artwork lives in
# the repository-level assets/bootlogo.bmp.
BASEOS_BOOTLOGO="$WORK/baseos-bootlogo.bmp"
[ -s "$REPO_ROOT/assets/bootlogo.bmp" ] || {
  echo "missing canonical BaseOS artwork: $REPO_ROOT/assets/bootlogo.bmp" >&2
  exit 1
}
mkdir -p "$WORK"
cp "$REPO_ROOT/assets/bootlogo.bmp" "$BASEOS_BOOTLOGO"
cmp -s "$REPO_ROOT/assets/bootlogo.bmp" "$BASEOS_BOOTLOGO" || {
  echo "failed to stage the canonical BaseOS boot logo" >&2
  exit 1
}

KREL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kernel_release"])' "$KERNEL_META")"
[ -d "$ROOTFS/lib/modules/$KREL" ] || { echo "rootfs has no matching modules for $KREL" >&2; exit 1; }

echo "== assembling RG353PS BaseOS image =="
mkdir -p "$WORK"
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$WORK":/work \
  -e IMG_UBOOT_START="$UBOOT_START" \
  -e IMG_UBOOT_SECTORS="$UBOOT_SECTORS" \
  -e IMG_BOOT_START="$BOOT_START" \
  -e IMG_BOOT_SECTORS="$BOOT_SECTORS" \
  -e IMG_ROOT_START="$ROOT_START" \
  -e IMG_ROOT_SECTORS="$ROOT_SECTORS" \
  -e IMG_DATA_START="$DATA_START" \
  -e TOTAL_SIZE="$TOTAL_SIZE" \
  -e ROOT_PARTUUID="$ROOT_PARTUUID" \
  -e DEBIAN_MIRROR="${DEBIAN_MIRROR:-}" \
  debian:bookworm-slim sh -euc '
    # Step clock. The image build is I/O and CPU spread over a container, and
    # when it drifts the question is always "which step"; a timestamp per phase
    # answers it without a profiler.
    T0=$(date +%s)
    ts() { echo "  [$(date +%H:%M:%S) +$(( $(date +%s) - T0 ))s] $*"; }
    ts "container start"
    export DEBIAN_FRONTEND=noninteractive
    if [ -n "${DEBIAN_MIRROR:-}" ]; then
      MIRROR="$DEBIAN_MIRROR"
      # The slim image ships no CA bundle, so an https mirror fails peer
      # verification before ca-certificates could ever be installed. Fall back
      # to http for the index fetch; apt still verifies package signatures, so
      # this does not weaken what gets installed.
      [ -e /etc/ssl/certs/ca-certificates.crt ] || MIRROR=$(echo "$MIRROR" | sed "s#^https://#http://#")
      sed -i "s#http://deb.debian.org/debian#${MIRROR}#g" /etc/apt/sources.list.d/debian.sources 2>/dev/null || \
      sed -i "s#http://deb.debian.org/debian#${MIRROR}#g" /etc/apt/sources.list 2>/dev/null
      echo "debian apt repositories now use mirror: ${MIRROR}"
    fi
    ts "apt update start"
    apt-get -qq update
    apt-get -qq install -y --no-install-recommends \
      gdisk dosfstools mtools e2fsprogs coreutils gzip util-linux
    ts "apt done"

    IMG=/work/baseos-rg353ps.img
    BOOTFS=/work/boot-fat.img
    ROOTFS_IMG=/work/rootfs-ext4.img
    rm -f "$IMG" "$BOOTFS" "$ROOTFS_IMG" "$IMG.gz" "$IMG.sha256"
    truncate -s "$TOTAL_SIZE" "$IMG"

    # Rockchip IDB/SPL begins at LBA 64 and the U-Boot FIT at absolute LBA
    # 16384, which is exactly where BASEOS_UBOOT starts. The SPL reads that FIT
    # from a fixed offset, so the region is written, never flipped.
    UBOOT_BYTES=$(stat -c %s /work/rg353ps-uboot.bin)
    UBOOT_LIMIT=$(( (IMG_UBOOT_START + IMG_UBOOT_SECTORS - 64) * 512 ))
    [ "$UBOOT_BYTES" -le "$UBOOT_LIMIT" ] || {
      echo "U-Boot image is larger than the region reserved for it" >&2
      exit 1
    }

    # Partitions are placed at explicit sectors, not packed: the gap behind
    # BASEOS_BOOT and BASEOS_ROOT is the inactive half an update writes into.
    # BASEOS_DATA stays blank in the image so first boot can extend it to the
    # physical card.
    sgdisk --clear \
      --new=1:${IMG_UBOOT_START}:+${IMG_UBOOT_SECTORS} --typecode=1:8300 --change-name=1:BASEOS_UBOOT \
      --new=2:${IMG_BOOT_START}:+${IMG_BOOT_SECTORS} --typecode=2:0700 --change-name=2:BASEOS_BOOT \
      --new=3:${IMG_ROOT_START}:+${IMG_ROOT_SECTORS} --typecode=3:8300 --change-name=3:BASEOS_ROOT \
      --new=4:${IMG_DATA_START}:0 --typecode=4:0700 --change-name=4:BASEOS \
      --partition-guid=3:"$ROOT_PARTUUID" \
      --attributes=2:set:2 \
      --attributes=2:set:62 --attributes=2:set:63 "$IMG"

    # The card is a console, not a two-volume USB disk. BASEOS_BOOT carries the
    # kernel and extlinux.conf and nothing a user needs to edit, so it is marked
    # hidden (bit 62) and no-automount (bit 63): Windows and macOS stop handing
    # it a drive letter, and only the user partition shows up. Linux mounts both
    # by PARTNAME and ignores these bits, so boot, the updater and BASEOS_ROOT
    # are unaffected. The user partition is named BASEOS to match upstream
    # BaseOS; every lookup still accepts the older BASEOS_DATA name.

    # This build boots through Standard Boot (CONFIG_BOOTCOMMAND="bootflow
    # scan -lb"), which walks every partition looking for extlinux.conf and
    # ignores GPT attributes. The legacy BIOS bootable bit is therefore not
    # what makes BASEOS_BOOT findable today, but it is still the flag every
    # partitioning tool, EFI loader and the older distro_bootcmd path treat as
    # authoritative. Setting it costs nothing and keeps the boot volume correct
    # if the scan method ever changes back.

    partition_value() {
      sgdisk --info="$1" "$IMG" | sed -n "s/^$2: *\\([0-9][0-9]*\\).*/\\1/p"
    }
    BOOT_START="$(partition_value 2 "First sector")"
    BOOT_END="$(partition_value 2 "Last sector")"
    ROOT_START="$(partition_value 3 "First sector")"
    ROOT_END="$(partition_value 3 "Last sector")"
    DATA_START="$(partition_value 4 "First sector")"
    DATA_END="$(partition_value 4 "Last sector")"
    [ -n "$BOOT_START" ] && [ -n "$ROOT_START" ] && [ -n "$DATA_START" ] || {
      echo "unable to read partition boundaries from sgdisk" >&2
      exit 1
    }
    BOOT_BYTES=$(( (BOOT_END - BOOT_START + 1) * 512 ))
    ROOT_BYTES=$(( (ROOT_END - ROOT_START + 1) * 512 ))

    # FAT boot partition follows the ROCKNIX Generic extlinux layout.
    ts "boot vfat start"
    truncate -s "$BOOT_BYTES" "$BOOTFS"
    mkfs.vfat -F 32 -n BASEOS_BOOT "$BOOTFS"
    mmd -i "$BOOTFS" ::/extlinux
    mmd -i "$BOOTFS" ::/device_trees
    mcopy -i "$BOOTFS" /work/kernel/output/Image ::/Image
    mcopy -i "$BOOTFS" /work/kernel/output/rk3566-anbernic-rg353ps.dtb ::/device_trees/rk3566-anbernic-rg353ps.dtb
    mcopy -o -i "$BOOTFS" /work/rootfs/etc/baseos.conf ::/baseos.conf
    # The canonical upstream BaseOS artwork is staged separately from the
    # rootfs fallback so RG353PS builds do not accidentally ship the legacy
    # platform-specific image as the active boot splash.
    mcopy -i "$BOOTFS" /work/baseos-bootlogo.bmp ::/bootlogo.bmp
    # Install the replaceable keyboard-free diagnostic task on the FAT boot partition.

    # `ro`, not `rw`. Nothing on this image writes to the root filesystem: the
    # slots are written as raw regions by the updater, state lives on BASEOS and
    # everything else a boot writes goes to tmpfs (see the top of rcS). Mounting
    # it read-only is what removes the ext4 journal replay from every boot - the
    # journal is only dirty because the previous boot never unmounted, and the
    # replay alone measured 2.8 s of a 4.2 s kernel-side handoff. It also means a
    # yanked card or a dead battery cannot corrupt it.
    cat > /tmp/extlinux.conf <<EOF
LABEL BaseOS-RG353PS
  MENU LABEL BaseOS RG353PS
  LINUX /Image
  FDT /device_trees/rk3566-anbernic-rg353ps.dtb
  APPEND root=PARTUUID=$ROOT_PARTUUID rootfstype=ext4 rootwait ro console=ttyS2,1500000n8 quiet loglevel=3 vt.global_cursor_default=0 init=/sbin/init
EOF
    mcopy -i "$BOOTFS" /tmp/extlinux.conf ::/extlinux/extlinux.conf

    # Create ext4 directly from the staged root directory; partition 2 has a
    # fixed size so the remaining partition can be used for persistent userdata.
    # The journal is capped at 4 MiB. It is never replayed on a normal boot now
    # that the kernel mounts this read-only, but JBD2 walks the entire journal in
    # single 4 KiB reads when it does replay, so the size is what a dirty mount
    # would cost: 16 MiB of default journal was 2.8 s.
    truncate -s "$ROOT_BYTES" "$ROOTFS_IMG"
    ts "rootfs ext4 start"
    mkfs.ext4 -F -L BASEOS_ROOT -J size=4 -d /work/rootfs "$ROOTFS_IMG"
    ts "rootfs ext4 done"

    # The combined bootloader is a raw region, never a full disk image. Place it
    # at LBA 64, then write filesystems into their GPT partition extents.
    #
    # bs=1M with oflag=seek_bytes, not bs=512 seek=<sector>: writing the 512 MiB
    # rootfs in 512-byte blocks is a million write() calls, and on the
    # Windows-backed mount this repository lives on each one crosses to the host
    # — 340 s against 5 s for the same 512 MiB. Offsets stay in bytes so the
    # partition starts do not have to be MiB-aligned.
    ts "dd start"
    dd if=/work/rg353ps-uboot.bin of="$IMG" bs=1M oflag=seek_bytes \
      seek=$((64 * 512)) conv=notrunc status=none
    dd if="$BOOTFS" of="$IMG" bs=1M oflag=seek_bytes \
      seek=$((BOOT_START * 512)) conv=notrunc status=none
    dd if="$ROOTFS_IMG" of="$IMG" bs=1M oflag=seek_bytes \
      seek=$((ROOT_START * 512)) conv=notrunc status=none
    sync
    ts "dd done"

    sgdisk --verify "$IMG"
    echo "Partition layout:"
    sgdisk --print "$IMG"
    cat > /work/image-build.json <<EOF
{
  "target": "Anbernic RG353PS",
  "image": "baseos-rg353ps.img.gz",
  "disk_size": "2 GiB",
  "bootloader_lba": 64,
  "uboot_partition_start_lba": "${IMG_UBOOT_START}",
  "boot_partition_start_lba": "$BOOT_START",
  "root_partition_start_lba": "$ROOT_START",
  "root_partition_guid": "$ROOT_PARTUUID",
  "ab_regions": "boot,rootfs",
  "ab_note": "uboot is loaded from a fixed sector by the SPL and has no spare half",
  "user_data_partition_number": 4,
  "user_data_partition_start_lba": "$DATA_START",
  "user_data_partition_initial_end_lba": "$DATA_END",
  "user_data_filesystem": "exFAT, initialized and expanded on first boot",
  "purpose": "RG353PS BaseOS system image",
  "frontend_model": "external; discovered from TF2 then TF1",
  "diagnostic_ui": true,
  "hardware_tested": false
}
EOF
    ts "gzip start"
    gzip -1 -c "$IMG" > "$IMG.gz"
    cd /work
    sha256sum "$(basename "$IMG")" "$(basename "$IMG.gz")" > "$(basename "$IMG").sha256"
    ts "gzip done"
    echo "Created RG353PS BaseOS SD-card image:"
    ls -lh "$IMG" "$IMG.gz" "$IMG.sha256" /work/image-build.json
  '

echo "BaseOS image: $OUTPUT.gz"
echo "Checksum file: $OUTPUT.sha256"
echo "Use a spare SD card for installation; install a supported frontend separately."
