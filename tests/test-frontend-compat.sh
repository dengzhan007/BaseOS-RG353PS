#!/bin/sh
# Regression tests for automatic wrapping and safe removal of legacy frontend folders.
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
DISCOVERY="$HERE/platforms/rg353ps/rootfs/usr/sbin/baseos-frontend-discovery"
MANAGER="$HERE/platforms/rg353ps/rootfs/usr/sbin/baseos-frontend-manager"
HELPER="$HERE/platforms/rg353ps/rootfs/usr/sbin/baseos-frontend-compat"
TMP=${TMPDIR:-/tmp}/baseos-compat-test-$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
TF1=$TMP/card
TF2=$TMP/tf2
CATALOG=$TMP/catalog
mkdir -p "$TF1/Frontends/NextUI" "$TF1/Frontends/NextUI-copy" "$TF1/Frontends/Next'UI" "$TF1/Frontends/街机" "$TF2/Frontends"
cat > "$TF1/Frontends/NextUI/launch.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$PWD" > "$COMPAT_TEST_RESULT"
printf '%s\n' "$BASEOS_COMPAT_PROGRAM_DIR" >> "$COMPAT_TEST_RESULT"
EOF
cat > "$TF1/Frontends/NextUI-copy/launch.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TF1/Frontends/Next'UI/launch.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TF1/Frontends/街机/launch.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
printf '%s\n' 'frontend_id=auto' > "$TF1/baseos.conf"
cp "$HELPER" "$TMP/baseos-frontend-compat"
chmod 0755 "$TMP/baseos-frontend-compat"

fail() { echo "FAIL: $*" >&2; exit 1; }
compat_scan() {
  BASEOS_DISCOVERY_LIB="$DISCOVERY" "$TMP/baseos-frontend-compat" scan "$TF2" "$TF1"
}
run_manager() {
  BASEOS_DISCOVERY_LIB="$DISCOVERY" \
  BASEOS_FRONTEND_TF1="$TF1" BASEOS_FRONTEND_TF2="$TF2" \
  BASEOS_FRONTEND_CATALOG="$CATALOG" \
  BASEOS_COMPAT_TOOL="$TMP/baseos-frontend-compat" \
  sh "$MANAGER" "$@"
}

compat_scan
STATE=$TF1/.baseos/compat.scan-state
[ -f "$STATE" ] || fail "compatibility scan state was not recorded"
state_before=$(stat -c '%y' "$STATE")
sleep 1
compat_scan
state_after=$(stat -c '%y' "$STATE")
[ "$state_before" = "$state_after" ] || fail "unchanged compatibility scan rewrote its state"
sleep 1
mkdir -p "$TF1/Frontends/LateFrontend"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$TF1/Frontends/LateFrontend/launch.sh"
compat_scan
[ -f "$TF1/.baseos/compat/LateFrontend/baseos-frontend.conf" ] || fail "new frontend folder did not invalidate the compatibility scan cache"
SIDE=$TF1/.baseos/compat/NextUI
[ -f "$SIDE/baseos-frontend.conf" ] || fail "compatibility manifest was not generated"
[ -f "$SIDE/launch.sh" ] || fail "compatibility launcher was not generated"
[ -f "$SIDE/profiles/default.conf" ] || fail "default compatibility profile was not generated"
grep -qx 'compat_api=1' "$SIDE/baseos-frontend.conf" || fail "compatibility API marker missing"
[ ! -e "$TF1/Frontends/NextUI/baseos-frontend.conf" ] || fail "original frontend directory was modified"

COMPAT_TEST_RESULT=$TMP/launch-result
export COMPAT_TEST_RESULT
/bin/sh "$SIDE/launch.sh"
[ "$(sed -n '1p' "$COMPAT_TEST_RESULT")" = "$TF1/Frontends/NextUI" ] || fail "compat launcher did not preserve the original working directory"
[ "$(sed -n '2p' "$COMPAT_TEST_RESULT")" = "$TF1/Frontends/NextUI" ] || fail "compat program directory was not exported"

run_manager catalog
grep -F -q 'NextUI--default|NextUI|' "$CATALOG" || fail "legacy folder was not added to selector catalog"
grep -F -q 'NextUI-copy--default|NextUI-copy|' "$CATALOG" || fail "renamed full-copy folder was not discovered independently"
grep -F -q "Next-UI--default|Next'UI|" "$CATALOG" || fail "folder names containing quotes were not safely wrapped"
unicode_id="frontend-$(printf '%s' '街机' | cksum | awk '{print $1}')"
grep -F -q "$unicode_id--default|街机|" "$CATALOG" || fail "all-Unicode folder name was not assigned a stable ID"
. "$DISCOVERY"
baseos_frontend_scan_root "$TF1" NextUI || fail "legacy simple frontend_id pin was not resolved"
[ "$BASEOS_SCAN_ID" = "NextUI--default" ] || fail "legacy simple frontend_id did not resolve to its default profile"
[ "$BASEOS_SCAN_KIND" = "compat-package" ] || fail "simple frontend_id pin did not select the compatibility package"
[ "$(wc -l < "$CATALOG" | tr -d ' ')" = 5 ] || fail "expected five independent compatibility entries"

# Y action disables the compatibility entry but preserves metadata and program
# files. Disabled entries stay listed and cannot be selected by boot discovery.
run_manager uninstall-compat NextUI--default
[ -d "$TF1/Frontends/NextUI" ] || fail "disabling compatibility deleted original program files"
[ -d "$SIDE" ] || fail "disabling compatibility deleted its BaseOS metadata"
[ -f "$TF1/.baseos/compat-disabled/NextUI" ] || fail "compatibility disable marker missing"
run_manager catalog
grep -F -q 'NextUI--default|' "$CATALOG" || fail "disabled compatibility entry disappeared from catalog"
grep -F -q '|compat|disabled' "$CATALOG" || fail "compatibility disabled status was not exposed to selector"
. "$DISCOVERY"
baseos_frontend_scan_root "$TF1" NextUI--default && fail "disabled compatibility frontend was still discoverable at boot"

# Re-enable through the same catalog entry. BaseOS reuses the saved metadata.
run_manager enable-compat NextUI--default
[ ! -e "$TF1/.baseos/compat-disabled/NextUI" ] || fail "re-enable left the compatibility disable marker"
run_manager catalog
grep -F -q '|compat|enabled' "$CATALOG" || fail "re-enabled compatibility status did not return to enabled"
baseos_frontend_scan_root "$TF1" NextUI--default || fail "re-enabled compatibility frontend was not discoverable"

# X action explicitly deletes the original program directory after confirmation,
# along with its BaseOS compatibility metadata, disable marker and path map.
mkdir -p "$TF1/.baseos/frontend-paths"
printf '%s\n' 'paths_api=1' 'frontend_id=NextUI' > "$TF1/.baseos/frontend-paths/NextUI.conf"
run_manager delete-compat NextUI--default
[ ! -e "$TF1/.baseos/frontend-paths/NextUI.conf" ] || fail "full compatibility deletion left its BaseOS path map"
[ ! -e "$TF1/Frontends/NextUI" ] || fail "full compatibility deletion left the original program directory"
[ ! -e "$TF1/.baseos/compat/NextUI" ] || fail "full compatibility deletion left sidecar metadata"
[ ! -e "$TF1/.baseos/compat-disabled/NextUI" ] || fail "full compatibility deletion left disable marker"
[ -d "$TF1/Frontends/NextUI-copy" ] || fail "deleting one copy removed another frontend"

echo "PASS: automatic legacy compatibility, independent full-copy installs, unregister and confirmed full deletion"
