#!/bin/sh
# Host-side tests for the generic frontend adapter contract.
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$HERE/platforms/rg353ps/rootfs/usr/sbin/baseos-frontend-discovery"
TMP=${TMPDIR:-/tmp}/baseos-adapter-test-$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/card/.baseos/frontends/alpha" "$TMP/card/.baseos/frontends/beta" "$TMP/card/.baseos/frontends/-bad" "$TMP/card/.baseos/frontends/unsupported" "$TMP/card/.baseos/frontends/old-adapter" "$TMP/card/wrapper/.baseos/frontends/gamma" "$TMP/card/baseos/frontends/visible" "$TMP/card/baseos/frontends/alpha"
: > "$TMP/card/.baseos/frontends/alpha/launch.sh"
: > "$TMP/card/.baseos/frontends/beta/launch.sh"
: > "$TMP/card/.baseos/frontends/-bad/launch.sh"
: > "$TMP/card/.baseos/frontends/unsupported/launch.sh"
: > "$TMP/card/.baseos/frontends/old-adapter/launch.sh"
: > "$TMP/card/baseos/frontends/visible/launch.sh"
: > "$TMP/card/wrapper/.baseos/frontends/gamma/launch.sh"
: > "$TMP/card/baseos/frontends/alpha/launch.sh"
cat > "$TMP/card/.baseos/frontends/alpha/manifest.conf" <<'EOF'
adapter_api=1
priority=100
volume_owner=system
power_owner=system
EOF
cat > "$TMP/card/.baseos/frontends/beta/manifest.conf" <<'EOF'
adapter_api=1
priority=900
volume_owner=frontend
power_owner=frontend
EOF
cat > "$TMP/card/.baseos/frontends/-bad/manifest.conf" <<'EOF'
adapter_api=1
priority=9999
EOF
cat > "$TMP/card/.baseos/frontends/unsupported/manifest.conf" <<'EOF'
adapter_api=99
priority=9999
EOF
cat > "$TMP/card/wrapper/.baseos/frontends/gamma/manifest.conf" <<'EOF'
adapter_api=1
priority=200
volume_owner=frontend
power_owner=system
EOF
fail() { echo "FAIL: $*" >&2; exit 1; }
baseos_frontend_load_manifest "$TMP/card/.baseos/frontends/alpha" || fail "default adapter rejected"
[ "$BASEOS_ADAPTER_ID" = alpha ] || fail "wrong adapter ID"
[ "$BASEOS_ADAPTER_PRIORITY" = 100 ] || fail "wrong default priority"
baseos_frontend_scan_root "$TMP/card" auto || fail "automatic scan found nothing"
[ "$BASEOS_SCAN_ID" = beta ] || fail "priority winner should be beta"
[ "$BASEOS_SCAN_VOLUME_OWNER" = frontend ] || fail "volume ownership not loaded"
[ "$BASEOS_SCAN_POWER_OWNER" = frontend ] || fail "power ownership not loaded"
baseos_frontend_scan_root "$TMP/card" alpha || fail "pinned adapter not found"
[ "$BASEOS_SCAN_ID" = alpha ] || fail "frontend_id pin was ignored"
[ "$BASEOS_SCAN_DIR" = "$TMP/card/.baseos/frontends/alpha" ] || fail "canonical path should win over alias"
baseos_frontend_scan_root "$TMP/card" old-adapter || fail "manifest-free legacy adapter not found"
[ "$BASEOS_SCAN_PRIORITY" = 100 ] || fail "legacy adapter default priority wrong"
[ "$BASEOS_SCAN_VOLUME_OWNER" = system ] || fail "legacy adapter default volume owner wrong"
baseos_frontend_scan_root "$TMP/card" visible || fail "visible alias adapter not found"
[ "$BASEOS_SCAN_ROOT" = "$TMP/card" ] || fail "visible alias root not returned"
baseos_frontend_scan_root "$TMP/card" gamma || fail "nested adapter not found"
[ "$BASEOS_SCAN_ROOT" = "$TMP/card/wrapper" ] || fail "nested frontend root not returned"
baseos_frontend_scan_root "$TMP/card" -bad && fail "invalid adapter ID accepted"
baseos_frontend_scan_root "$TMP/card" unsupported && fail "unsupported API accepted"
echo "PASS: generic frontend adapter discovery"
