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

# Removing the current default profile must leave the package and select
# the remaining profile as the new default.
run_manager set-default slot-rg353ps--640-native
run_manager uninstall slot-rg353ps--640-native
[ -d "$PACKAGE" ] || fail "package was deleted while another profile remained"
[ -f "$PACKAGE/profiles/640x480.conf" ] || fail "other profile was removed"
[ ! -e "$PACKAGE/profiles/640-native.conf" ] || fail "selected profile was not removed"
[ -f "$TF1/.baseos/instances/slot-rg353ps--640-native/data/marker" ] || fail "profile instance data was deleted"
[ -f "$TF1/Games/game.rom" ] || fail "shared ROM was deleted"
[ -f "$TF1/Saves/game.srm" ] || fail "shared save was deleted"
grep -F -q 'frontend_id=slot-rg353ps--640x480' "$CONFIG" || fail "remaining profile was not selected as new default"

# Removing the last profile removes the package but still retains all user data.
run_manager uninstall slot-rg353ps--640x480
[ ! -e "$PACKAGE" ] || fail "empty package directory was not removed"
[ "$(sed -n 's/^frontend_id=//p' "$CONFIG")" = auto ] || fail "removed default was not reset to auto"
[ -f "$TF1/.baseos/instances/slot-rg353ps--640-native/data/marker" ] || fail "last-profile removal deleted instance data"
[ -f "$TF1/Games/game.rom" ] || fail "last-profile removal deleted shared ROM"
[ -f "$TF1/Saves/game.srm" ] || fail "last-profile removal deleted shared save"

# Full frontend uninstall removes every profile and the shared program package,
# but keeps every instance directory and all common game/save data.
FULL_PACKAGE=$TF1/Frontends/full-frontend
mkdir -p "$FULL_PACKAGE/profiles" "$TF1/.baseos/instances/full-frontend--one/data"
: > "$FULL_PACKAGE/launch.sh"
cat > "$FULL_PACKAGE/baseos-frontend.conf" <<'EOF'
package_api=1
display_name=Full uninstall test
priority=10
EOF
cat > "$FULL_PACKAGE/profiles/one.conf" <<'EOF'
profile_api=1
display_name=One
EOF
cat > "$FULL_PACKAGE/profiles/two.conf" <<'EOF'
profile_api=1
display_name=Two
EOF
printf 'preserve full package instance\n' > "$TF1/.baseos/instances/full-frontend--one/data/marker"
run_manager set-default full-frontend--one
run_manager uninstall-package full-frontend--one
[ ! -e "$FULL_PACKAGE" ] || fail "full frontend uninstall left its package directory"
[ -f "$TF1/.baseos/instances/full-frontend--one/data/marker" ] || fail "full frontend uninstall deleted instance data"
[ "$(sed -n 's/^frontend_id=//p' "$CONFIG")" = auto ] || fail "full frontend uninstall did not reset the removed default"
[ -f "$TF1/Games/game.rom" ] || fail "full frontend uninstall deleted shared ROM"
[ -f "$TF1/Saves/game.srm" ] || fail "full frontend uninstall deleted shared save"

# A profile config symlink must never be followed for destructive operations.
mkdir -p "$TF1/Frontends/unsafe-package/profiles"
: > "$TF1/Frontends/unsafe-package/launch.sh"
cat > "$TF1/Frontends/unsafe-package/baseos-frontend.conf" <<'EOF'
package_api=1
display_name=Unsafe test
priority=1
EOF
printf 'profile_api=1\ndisplay_name=External target\n' > "$TMP/external-profile.conf"
ln -s "$TMP/external-profile.conf" "$TF1/Frontends/unsafe-package/profiles/external.conf"
if run_manager uninstall unsafe-package--external; then
  fail "manager accepted a symlinked profile uninstall target"
fi
[ -f "$TMP/external-profile.conf" ] || fail "symlink uninstall deleted its external target"
[ -L "$TF1/Frontends/unsafe-package/profiles/external.conf" ] || fail "symlink guard unexpectedly removed the link"

# A renamed package can carry one previous package ID. The catalog keeps the
# visible package name concise when package/profile display names match, and
# migrates the old pinned frontend_id to the new package/profile identity.
RENAMED_PACKAGE=$TF1/Frontends/LUCKLUCK-SLOT
mkdir -p "$RENAMED_PACKAGE/profiles"
: > "$RENAMED_PACKAGE/launch.sh"
cat > "$RENAMED_PACKAGE/baseos-frontend.conf" <<'EOF'
package_api=1
display_name=LUCKLUCK-SLOT
previous_package_id=slot-rg353ps
priority=100
EOF
cat > "$RENAMED_PACKAGE/profiles/640-native.conf" <<'EOF'
profile_api=1
display_name=LUCKLUCK-SLOT
priority=100
EOF
cat > "$CONFIG" <<'EOF'
debug=no
frontend_id=slot-rg353ps--640-native
usb_diagnostics=no
EOF
run_manager catalog
grep -F -q 'LUCKLUCK-SLOT--640-native|LUCKLUCK-SLOT|' "$CATALOG" || fail "selector label was not reduced to the package name"
grep -F -q 'frontend_id=LUCKLUCK-SLOT--640-native' "$CONFIG" || fail "legacy package default was not migrated"
. "$DISCOVERY"
baseos_frontend_scan_root "$TF1" "slot-rg353ps--640-native" || fail "legacy pinned package ID did not resolve through previous_package_id"
[ "$BASEOS_SCAN_ID" = "LUCKLUCK-SLOT--640-native" ] || fail "legacy selection resolved to an unexpected package ID"

