#!/bin/sh
# Generate the RG353PS boot-resource BMP with the H700 BaseOS fbsplash renderer.
# This is a host-side build step: the handheld only consumes the finished BMP.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
. "$REPO_ROOT/tools/common.sh"

WORK="$REPO_ROOT/work/rg353ps"
OUT="$WORK/bootlogo.bmp"
mkdir -p "$WORK"

docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$REPO_ROOT/src":/src:ro \
  -v "$REPO_ROOT/assets":/assets:ro \
  -v "$WORK":/work \
  alpine:3.20 sh -euc '
    apk add --no-cache build-base linux-headers pkgconf freetype-dev freetype-static \
      zlib-static libpng-static bzip2-static brotli-static imagemagick
    mkdir -p /usr/share/baseos
    cp /assets/boot.ttf /usr/share/baseos/boot.ttf
    gcc -DFBSPLASH_TEST -O2 $(pkg-config --cflags freetype2) \
      -o /tmp/fbtest /src/fbsplash.c $(pkg-config --static --libs freetype2)
    /tmp/fbtest 100 "" /tmp/bootlogo.ppm 640 480 0
    convert /tmp/bootlogo.ppm -type TrueColor \
      -define bmp:format=bmp3 BMP3:/work/bootlogo.bmp
  '

python3 - "$OUT" <<'PY'
import struct, sys
from pathlib import Path
p = Path(sys.argv[1])
data = p.read_bytes()
assert data[:2] == b"BM", "fbsplash renderer did not produce a BMP"
width, height = struct.unpack_from("<ii", data, 18)
planes, bpp = struct.unpack_from("<HH", data, 26)
compression = struct.unpack_from("<I", data, 30)[0]
assert (width, abs(height), planes, bpp, compression) == (640, 480, 1, 24, 0), (
    "unexpected bootlogo format: {}x{}, {} planes, {}bpp, compression={}".format(
        width, height, planes, bpp, compression
    )
)
assert len(data) >= 921654, "bootlogo is truncated: {} bytes".format(len(data))
print("Generated {}: 640x480 24bpp ({} bytes)".format(p, len(data)))
PY
