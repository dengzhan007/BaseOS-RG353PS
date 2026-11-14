#!/bin/sh
# Regression tests for automatic wrapping and safe removal of legacy frontend folders.
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
DISCOVERY="$HERE/platforms/rg353ps/rootfs/usr/sbin/baseos-frontend-discovery"
MANAGER="$HERE/platforms/rg353ps/rootfs/usr/sbin/baseos-frontend-manager"
HELPER="$HERE/platforms/rg353ps/rootfs/usr/sbin/baseos-frontend-compat"
TMP=${TMPDIR:-/tmp}/baseos-compat-test-$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
TF1=$TMP/card
TF2=$TMP/tf2
CATALOG=$TMP/catalog
mkdir -p "$TF1/Frontends/NextUI" "$TF1/Frontends/NextUI-copy" "$TF1/Frontends/Next'UI" "$TF1/Frontends/街机" "$TF2"
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
[ "$(wc -l < "$CATALOG" | tr -d ' ')" = 4 ] || fail "expected four independent compatibility entries"

# Y action unregisters only the BaseOS-generated compatibility and leaves the
# original program directory untouched; the tombstone prevents auto-regeneration.
run_manager uninstall-compat NextUI--default
[ -d "$TF1/Frontends/NextUI" ] || fail "compatibility-only uninstall deleted original program files"
[ ! -e "$SIDE" ] || fail "compatibility-only uninstall left generated metadata"
[ -f "$TF1/.baseos/compat-disabled/NextUI" ] || fail "compatibility disable marker missing"
run_manager catalog
! grep -F -q 'NextUI--default|' "$CATALOG" || fail "disabled compatibility entry was regenerated"

# X action explicitly deletes the original program directory after the caller's
# confirmation, and also removes the sidecar and disabled marker.
rm -f "$TF1/.baseos/compat-disabled/NextUI"
run_manager catalog
grep -F -q 'NextUI--default|' "$CATALOG" || fail "compat entry did not return after re-enable"
run_manager delete-compat NextUI--default
[ ! -e "$TF1/Frontends/NextUI" ] || fail "full compatibility deletion left the original program directory"
[ ! -e "$TF1/.baseos/compat/NextUI" ] || fail "full compatibility deletion left sidecar metadata"
[ ! -e "$TF1/.baseos/compat-disabled/NextUI" ] || fail "full compatibility deletion left disable marker"
[ -d "$TF1/Frontends/NextUI-copy" ] || fail "deleting one copy removed another frontend"

echo "PASS: automatic legacy compatibility, independent full-copy installs, unregister and confirmed full deletion"