# If an old default profile is not shipped in the new single-profile package,
# BaseOS should fall back to the available default profile rather than failing
# frontend discovery. The old profile instance is still retained for opt-in
# recreation under the same profile ID.
cat > "$CONFIG" <<'EOF'
frontend_id=slot-rg353ps--640-native-alt
EOF
. "$DISCOVERY"
baseos_frontend_scan_root "$TF1" "slot-rg353ps--640-native-alt" || fail "normal boot could not fall back from a removed legacy default profile"
[ "$BASEOS_SCAN_ID" = "LUCKLUCK-SLOT--640-native" ] || fail "normal-boot fallback selected the wrong profile"
run_manager catalog
grep -F -q 'frontend_id=LUCKLUCK-SLOT--640-native' "$CONFIG" || fail "missing legacy profile did not fall back to the default profile"
[ -d "$TF1/.baseos/instances/slot-rg353ps--640-native" ] || fail "old matching profile instance was not preserved"

# Creating the omitted old profile under the same ID lets the pinned legacy ID
# resolve again, and preserves the old per-profile data for the launcher migration.
cat > "$RENAMED_PACKAGE/profiles/640-native-alt.conf" <<'EOF'
profile_api=1
display_name=Extra Config
priority=90
EOF
. "$DISCOVERY"
baseos_frontend_scan_root "$TF1" "slot-rg353ps--640-native-alt" || fail "recreated legacy profile did not resolve through the package alias"
[ "$BASEOS_SCAN_ID" = "LUCKLUCK-SLOT--640-native-alt" ] || fail "recreated profile resolved to an unexpected identity"

# A legacy archive is installed as one independent directory under
# Frontends/<name>/. The adapter, .system and Tools all belong to this bundle.
LEGACY_ROOT=$TF1/Frontends/NextUI
LEGACY_ADAPTER=$LEGACY_ROOT/.baseos/frontends/nextui
mkdir -p "$LEGACY_ADAPTER" "$LEGACY_ROOT/.system/rg353ps" "$LEGACY_ROOT/Tools/rg353ps"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$LEGACY_ADAPTER/launch.sh"
cat > "$LEGACY_ADAPTER/manifest.conf" <<'EOF'
adapter_api=1
priority=120
volume_owner=system
power_owner=system
EOF
printf 'nextui payload\n' > "$LEGACY_ROOT/.system/rg353ps/nextui.elf"
printf 'shared tool\n' > "$LEGACY_ROOT/Tools/rg353ps/tool"
run_manager catalog
grep -F -q 'nextui|nextui|nextui|legacy|' "$CATALOG" || fail "legacy adapter under wrapper root was missing from the selector catalog"
. "$DISCOVERY"
baseos_frontend_scan_root "$TF1" nextui || fail "runtime discovery did not find the old NextUI wrapper layout"
[ "$BASEOS_SCAN_DIR" = "$LEGACY_ADAPTER" ] || fail "runtime discovery selected an unexpected legacy adapter directory"
run_manager set-default nextui
grep -F -q 'frontend_id=nextui' "$CONFIG" || fail "plain legacy adapter ID was not accepted as a default"
run_manager disable-legacy nextui
[ -f "$LEGACY_ROOT/.baseos/frontends-disabled/nextui" ] || fail "legacy adapter disable marker was not created"
[ -f "$LEGACY_ADAPTER/launch.sh" ] || fail "disabling legacy adapter deleted its original files"
[ -f "$LEGACY_ROOT/.system/rg353ps/nextui.elf" ] || fail "disabling legacy adapter touched shared frontend payload"
run_manager catalog
! grep -F -q 'nextui|' "$CATALOG" || fail "disabled legacy adapter remained in selector catalog"
[ "$(sed -n 's/^frontend_id=//p' "$CONFIG" | tail -n 1)" != nextui ] || fail "disabled default adapter was left pinned"
rm -f "$LEGACY_ROOT/.baseos/frontends-disabled/nextui"
run_manager catalog
grep -F -q 'nextui|nextui|nextui|legacy|' "$CATALOG" || fail "legacy adapter did not return after re-enable"
run_manager delete-legacy-adapter nextui
[ ! -e "$LEGACY_ROOT" ] || fail "confirmed legacy frontend deletion left its bundle directory"
[ ! -e "$LEGACY_ROOT/.system/rg353ps/nextui.elf" ] || fail "legacy frontend deletion left bundled .system payload"
[ ! -e "$LEGACY_ROOT/Tools/rg353ps/tool" ] || fail "legacy frontend deletion left bundled Tools payload"
[ -f "$TF1/Games/game.rom" ] || fail "legacy frontend deletion removed shared Games"
[ -f "$TF1/Saves/game.srm" ] || fail "legacy frontend deletion removed shared Saves"

echo "PASS: frontend manager catalog, profile/full uninstall, legacy adapter selector lifecycle, data retention, package rename/default migration and symlink guard"
