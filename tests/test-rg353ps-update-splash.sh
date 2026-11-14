#!/bin/sh
# Verify that A/B progress is shown both in the BaseOS wordmark and in the bottom pill.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATE="$ROOT/platforms/rg353ps/rootfs/usr/sbin/baseos-update"
WRAPPER="$ROOT/platforms/rg353ps/rootfs/usr/bin/baseos-splash"
FBSPLASH="$ROOT/src/fbsplash.c"

require() {
  grep -Fq -- "$1" "$UPDATE" || {
    echo "missing update-splash contract: $1" >&2
    exit 1
  }
}

require 'unset BASEOS_CUSTOM_SPLASH BASEOS_CUSTOM_SPLASH_ONLY'
require '[ -x /usr/bin/baseos-splash ] && /usr/bin/baseos-splash --progress "$1" "UPDATING SYSTEM"'
grep -Fq 'exec /usr/bin/fbsplash "$1" "$2" --combined' "$WRAPPER" || {
  echo "progress wrapper must invoke the combined framebuffer renderer" >&2
  exit 1
}
grep -Fq 'render(canvas, draw_v, draw_f, prog, NULL);' "$FBSPLASH" || {
  echo "combined mode must keep the left-to-right wordmark illumination" >&2
  exit 1
}
grep -Fq 'render_pill(canvas, draw_v, draw_f, prog, msg);' "$FBSPLASH" || {
  echo "combined mode must draw the bottom status pill in the same frame" >&2
  exit 1
}
grep -Fq 'present(fb, &v, &f, panel_rotation(), prog, msg, pill, combined);' "$FBSPLASH" || {
  echo "combined render mode is not wired to the framebuffer entry point" >&2
  exit 1
}
require 'paint() { update_progress $(( $1 + ($2 - $1) * $3 / total_mb )); }'
require 'update_progress "$WRITE_FROM"'
require 'update_progress "$COMMIT_STAGE"'
require 'splash -1 "UPDATE FAILED"'

if grep -Fq 'paint() { splash' "$UPDATE"; then
  echo "progress percentage must remain based on bytes written/read back" >&2
  exit 1
fi

echo "PASS: update progress keeps wordmark illumination and status pill in one framebuffer frame"
