#!/bin/sh
# BaseOS RG353PS MTP integrity test - device-side dataset generator.
#
# Runs on the handheld (BusyBox ash, no GNU extensions). Creates exactly one
# marked directory below the MTP storage root and leaves everything else alone:
# no block devices, no mounts, no gadget state.
#
# The layout mirrors DATASET_FULL in tools/mtp/mtp_common.py. Keep the two in
# sync, otherwise the host manifest comparison will fail for the wrong reason.
set -eu

STORAGE=/mnt/SDCARD
RUN_ID=
PROFILE=full
FORCE=no
ALLOW_NONSTD=no
# The only writable user-data mount on the RG353PS: / is a read-only rootfs and
# /mnt/boot holds the boot partition. Writing a 128 MiB test tree anywhere else
# is a mistake, so the root is pinned unless explicitly overridden.
ALLOWED_STORAGE=/mnt/SDCARD

usage() {
    cat <<'EOF'
usage: mtp-prepare.sh [--storage DIR] [--run-id ID] [--profile full|fast] [--force]
                      [--allow-nonstandard-storage]

  --storage DIR    MTP storage root (default /mnt/SDCARD, the only allowed value)
  --run-id ID      run identifier, YYYYMMDD-HHMMSS-aaaaaa (default: generated)
  --profile full   full payload sizes (default)
  --profile fast   shrunken payloads, same layout (for quick smoke runs)
  --force          replace an existing tree, but only if its marker matches
  --allow-nonstandard-storage
                   permit a --storage other than /mnt/SDCARD (deliberate tests only)

Refuses to overwrite a directory it did not create.
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        --storage) STORAGE=$2; shift 2 ;;
        --run-id) RUN_ID=$2; shift 2 ;;
        --profile) PROFILE=$2; shift 2 ;;
        --force) FORCE=yes; shift ;;
        --allow-nonstandard-storage) ALLOW_NONSTD=yes; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

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
case $PROFILE in full|fast) ;; *) die "unknown profile: $PROFILE" ;; esac

if [ -z "$RUN_ID" ]; then
    # BusyBox date supports %Y%m%d-%H%M%S; entropy comes from /dev/urandom.
    stamp=$(date -u '+%Y%m%d-%H%M%S' 2>/dev/null) || die "cannot read the clock"
    suffix=$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    [ -n "$suffix" ] || suffix=000000
    RUN_ID="$stamp-$suffix"
fi

printf '%s' "$RUN_ID" | grep -Eq '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$' \
    || die "invalid run id '$RUN_ID'; expected YYYYMMDD-HHMMSS-aaaaaa"

TEST_DIR="$STORAGE/baseos-mtp-test-$RUN_ID"
MARKER="$TEST_DIR/baseos-mtp-test-marker.json"
MANIFEST="$TEST_DIR/baseos-mtp-test-manifest.json"

case $TEST_DIR in
    "$STORAGE"/baseos-mtp-test-*) ;;
    *) die "refusing to work outside the storage root: $TEST_DIR" ;;
esac

if [ -e "$TEST_DIR" ]; then
    [ "$FORCE" = yes ] || die "$TEST_DIR already exists; pass --force only for a directory this tool created"
    [ -f "$MARKER" ] || die "$TEST_DIR has no marker; refusing to replace it"
    grep -Fq '"tool": "baseos-mtp-integrity"' "$MARKER" || die "$TEST_DIR belongs to another tool"
    grep -Fq "\"run_id\": \"$RUN_ID\"" "$MARKER" || die "$TEST_DIR marker run id does not match $RUN_ID"
    rm -rf "$TEST_DIR"
    say "replaced previous tool tree $TEST_DIR"
fi

if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD=sha256sum
elif busybox sha256sum </dev/null >/dev/null 2>&1; then
    SHA_CMD='busybox sha256sum'
else
    die "no sha256 implementation found"
fi

# Hash through stdin: GNU coreutils prefixes the "hash  name" form with a
# backslash for names needing escaping (spaces, newlines), which would corrupt
# the JSON manifest.
sha_of() { $SHA_CMD <"$1" | cut -d' ' -f1; }

size_for() { # profile-dependent payload size for a logical entry
    _name=$1
    _full=$2
    if [ "$PROFILE" = fast ] && [ "$_full" -ge 1048576 ]; then
        echo 8192
    else
        echo "$_full"
    fi
}

make_payload() { # path size
    _path=$1
    _size=$2
    case $_path in
        *.txt)
            printf 'BaseOS RG353PS MTP integrity test\nrun_id=%s\npath=%s\n' \
                "$RUN_ID" "${_path#"$TEST_DIR"/}" >"$_path"
            _have=$(wc -c <"$_path" | tr -d ' ')
            _need=$((_size - _have))
            if [ "$_need" -gt 0 ]; then
                _blocks=$(((_need + 1023) / 1024))
                dd if=/dev/urandom bs=1024 count="$_blocks" 2>/dev/null \
                    | head -c "$_need" >>"$_path"
            fi
            ;;
        *)
            dd if=/dev/urandom of="$_path" bs=1024 count=$((_size / 1024)) 2>/dev/null
            ;;
    esac
}

# name<TAB>full size
ENTRIES='small-4k.bin 4096
medium-1m.bin 1048576
large-128m.bin 134217728
中文文件名.txt 1024
name with spaces.txt 1024
中文 目录 with spaces/嵌套 子目录/深层 文件.txt 1024
nested/sub/deep.bin 65536'

mkdir -p "$TEST_DIR" || die "cannot create $TEST_DIR"

manifest_tmp="$MANIFEST.tmp"
{
    printf '{\n'
    printf '  "tool": "baseos-mtp-integrity",\n'
    printf '  "tool_version": "1.0",\n'
    printf '  "dataset_version": 1,\n'
    printf '  "run_id": "%s",\n' "$RUN_ID"
    printf '  "origin": "device",\n'
    printf '  "created_utc": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)"
    printf '  "files": [\n'
} >"$manifest_tmp"

first=yes
printf '%s\n' "$ENTRIES" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=${line% *}
    full_size=${line##* }
    size=$(size_for "$name" "$full_size")
    target="$TEST_DIR/$name"
    mkdir -p "$(dirname "$target")"
    make_payload "$target" "$size"
    actual=$(wc -c <"$target" | tr -d ' ')
    digest=$(sha_of "$target")
    [ "$actual" = "$size" ] || die "size mismatch while generating $name ($actual != $size)"
    if [ "$first" = yes ]; then
        first=no
    else
        printf ',\n' >>"$manifest_tmp"
    fi
    printf '    {"relpath": "%s", "size": %s, "sha256": "%s"}' "$name" "$actual" "$digest" \
        >>"$manifest_tmp"
done

printf '\n  ]\n}\n' >>"$manifest_tmp"
mv "$manifest_tmp" "$MANIFEST"

cat >"$MARKER" <<EOF
{
  "dataset_profile": "$PROFILE",
  "dataset_version": 1,
  "note": "Created by the BaseOS MTP integrity test tool; safe to delete with mtp-cleanup.sh",
  "run_id": "$RUN_ID",
  "tool": "baseos-mtp-integrity",
  "tool_version": "1.0"
}
EOF

sync
say "run_id=$RUN_ID"
say "test_dir=$TEST_DIR"
say "manifest=$MANIFEST"
say "files=$(grep -c '"relpath"' "$MANIFEST")"
