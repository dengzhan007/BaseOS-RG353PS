#!/bin/sh
# Guard the RG353PS update splash contract: show measured A/B progress on the
# built-in BaseOS wordmark, never on the selected user boot logo.
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
require '[ -x /usr/bin/fbsplash ] && /usr/bin/fbsplash "$1"'
require 'paint() { update_progress $(( $1 + ($2 - $1) * $3 / total_mb )); }'
require 'update_progress "$WRITE_FROM"'
require 'update_progress "$COMMIT_STAGE"'
require 'splash -1 "UPDATE FAILED"'

if grep -Fq 'paint() { splash' "$UPDATE"; then
  echo "update progress must not be rendered as a status pill" >&2
  exit 1
fi

echo "PASS: system updates use measured BaseOS wordmark progress"
