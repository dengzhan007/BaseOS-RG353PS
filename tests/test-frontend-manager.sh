#!/bin/sh
# Sandboxed tests for frontend catalog, default selection and profile uninstall.
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=${TMPDIR:-/tmp}/baseos-frontend-manager-test-$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
TF1=$TMP/card
TF2=$TMP/tf2
CATALOG=$TMP/catalog
mkdir -p "$TF1/Frontends/slot-rg353ps/profiles" "$TF2" "$TF1/Games" "$TF1/Saves"
MANAGER=$HERE/platforms/rg353ps/rootfs/usr/sbin/baseos-frontend-manager
DISCOVERY=$HERE/platforms/rg353ps/rootfs/usr/sbin/baseos-frontend-discovery
run_manager() {
  BASEOS_DISCOVERY_LIB="$DISCOVERY" \
  BASEOS_FRONTEND_TF1="$TF1" BASEOS_FRONTEND_TF2="$TF2" \
  BASEOS_FRONTEND_CATALOG="$CATALOG" \
    sh "$MANAGER" "$@"
}
PACKAGE=$TF1/Frontends/slot-rg353ps
: > "$PACKAGE/launch.sh"
cat > "$PACKAGE/baseos-frontend.conf" <<'EOF'
package_api=1
display_name=Slot
priority=100
volume_owner=frontend
power_owner=frontend
EOF
cat > "$PACKAGE/profiles/640-native.conf" <<'EOF'
profile_api=1
display_name=640 Native
priority=100
EOF
cat > "$PACKAGE/profiles/640x480.conf" <<'EOF'
profile_api=1
display_name=640x480
priority=200
EOF
CONFIG=$TF1/baseos.conf
cat > "$CONFIG" <<'EOF'
# Preserve unrelated card settings.
debug=no
frontend_id=slot-rg353ps--640-native
usb_diagnostics=no
EOF
mkdir -p "$TF1/.baseos/instances/slot-rg353ps--640-native/data"
printf 'keep me\n' > "$TF1/.baseos/instances/slot-rg353ps--640-native/data/marker"
printf 'game\n' > "$TF1/Games/game.rom"
printf 'save\n' > "$TF1/Saves/game.srm"

fail() { echo "FAIL: $*" >&2; exit 1; }
run_manager catalog
[ "$(wc -l < "$CATALOG" | tr -d ' ')" = 2 ] || fail "catalog should contain both profiles"
grep -F -q 'slot-rg353ps--640-native|' "$CATALOG" || fail "native profile missing from catalog"
grep -F -q 'slot-rg353ps--640x480|' "$CATALOG" || fail "640x480 profile missing from catalog"

run_manager set-default slot-rg353ps--640x480
grep -F -q 'frontend_id=slot-rg353ps--640x480' "$CONFIG" || fail "default profile was not saved"
grep -F -q 'debug=no' "$CONFIG" || fail "unrelated debug setting was lost"
grep -F -q 'usb_diagnostics=no' "$CONFIG" || fail "unrelated USB setting was lost"
grep -F -q '# Preserve unrelated card settings.' "$CONFIG" || fail "user comment was lost"

# Removing one profile must leave the common package payload and other profile.
run_manager uninstall slot-rg353ps--640-native
[ -d "$PACKAGE" ] || fail "package was deleted while another profile remained"
[ -f "$PACKAGE/profiles/640x480.conf" ] || fail "other profile was removed"
[ ! -e "$PACKAGE/profiles/640-native.conf" ] || fail "selected profile was not removed"
[ -f "$TF1/.baseos/instances/slot-rg353ps--640-native/data/marker" ] || fail "profile instance data was deleted"
[ -f "$TF1/Games/game.rom" ] || fail "shared ROM was deleted"
[ -f "$TF1/Saves/game.srm" ] || fail "shared save was deleted"
grep -F -q 'frontend_id=slot-rg353ps--640x480' "$CONFIG" || fail "other profile default was changed"

# Removing the last profile removes the package but still retains all user data.
run_manager uninstall slot-rg353ps--640x480
[ ! -e "$PACKAGE" ] || fail "empty package directory was not removed"
[ "$(sed -n 's/^frontend_id=//p' "$CONFIG")" = auto ] || fail "removed default was not reset to auto"
[ -f "$TF1/.baseos/instances/slot-rg353ps--640-native/data/marker" ] || fail "last-profile removal deleted instance data"
[ -f "$TF1/Games/game.rom" ] || fail "last-profile removal deleted shared ROM"
[ -f "$TF1/Saves/game.srm" ] || fail "last-profile removal deleted shared save"

echo "PASS: frontend manager catalog, defaults and profile uninstall"
