#!/bin/sh
# Verify that A/B progress is shown both in the BaseOS wordmark and in the bottom pill.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATE="$ROOT/platforms/rg353ps/rootfs/usr/sbin/baseos-update"

require() {
  grep -Fq -- "$1" "$UPDATE" || {
    echo "missing update-splash contract: $1" >&2
    exit 1
  }
}

require 'unset BASEOS_CUSTOM_SPLASH BASEOS_CUSTOM_SPLASH_ONLY'
require '[ -x /usr/bin/baseos-splash ] && /usr/bin/baseos-splash --important "$1" "UPDATING SYSTEM"'
if grep -Fq '/usr/bin/fbsplash "$1"' "$UPDATE"; then
  echo "progress update must not redraw the full-screen background on every step" >&2
  exit 1
fi
require 'paint() { update_progress $(( $1 + ($2 - $1) * $3 / total_mb )); }'
require 'update_progress "$WRITE_FROM"'
require 'update_progress "$COMMIT_STAGE"'
require 'splash -1 "UPDATE FAILED"'

if grep -Fq 'paint() { splash' "$UPDATE"; then
  echo "progress percentage must remain based on bytes written/read back" >&2
  exit 1
fi

echo "PASS: update progress updates only the bottom status pill without full-screen flicker"
