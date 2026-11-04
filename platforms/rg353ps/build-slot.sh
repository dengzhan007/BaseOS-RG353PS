#!/bin/sh
# Build an experimental Slot frontend bundle for RG353PS (SDL2/KMSDRM + Mesa/Panfrost).
# The output is a ZIP for the frontend SD card; it does not modify the OS image.
#
# Quick fork porting: only three inputs are fork-specific -
#   SLOT_REPO / SLOT_REV   -> which Slot fork + commit to build
#   platforms/rg353ps/frontends/slot/slot-rg353ps.patch -> input mapping (per DTS)
#   platforms/rg353ps/frontends/slot/slot-analog.patch  -> stick support (fork-agnostic)
#   platforms/rg353ps/frontends/slot/slot-power.patch   -> frontend-owned power key
#   platforms/rg353ps/frontends/slot/slot-bootlogo.patch -> logo written to this
#                                                          port's boot partition
# Everything else (fbdev.rs display backend, launch.sh, cores) is reused as-is.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
. "$REPO_ROOT/tools/common.sh"

WORK="${RG353PS_WORK:-$REPO_ROOT/work/rg353ps}"
OUT="$WORK/frontends"
mkdir -p "$OUT"

# ---- configurable forks / pins (override per fork here) ----
SLOT_REPO="${SLOT_REPO:-BrandonKowalski/slot}"
# ab518c6 is the commit the two patches in frontends/slot were generated against.
# Moving this pin means regenerating both patches (git apply --check will tell you).
SLOT_REV="${SLOT_REV:-ab518c6}"
MGBA_REV="${MGBA_REV:-e31759b24e7a4e3899285ff720d7b573ac328ae7}"
GPSP_REV="${GPSP_REV:-7b2dd37394e2822110cacef321e9bb291a305b77}"

for cmd in docker git; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 1; }
done

# ---- STEP 0: fetch sources on the HOST (container cannot reach GitHub reliably) ----
# Reused across runs; set SLOT_REFRESH=1 to force re-fetch. Cores are fork-agnostic
# and built once, so they are cached and not re-fetched on every fork port.
SRC_HOST="$WORK/slot-src"
MGBA_HOST="$WORK/mgba-src"
GPSP_TARBALL_HOST="$WORK/gpsp-$GPSP_REV.tar.gz"

if [ -n "${SLOT_SRC:-}" ]; then
  SRC_HOST="$SLOT_SRC"
elif [ "${SLOT_REFRESH:-}" = 1 ] || [ ! -d "$SRC_HOST/.git" ]; then
  rm -rf "$SRC_HOST"
  git clone "https://github.com/$SLOT_REPO.git" "$SRC_HOST"
fi
git -C "$SRC_HOST" fetch origin "$SLOT_REV" 2>/dev/null || true
git -C "$SRC_HOST" checkout --detach "$SLOT_REV"

if [ "${SLOT_REFRESH:-}" = 1 ] || [ ! -d "$MGBA_HOST/.git" ]; then
  rm -rf "$MGBA_HOST"
  git clone "https://github.com/libretro/mgba.git" "$MGBA_HOST"
fi
git -C "$MGBA_HOST" fetch origin "$MGBA_REV" 2>/dev/null || true
git -C "$MGBA_HOST" checkout --detach "$MGBA_REV"

if [ ! -f "$GPSP_TARBALL_HOST" ]; then
  curl -fsSL -o "$GPSP_TARBALL_HOST" "https://github.com/libretro/gpsp/archive/$GPSP_REV.tar.gz"
fi

