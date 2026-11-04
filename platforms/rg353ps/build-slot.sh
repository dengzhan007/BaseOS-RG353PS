#!/bin/sh
# Build the Slot-6 frontend-only bring-up bundle for RG353PS.
# No libretro cores are built or packaged in this first milestone.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
. "$REPO_ROOT/tools/common.sh"

WORK="${RG353PS_WORK:-$REPO_ROOT/work/rg353ps}"
OUT="$WORK/frontends"
SLOT_BUILD_IMAGE="${SLOT_BUILD_IMAGE:-rg353ps-slot-build:latest}"
mkdir -p "$OUT"

# Pin the exact source snapshot audited for this port. SLOT_SRC can point at an
# already checked-out private repository when the build host has no GitHub auth.
SLOT_REPO="${SLOT_REPO:-dengzhan007/slot-6}"
SLOT_REV="${SLOT_REV:-acc4e91708cc21abf2321a3af279aae1b2f26d47}"

for cmd in docker git; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 1; }
done

SRC_HOST="${SLOT_SRC:-$WORK/slot6-src}"
if [ -z "${SLOT_SRC:-}" ]; then
  if [ "${SLOT_REFRESH:-}" = 1 ] || [ ! -d "$SRC_HOST/.git" ]; then
    rm -rf "$SRC_HOST"
    git clone "https://github.com/$SLOT_REPO.git" "$SRC_HOST"
  fi
  git -C "$SRC_HOST" fetch origin "$SLOT_REV"
  git -C "$SRC_HOST" checkout --detach "$SLOT_REV"
else
  git -C "$SRC_HOST" rev-parse --verify "$SLOT_REV^{commit}" >/dev/null
  git -C "$SRC_HOST" checkout --detach "$SLOT_REV"
fi

baseos_require_aarch64
if ! docker image inspect "$SLOT_BUILD_IMAGE" >/dev/null 2>&1; then
  echo "== preparing Slot-6 AArch64 musl build image =="
  docker build --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
    -f "$HERE/frontends/slot/Dockerfile.slot-build" \
    -t "$SLOT_BUILD_IMAGE" "$REPO_ROOT"
fi

echo "== building Slot-6 RG353PS frontend-only bundle =="
echo "   source: $SLOT_REPO @ $SLOT_REV"
docker run --rm --network host --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
  -v "$HERE/frontends/slot":/slot-port:ro \
  -v "$OUT":/out \
  -v rg353ps-slot-cargo:/usr/local/cargo \
  -v rg353ps-slot-target:/cargo-target \
  -v "$SRC_HOST":/slot-up:ro \
  -e SLOT_REV="$SLOT_REV" \
  "$SLOT_BUILD_IMAGE" sh -euc '
    export RUSTFLAGS="-C target-feature=-crt-static"
    export CARGO_HOME=/usr/local/cargo
    if [ -n "'"${SLOT_TOOLCHAIN:-}"'" ]; then
      export RUSTUP_TOOLCHAIN="'"${SLOT_TOOLCHAIN:-}"'"
    fi

    SRC=/tmp/slot6-src
    TARGET=/cargo-target
    PKG=/out/baseos-rg353ps-slot
    rm -rf "$SRC" "$PKG"
    mkdir -p "$SRC"
    cp -R /slot-up/. "$SRC/"

    # The actual Cargo workspace is nested one level below the repository root.
    WORKSPACE="$SRC/slot-main-640"
    test -f "$WORKSPACE/Cargo.toml"
    cp /slot-port/fbdev.rs "$WORKSPACE/crates/slot-gfx/src/fbdev.rs"

    # These are deliberately the only device-specific source changes in milestone 1:
    # physical keys, RG353PS 640x480 bootlogo validation, and the BaseOS ALSA route.
    for p in /slot-port/slot6-rg353ps-buttons.patch \
             /slot-port/slot6-bootlogo-640.patch \
             /slot-port/slot6-audio-default.patch; do
      echo "checking $(basename "$p")"
      git -C "$SRC" apply --check "$p"
      git -C "$SRC" apply "$p"
    done

    cd "$WORKSPACE"
    cargo build --release --target-dir "$TARGET" -p slot \
      --no-default-features --features device
    BIN="$TARGET/release/slot"
    test -x "$BIN"
    readelf -l "$BIN" | grep -q "ld-musl-aarch64.so.1" || {
      echo "Slot executable is not dynamically linked for the BaseOS musl rootfs" >&2
      exit 1
    }

    mkdir -p "$PKG/System/licenses" "$PKG/.baseos/frontends/slot" \
             "$PKG/baseos/frontends/slot"
    cp "$BIN" "$PKG/System/slot"
    cp /slot-port/launch.sh "$PKG/.baseos/frontends/slot/launch.sh"
    cp /slot-port/launch.sh "$PKG/baseos/frontends/slot/launch.sh"
    chmod 0755 "$PKG/System/slot" "$PKG/.baseos/frontends/slot/launch.sh" \
               "$PKG/baseos/frontends/slot/launch.sh"
    cp "$WORKSPACE/LICENSE" "$PKG/System/licenses/slot-6-LICENSE.txt"
    tar --exclude=.git -czf "$PKG/System/licenses/slot-6-$SLOT_REV-source.tar.gz" \
      -C "$SRC" slot-main-640

    # Create the card-side directory layout. This does not install emulator cores.
    "$PKG/System/slot" --init-root "$PKG"

    cat > "$PKG/README-RG353PS.txt" <<EOF
BaseOS RG353PS Slot-6 frontend bring-up
======================================

This is a frontend-only first-boot package. It contains the Slot executable
and its BaseOS adapter, but intentionally does not include libretro emulator
cores, BIOS files, game assets, theme packs or screen overlays.

Extract the ZIP to the root of TF2 for priority use, or to the root of TF1
BASEOS user partition for fallback use. BaseOS keeps its existing Wi-Fi,
Bluetooth, RK817 audio, volume and power-key services.

The target panel is 640x480. User boot logos must be uncompressed 24-bit BMP,
640x480, named .bmp, and are selected from Bootlogos/ on the user partition.
The active boot image is stored on BASEOS_BOOT (/mnt/boot).

This build has not yet been validated on physical RG353PS hardware.
Keep the original system card and back up saves before testing.
EOF
    chmod 0644 "$PKG/README-RG353PS.txt"

    cd "$PKG"
    rm -f /out/baseos-rg353ps-slot.zip
    zip -qry /out/baseos-rg353ps-slot.zip .
    ( cd /out && sha256sum baseos-rg353ps-slot.zip > baseos-rg353ps-slot.zip.sha256 )
    ls -lh /out/baseos-rg353ps-slot.zip /out/baseos-rg353ps-slot.zip.sha256
  '

echo "Slot bundle: $OUT/baseos-rg353ps-slot.zip"
echo "Checksum:    $OUT/baseos-rg353ps-slot.zip.sha256"
