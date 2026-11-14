#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SESSION="$ROOT/platforms/rg353ps/rootfs/usr/sbin/baseos-frontend-session"
CONTROL="$ROOT/platforms/rg353ps/src/rg353ps-control-center.c"
SELECTOR="$ROOT/platforms/rg353ps/src/rg353ps-frontend-selector.c"

grep -Fq 'ln -sfn "$BASEOS_CARD_ROOT" /mnt/sdcard' "$SESSION" ||
  { echo "FAIL: legacy /mnt/sdcard alias does not point at the selected card root" >&2; exit 1; }
grep -Fq 'BASEOS_DIAGNOSTIC_SUPERVISED=1 /usr/sbin/rg353ps-control-center &' "$SESSION" ||
  { echo "FAIL: session diagnostic UI does not advertise supervisor ownership" >&2; exit 1; }
grep -Fq '"/run/baseos-frontend-paused"' "$CONTROL" ||
  { echo "FAIL: selector-launched diagnostics cannot acknowledge USB pause" >&2; exit 1; }
grep -Fq '"/run/baseos-usb-storage.request"' "$CONTROL" ||
  { echo "FAIL: selector-launched diagnostics do not wait for the USB request marker" >&2; exit 1; }
grep -Fq 'BASEOS_DIAGNOSTIC_SUPERVISED", "0"' "$SELECTOR" ||
  { echo "FAIL: selector child does not identify its unsupervised state" >&2; exit 1; }
grep -Fq 'nested selector diagnostics acknowledged the USB pause' "$SESSION" ||
  { echo "FAIL: outer supervisor does not honor nested USB pause" >&2; exit 1; }
grep -Fq 'access("/run/baseos-frontend-selection", F_OK)' "$SELECTOR" ||
  { echo "FAIL: nested diagnostics cannot propagate frontend selection" >&2; exit 1; }

echo "PASS: selector diagnostics coordinate USB storage and frontend-selection handoff"
