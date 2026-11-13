#!/bin/sh
# Host-side tests for package/profile discovery and per-profile identity.
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$HERE/platforms/rg353ps/rootfs/usr/sbin/baseos-frontend-discovery"
TMP=${TMPDIR:-/tmp}/baseos-package-test-$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
CARD=$TMP/card
PKG=$CARD/Frontends/slot-rg353ps
mkdir -p "$PKG/profiles"
: > "$PKG/launch.sh"
cat > "$PKG/baseos-frontend.conf" <<'EOF'
package_api=1
display_name=Slot
priority=100
volume_owner=frontend
power_owner=frontend
EOF
cat > "$PKG/profiles/640-native.conf" <<'EOF'
profile_api=1
display_name=640 Native
priority=100
EOF
cat > "$PKG/profiles/640x480.conf" <<'EOF'
profile_api=1
display_name=640x480 Compatibility
priority=200
power_owner=frontend
EOF
fail() { echo "FAIL: $*" >&2; exit 1; }

baseos_frontend_load_package "$CARD" "$PKG" "$PKG/profiles/640-native.conf" || fail "native profile rejected"
[ "$BASEOS_ADAPTER_ID" = slot-rg353ps--640-native ] || fail "wrong composite ID"
[ "$BASEOS_PACKAGE_ID" = slot-rg353ps ] || fail "package ID not loaded"
[ "$BASEOS_PROFILE_ID" = 640-native ] || fail "profile ID not loaded"
[ "$BASEOS_FRONTEND_NAME" = "Slot / 640 Native" ] || fail "display name not composed"
[ "$BASEOS_ADAPTER_VOLUME_OWNER" = frontend ] || fail "package volume owner not inherited"

baseos_frontend_load_package "$CARD" "$PKG" "$PKG/profiles/640x480.conf" || fail "compatibility profile rejected"
[ "$BASEOS_ADAPTER_ID" = slot-rg353ps--640x480 ] || fail "second profile did not get its own ID"
[ "$BASEOS_ADAPTER_PRIORITY" = 200 ] || fail "profile priority did not override package priority"

baseos_frontend_scan_root "$CARD" auto || fail "package discovery found no profile"
[ "$BASEOS_SCAN_ID" = slot-rg353ps--640x480 ] || fail "highest-priority profile did not win auto selection"
[ "$BASEOS_SCAN_KIND" = package ] || fail "package candidate kind was not recorded"
[ "$BASEOS_SCAN_PROFILE_ID" = 640x480 ] || fail "scan profile identity was lost"
[ "$BASEOS_SCAN_PACKAGE_DIR" = "$PKG" ] || fail "package directory was not returned"

baseos_frontend_scan_root "$CARD" slot-rg353ps--640-native || fail "pinned native profile not found"
[ "$BASEOS_SCAN_ID" = slot-rg353ps--640-native ] || fail "pinned profile selection ignored"
[ "$BASEOS_SCAN_PROFILE_CONFIG" = "$PKG/profiles/640-native.conf" ] || fail "profile config path mismatch"

# A legacy adapter remains discoverable alongside the new package format.
mkdir -p "$CARD/.baseos/frontends/legacy"
: > "$CARD/.baseos/frontends/legacy/launch.sh"
cat > "$CARD/.baseos/frontends/legacy/manifest.conf" <<'EOF'
adapter_api=1
priority=50
volume_owner=system
power_owner=system
EOF
baseos_frontend_scan_root "$CARD" legacy || fail "legacy adapter compatibility regressed"
[ "$BASEOS_SCAN_KIND" = legacy ] || fail "legacy adapter was reported as a package"

# Package/profile changes must invalidate the existing discovery cache.
CACHE=$TMP/selection-cache
: > "$CACHE"
touch "$CACHE"
sleep 1
mkdir "$CARD/Frontends/slot-rg353ps/profiles/third"
: > "$CARD/Frontends/slot-rg353ps/profiles/third/ignore"
# Directory mtime change is enough to invalidate; profile files remain validated.
baseos_frontend_tree_changed_since "$CARD" "$CACHE" || fail "new package/profile path did not invalidate cache"
sleep 1
touch "$CACHE"
sleep 1
printf '%s\n' 'display_name=Changed label' >> "$PKG/profiles/640-native.conf"
baseos_frontend_tree_changed_since "$CARD" "$CACHE" || fail "profile config edit did not invalidate cache"

# Invalid package/profile identities and APIs are rejected.
mkdir -p "$CARD/Frontends/bad/profiles"
: > "$CARD/Frontends/bad/launch.sh"
cat > "$CARD/Frontends/bad/baseos-frontend.conf" <<'EOF'
package_api=99
display_name=Bad
EOF
cat > "$CARD/Frontends/bad/profiles/default.conf" <<'EOF'
profile_api=1
display_name=Default
EOF
baseos_frontend_load_package "$CARD" "$CARD/Frontends/bad" "$CARD/Frontends/bad/profiles/default.conf" && fail "unsupported package API accepted"

echo "PASS: frontend package/profile discovery"