echo "== building experimental RG353PS Slot bundle =="
echo "   slot: $SLOT_REPO @ $SLOT_REV"
docker run --rm --network host --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
  -v "$HERE/frontends/slot":/slot-port:ro \
  -v "$OUT":/out \
  -v rg353ps-slot-cargo:/usr/local/cargo \
  -v rg353ps-slot-target:/cargo-target \
  -v "$WORK/core-cache":/core-cache \
  -v "$SRC_HOST":/slot-up:ro \
  -v "$MGBA_HOST":/mgba-up:ro \
  -v "$GPSP_TARBALL_HOST":/gpsp.tar.gz:ro \
  "${SLOT_BUILD_IMAGE:-rg353ps-slot-build:latest}" sh -euc '
    SLOT_REV="'"$SLOT_REV"'"
    MGBA_REV="'"$MGBA_REV"'"
    GPSP_REV="'"$GPSP_REV"'"
    export RUSTFLAGS="-C target-feature=-crt-static"
    export CARGO_HOME=/usr/local/cargo
    # Unmodified cores are compiled once and kept here, keyed by revision.
    CORE_CACHE=/core-cache
    # SLOT_TOOLCHAIN pins the compiler explicitly. Leave it empty to honour the
    # rust-toolchain.toml of the fork, which makes rustup download that channel.
    # Set it to e.g. 1.99.1-aarch64-unknown-linux-musl to build offline with the
    # toolchain already baked into the image.
    if [ -n "'"${SLOT_TOOLCHAIN:-}"'" ]; then export RUSTUP_TOOLCHAIN="'"${SLOT_TOOLCHAIN:-}"'"; fi

    SRC=/tmp/slot-src
    TARGET=/cargo-target
    PKG=/out/baseos-rg353ps-slot
    # Do NOT rm the cargo target cache: it is a persistent named volume warmed by
    # diag/warm-slot-cache.sh so dependency compilation (fat LTO) is skipped.
    rm -rf "$SRC" "$PKG"

    # Use the host-fetched, network-free copy and patch it in place.
    cp -r /slot-up "$SRC"
    cp /slot-port/fbdev.rs "$SRC/crates/slot-gfx/src/fbdev.rs"
    # slot-rg353ps.patch: the DTS-specific button and axis mapping.
    # slot-analog.patch: sticks reach the cores (RetroCore::set_analog, ANALOG
    # input_state) and the stick clicks become bindable L3/R3 buttons.
    # slot-power.patch: KEY_POWER goes back to the frontend (it must apply
    # after slot-rg353ps.patch, which removed the mapping). The music-aware
    # App::doze() policy lives in the selected Slot fork source, not in this patch.
    for p in /slot-port/slot-rg353ps.patch /slot-port/slot-analog.patch \
             /slot-port/slot-power.patch /slot-port/slot-bootlogo.patch; do
      echo "applying $(basename "$p")"
      git -C "$SRC" apply --ignore-whitespace "$p"
    done

    cd "$SRC"
    # The Slot SDL2/GLES surface uses libloading::Library::new, which requires dlopen.
    # Static musl binaries return "Dynamic loading not supported" and exit before SDL init.
    cargo build --profile device --target-dir "$TARGET" -p slot --no-default-features --features device
    test -x "$TARGET/device/slot"
    readelf -l "$TARGET/device/slot" | grep -q "ld-musl-aarch64.so.1" || {
      echo "Slot executable is not dynamically linked; SDL2/GLES dlopen will fail" >&2
      exit 1
    }

    mkdir -p "$PKG/System" "$PKG/.baseos/frontends/slot" "$PKG/baseos/frontends/slot"
    cp "$TARGET/device/slot" "$PKG/System/slot"
    cp /slot-port/launch.sh "$PKG/.baseos/frontends/slot/launch.sh"
    # Visible alias is intentional: some GUI extractors mishandle dot-prefixed folders.
    cp /slot-port/launch.sh "$PKG/baseos/frontends/slot/launch.sh"
    chmod 0755 "$PKG/.baseos/frontends/slot/launch.sh" "$PKG/baseos/frontends/slot/launch.sh" "$PKG/System/slot"
    cp -R licenses "$PKG/System/licenses"
    cp LICENSE "$PKG/System/licenses/slot-LICENSE.txt"
    # Ship the exact patched Slot source corresponding to System/slot.
    tar --exclude=.git -czf "$PKG/System/licenses/slot-rg353ps-$SLOT_REV-source.tar.gz" -C "$SRC" .
    "$PKG/System/slot" --init-root "$PKG"

    # mGBA: host-fetched copy so build.sh skips network entirely. This port does
    # not modify the core, so the compiled object, its metadata and the
    # corresponding-source archive are cached on the host under the revision they
    # were built from: a rebuild that only touched the slot sources copies them
    # instead of spending minutes compiling the core again. Changing MGBA_REV misses
    # the cache by construction; delete $CORE_CACHE to force a clean rebuild.
    mkdir -p "$CORE_CACHE"
    if [ -s "$CORE_CACHE/mgba-$MGBA_REV.so" ] &&
       [ -s "$CORE_CACHE/mgba-$MGBA_REV.meta" ] &&
       [ -s "$CORE_CACHE/mgba-$MGBA_REV-source.tar.gz" ]; then
      echo "reusing cached mGBA core ($MGBA_REV)"
      cp "$CORE_CACHE/mgba-$MGBA_REV.so" "$PKG/System/mgba_libretro.so"
      cp "$CORE_CACHE/mgba-$MGBA_REV.meta" "$PKG/System/mgba_libretro.so.meta"
      cp "$CORE_CACHE/mgba-$MGBA_REV-source.tar.gz" "$PKG/System/licenses/mgba-$MGBA_REV-source.tar.gz"
    else
      rm -rf /tmp/mgba-work
      mkdir -p /tmp/mgba-work
      cp -r /mgba-up /tmp/mgba-work/mgba
      sh cores/mgba/build.sh build "$MGBA_REV" /tmp/mgba-work "$PKG/System/mgba_libretro.so"
      # mGBA is dynamically linked; include the patched corresponding source and metadata.
      tar --exclude=.git -czf "$PKG/System/licenses/mgba-$MGBA_REV-source.tar.gz" -C /tmp/mgba-work/mgba .
      cp "$PKG/System/mgba_libretro.so" "$CORE_CACHE/mgba-$MGBA_REV.so"
      cp "$PKG/System/mgba_libretro.so.meta" "$CORE_CACHE/mgba-$MGBA_REV.meta"
      cp "$PKG/System/licenses/mgba-$MGBA_REV-source.tar.gz" "$CORE_CACHE/mgba-$MGBA_REV-source.tar.gz"
    fi

    # gpSP: host-fetched tarball, network-free, and cached the same way as mGBA.
    cp /gpsp.tar.gz /tmp/gpsp-src.tar.gz
    GPSP_TARBALL=/tmp/gpsp-src.tar.gz
    if [ -s "$CORE_CACHE/gpsp-$GPSP_REV.so" ] &&
       [ -s "$CORE_CACHE/gpsp-$GPSP_REV.meta" ] &&
       [ -s "$CORE_CACHE/gpsp-$GPSP_REV-source.tar.gz" ]; then
      echo "reusing cached gpSP core ($GPSP_REV)"
      cp "$CORE_CACHE/gpsp-$GPSP_REV.so" "$PKG/System/gpsp_libretro.so"
      cp "$CORE_CACHE/gpsp-$GPSP_REV.meta" "$PKG/System/gpsp_libretro.so.meta"
      cp "$CORE_CACHE/gpsp-$GPSP_REV-source.tar.gz" "$PKG/System/licenses/gpsp-$GPSP_REV-source.tar.gz"
    else
      sh cores/gpsp/build.sh build "$GPSP_REV" "$GPSP_TARBALL" /tmp/gpsp-work "$PKG/System/gpsp_libretro.so"
      # Include the exact patched source tree corresponding to the output core.
      tar --exclude=.git -czf "$PKG/System/licenses/gpsp-$GPSP_REV-source.tar.gz" -C "/tmp/gpsp-work/gpsp-$GPSP_REV" .
      cp "$PKG/System/gpsp_libretro.so" "$CORE_CACHE/gpsp-$GPSP_REV.so"
      cp "$PKG/System/gpsp_libretro.so.meta" "$CORE_CACHE/gpsp-$GPSP_REV.meta"
      cp "$PKG/System/licenses/gpsp-$GPSP_REV-source.tar.gz" "$CORE_CACHE/gpsp-$GPSP_REV-source.tar.gz"
    fi

    # Include source/provenance required for the GPL-licensed gpSP core and keep
    # both core build recipes and source patches with the distributable bundle.
    cp "$GPSP_TARBALL" "$PKG/System/licenses/gpsp-$GPSP_REV.tar.gz"
    cp "$PKG/System/gpsp_libretro.so.meta" "$PKG/System/licenses/gpsp-$GPSP_REV.meta"
    for p in cores/gpsp/*.patch; do
      cp "$p" "$PKG/System/licenses/gpsp-$(basename "$p")"
    done
    MGBA_BUILT_REV="$(grep "^commit=" "$PKG/System/mgba_libretro.so.meta" | cut -d= -f2)"
    cp "$PKG/System/mgba_libretro.so.meta" "$PKG/System/licenses/mgba-$MGBA_BUILT_REV.meta"
    for p in cores/mgba/*.patch; do
      cp "$p" "$PKG/System/licenses/mgba-$(basename "$p")"
    done

    cat > "$PKG/README-RG353PS.txt" <<EOF
BaseOS RG353PS Slot frontend experiment
=======================================

This bundle is intended to be extracted directly into the root of the TF2 card for priority use. BaseOS automatically scans TF2 first for a usable frontend adapter; if TF2 is absent or has no usable frontend, BaseOS checks the BASEOS user partition on TF1.

No baseos.conf edits are required. The second card is mounted at /mnt/TF2 and this adapter is:
  /mnt/TF2/.baseos/frontends/slot/launch.sh

If you intentionally want the TF1 copy to be the fallback, extract the bundle to the root of its BASEOS partition. TF2 remains the preferred location when it has a usable frontend.

This is an experimental port. The UI, input behavior, emulator launch, sound,
battery/backlight, shutdown, save states and extended play have not yet all
been verified on physical RG353PS hardware. Keep a separate copy of saves and
do not overwrite your original system card.
EOF
    chmod 0644 "$PKG/README-RG353PS.txt"
    cd "$PKG"
    # zip updates an existing archive instead of replacing it, so a leftover zip
    # from an older build silently keeps its stale entries and doubles the size.
    rm -f /out/baseos-rg353ps-slot.zip
    zip -qry /out/baseos-rg353ps-slot.zip .
    # Relative name so the checksum file is usable wherever it gets copied to.
    ( cd /out && sha256sum baseos-rg353ps-slot.zip > baseos-rg353ps-slot.zip.sha256 )
    ls -lh /out/baseos-rg353ps-slot.zip /out/baseos-rg353ps-slot.zip.sha256
  '

echo "Slot bundle: $OUT/baseos-rg353ps-slot.zip"
echo "Checksum:    $OUT/baseos-rg353ps-slot.zip.sha256"
