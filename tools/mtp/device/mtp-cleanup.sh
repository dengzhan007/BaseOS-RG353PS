#!/bin/sh
# BaseOS RG353PS MTP integrity test - device-side cleanup.
#
# Deletes ONE tool-owned test tree after re-checking the marker, the run id and
# the resolved path. Cleanup is always a separate, explicit step: the prepare
# script never removes anything by itself and the host tool never deletes a
# directory the user did not name.
set -eu

STORAGE=/mnt/SDCARD
RUN_ID=
CONFIRM=no
ALLOW_NONSTD=no
# Same pin as mtp-prepare.sh: only the user-data partition may be touched, so a
# mistyped --storage cannot delete anything under / or /mnt/boot.
ALLOWED_STORAGE=/mnt/SDCARD

usage() {
    cat <<'EOF'
usage: mtp-cleanup.sh --run-id ID [--storage DIR] --confirm
                      [--allow-nonstandard-storage]

  --run-id ID    run identifier of the tree to delete
  --storage DIR  MTP storage root (default /mnt/SDCARD, the only allowed value)
  --confirm      required; without it the script only reports what it would do
  --allow-nonstandard-storage
                 permit a --storage other than /mnt/SDCARD (deliberate tests only)

Only <storage>/baseos-mtp-test-<ID> is ever removed, and only when its marker
proves the directory was created by this tool with the same run id.
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        --storage) STORAGE=$2; shift 2 ;;
        --run-id) RUN_ID=$2; shift 2 ;;
        --confirm) CONFIRM=yes; shift ;;
        --allow-nonstandard-storage) ALLOW_NONSTD=yes; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -n "$RUN_ID" ] || { usage >&2; die "--run-id is required"; }
[ -d "$STORAGE" ] || die "storage root does not exist: $STORAGE"
case $STORAGE in
    *..*) die "refusing a storage path containing '..': $STORAGE" ;;
esac
STORAGE=$(cd "$STORAGE" 2>/dev/null && pwd -P) || die "cannot resolve storage root: $STORAGE"
[ -n "$STORAGE" ] || die "cannot resolve storage root"
[ "$STORAGE" != / ] || die "refusing to use / as the test root"
if [ "$ALLOW_NONSTD" != yes ] && [ "$STORAGE" != "$ALLOWED_STORAGE" ]; then
    die "refusing to use '$STORAGE' as the test root; only $ALLOWED_STORAGE
(the user-data partition) is allowed. Pass --allow-nonstandard-storage to override."
fi
printf '%s' "$RUN_ID" | grep -Eq '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$' \
    || die "invalid run id '$RUN_ID'"

TEST_DIR="$STORAGE/baseos-mtp-test-$RUN_ID"
MARKER="$TEST_DIR/baseos-mtp-test-marker.json"

case $TEST_DIR in
    "$STORAGE"/baseos-mtp-test-*) ;;
    *) die "refusing to touch a path outside the storage root: $TEST_DIR" ;;
esac

[ -e "$TEST_DIR" ] || { printf 'nothing to do: %s does not exist\n' "$TEST_DIR"; exit 0; }
[ -d "$TEST_DIR" ] || die "not a directory: $TEST_DIR"
[ ! -L "$TEST_DIR" ] || die "refusing to delete a symlink: $TEST_DIR"
[ -f "$MARKER" ] || die "$TEST_DIR has no marker, refusing to delete"

grep -Fq '"tool": "baseos-mtp-integrity"' "$MARKER" || die "$TEST_DIR belongs to another tool"
grep -Fq "\"run_id\": \"$RUN_ID\"" "$MARKER" || die "$TEST_DIR marker run id does not match $RUN_ID"

printf 'verified tree: %s\n' "$TEST_DIR"
if [ "$CONFIRM" != yes ]; then
    printf 'dry run: pass --confirm to delete it\n'
    exit 0
fi

rm -rf "$TEST_DIR"
[ ! -e "$TEST_DIR" ] || die "delete did not complete: $TEST_DIR still exists"
printf 'deleted: %s\n' "$TEST_DIR"
