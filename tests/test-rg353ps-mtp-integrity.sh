#!/bin/sh
# Static and behavioural checks for the MTP file-integrity test tool.
# Runs the simulated-MTP suite; hardware acceptance is a separate, manual step.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
MTP="$ROOT/tools/mtp"

python3 -c 'import sys; sys.exit(0)' >/dev/null 2>&1 || {
    echo "python3 is required for the MTP integrity tests" >&2
    exit 1
}

# Device scripts must stay POSIX/BusyBox compatible.
sh -n "$MTP/device/mtp-prepare.sh"
sh -n "$MTP/device/mtp-cleanup.sh"

# Python sources must compile.
python3 -m py_compile \
    "$MTP/mtp_common.py" \
    "$MTP/mtp_backends.py" \
    "$MTP/mtp_integrity.py" \
    "$MTP/tests/test_mtp_integrity.py"

# The harness must stay a test tool: no device mutation, no boot integration.
for forbidden in /dev/mmcblk reboot soft_connect configfs mkfs fastboot; do
    if grep -Rqu -- "$forbidden" "$MTP"/*.py "$MTP"/hosts "$MTP"/device; then
        echo "MTP integrity tool must not reference '$forbidden'" >&2
        exit 1
    fi
done

# Safety rails that the tests rely on must remain present in the sources.
grep -Fq 'baseos-mtp-test-' "$MTP/mtp_common.py"
grep -Fq 'was not created by the MTP integrity test tool' "$MTP/mtp_common.py"
grep -Fq 'parent traversal is not allowed' "$MTP/mtp_common.py"
grep -Fq 'symlink is not allowed' "$MTP/mtp_common.py"
grep -Fq -- '--confirm' "$MTP/device/mtp-cleanup.sh"

python3 "$MTP/tests/test_mtp_integrity.py" >/tmp/mtp-integrity-tests.log 2>&1 || {
    cat /tmp/mtp-integrity-tests.log >&2
    exit 1
}
tail -n 3 /tmp/mtp-integrity-tests.log

echo "RG353PS MTP integrity tool checks passed"
