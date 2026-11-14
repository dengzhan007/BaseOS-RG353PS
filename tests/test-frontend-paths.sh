#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/platforms/rg353ps/rootfs/usr/sbin/baseos-frontend-paths"
TMP=${TMPDIR:-/tmp}/baseos-frontend-paths-test-$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

CARD=$TMP/card
PROGRAM=$CARD/Frontends/NextUI
USERDATA=$PROGRAM/.baseos/userdata
mkdir -p "$PROGRAM/.system/h700/cores" "$PROGRAM/Tools/rg353ps" "$USERDATA" "$CARD/Games/FC"
: > "$PROGRAM/.system/h700/cores/.keep"
printf '%s\n' 'test-core-binary' > "$PROGRAM/.system/h700/cores/test_libretro.so"
: > "$PROGRAM/Tools/rg353ps/.keep"
printf '%s\n' "test-rom" > "$CARD/Games/FC/test.rom"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$HELPER" ] || fail "frontend path-map helper is missing"
sh "$HELPER" scan "$CARD" NextUI "$PROGRAM" || fail "initial path-map scan failed"

MAP=$CARD/.baseos/frontend-paths/NextUI.conf
[ -f "$MAP" ] || fail "BaseOS did not generate a path-map file"
grep -qx 'paths_api=1' "$MAP" || fail "path-map API version missing"
grep -qx 'frontend_id=NextUI' "$MAP" || fail "path-map frontend identity missing"
grep -qx 'games_target=Roms' "$MAP" || fail "legacy Roms target was not detected"
grep -qx 'system_target=.system' "$MAP" || fail "legacy .system target was not detected"
grep -qx 'tools_target=Tools' "$MAP" || fail "legacy Tools target was not detected"
grep -qx 'cores_target=.system/h700/cores' "$MAP" || fail "H700 core target was not detected"

# The scan is idempotent and must preserve user changes to the BaseOS-owned map.
printf '%s\n' '# user edit is preserved' >> "$MAP"
cp "$MAP" "$TMP/map.before"
sh "$HELPER" scan "$CARD" NextUI "$PROGRAM" || fail "repeat path-map scan failed"
cmp -s "$MAP" "$TMP/map.before" || fail "repeat scan overwrote the user's map edit"

# Apply only temporary frontend-facing aliases. The canonical Games and Saves
# trees remain the source of truth and are never copied or moved.
sh "$HELPER" apply "$CARD" "$PROGRAM" "$MAP" "$USERDATA" || fail "path-map apply failed"
[ -L "$CARD/Roms" ] || fail "Roms alias was not created"
[ "$(readlink "$CARD/Roms")" = "$CARD/Games" ] || fail "Roms does not point to canonical Games"
[ -L "$CARD/.system" ] || fail ".system alias was not created"
[ "$(readlink "$CARD/.system")" = "$PROGRAM/.system" ] || fail ".system does not point to the frontend's bundled system tree"
[ -L "$CARD/Tools" ] || fail "Tools alias was not created"
[ "$(readlink "$CARD/Tools")" = "$PROGRAM/Tools" ] || fail "Tools does not point to the frontend's bundled tools"
[ -L "$CARD/.userdata" ] || fail ".userdata alias was not created"
[ "$(readlink "$CARD/.userdata")" = "$USERDATA" ] || fail ".userdata does not point to the frontend-private userdata"
[ -f "$CARD/Roms/FC/test.rom" ] || fail "legacy Roms path cannot see the shared Games library"

# Cleanup removes only aliases created by this helper and preserves both
# frontend payload files and canonical shared game files.
sh "$HELPER" cleanup "$CARD" || fail "path-map cleanup failed"
for alias in Roms .system Tools .userdata; do
  [ ! -L "$CARD/$alias" ] || fail "temporary alias survived cleanup: $alias"
done
[ -f "$PROGRAM/.system/h700/cores/.keep" ] || fail "frontend system files were modified"
[ -f "$PROGRAM/Tools/rg353ps/.keep" ] || fail "frontend Tools files were modified"
[ -f "$CARD/Games/FC/test.rom" ] || fail "shared Games data was modified"
[ -f "$MAP" ] || fail "persistent path-map config was removed during cleanup"
[ -f "$CARD/.baseos/shared/cores/rg353ps/test_libretro.so" ] || fail "frontend core was not imported into the shared library"

sed 's/^games_target=.*/games_target=Games/' "$MAP" > "$MAP.tmp"
mv "$MAP.tmp" "$MAP"
mkdir -p "$CARD/Roms" "$CARD/ROMs" "$CARD/roms"
: > "$CARD/Roms/.keep"
: > "$CARD/ROMs/.keep"
: > "$CARD/roms/.keep"
sh "$HELPER" apply "$CARD" "$PROGRAM" "$MAP" "$USERDATA" || fail "Games-target compatibility apply failed"
for alias in Roms ROMs roms; do
  [ -L "$CARD/$alias" ] || fail "legacy ROM alias missing for games_target=Games: $alias"
  [ "$(readlink "$CARD/$alias")" = "$CARD/Games" ] || fail "$alias does not point to canonical Games"
  [ -f "$CARD/$alias/FC/test.rom" ] || fail "$alias cannot see the shared Games library"
done
sh "$HELPER" cleanup "$CARD" || fail "Games-target compatibility cleanup failed"
for alias in Roms ROMs roms; do
  [ ! -L "$CARD/$alias" ] || fail "temporary legacy ROM alias survived cleanup: $alias"
done

# A legacy frontend may live directly at the selected card root (for example,
# a root-installed NextUI layout). That is inside the card and must still get
# the ROM aliases; it must not be rejected as an external program path.
ROOT_CARD=$TMP/root-card
mkdir -p "$ROOT_CARD/.system/rg353ps/cores" "$ROOT_CARD/Tools" \
  "$ROOT_CARD/Games/FC" "$ROOT_CARD/.baseos/userdata"
printf '%s\\n' "root-layout-rom" > "$ROOT_CARD/Games/FC/root.rom"
sh "$HELPER" scan "$ROOT_CARD" NextUIRoot "$ROOT_CARD" || fail "root-layout path-map scan failed"
ROOT_MAP=$ROOT_CARD/.baseos/frontend-paths/NextUIRoot.conf
sh "$HELPER" apply "$ROOT_CARD" "$ROOT_CARD" "$ROOT_MAP" "$ROOT_CARD/.baseos/userdata" || \
  fail "root-installed frontend path-map apply failed"
[ -L "$ROOT_CARD/Roms" ] || fail "root-installed frontend did not get the Roms alias"
[ "$(readlink "$ROOT_CARD/Roms")" = "$ROOT_CARD/Games" ] || fail "root-layout Roms alias does not target Games"
[ -f "$ROOT_CARD/Roms/FC/root.rom" ] || fail "root-layout Roms alias cannot see shared Games"
sh "$HELPER" cleanup "$ROOT_CARD" || fail "root-layout path-map cleanup failed"
[ ! -L "$ROOT_CARD/Roms" ] || fail "root-layout temporary Roms alias survived cleanup"
[ -f "$ROOT_CARD/Games/FC/root.rom" ] || fail "root-layout cleanup modified shared Games"

# Simulate an exFAT card: symlink creation fails, so BaseOS must fall
# back to a bind-mounted alias. The fake mount command uses a symlink only as
# a test stand-in for the kernel mount operation.
FALLBACK_CARD=$TMP/fallback-card
FAKE_BIN=$TMP/fake-bin
mkdir -p "$FALLBACK_CARD/.system/rg353ps/cores" "$FALLBACK_CARD/Games/FC" \
  "$FALLBACK_CARD/Roms" "$FAKE_BIN"
printf '%s\\n' "fallback-rom" > "$FALLBACK_CARD/Games/FC/fallback.rom"
sh "$HELPER" scan "$FALLBACK_CARD" NextUIExfat "$FALLBACK_CARD" || \
  fail "exFAT fallback path-map scan failed"
FALLBACK_MAP=$FALLBACK_CARD/.baseos/frontend-paths/NextUIExfat.conf
cat > "$FAKE_BIN/ln" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-s" ]; then
  echo "ln: symbolic links not supported by test filesystem" >&2
  exit 1
fi
exec /bin/ln "$@"
EOF
cat > "$FAKE_BIN/mount" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--bind" ]; then
  source=$2
  target=$3
  rmdir "$target" 2>/dev/null || exit 1
  /bin/ln -s "$source" "$target"
  exit $?
fi
exec /bin/mount "$@"
EOF
chmod +x "$FAKE_BIN/ln" "$FAKE_BIN/mount"
# The production helper deliberately resets PATH; create a test-only copy with
# the fake command directory prepended to exercise the unsupported-symlink case.
FALLBACK_HELPER=$TMP/baseos-frontend-paths-fallback
sed "s#^PATH=/sbin:/bin:/usr/sbin:/usr/bin#PATH=$FAKE_BIN:/sbin:/bin:/usr/sbin:/usr/bin#" \
  "$HELPER" > "$FALLBACK_HELPER"
chmod +x "$FALLBACK_HELPER"
sh "$FALLBACK_HELPER" apply "$FALLBACK_CARD" "$FALLBACK_CARD" "$FALLBACK_MAP" || \
  fail "exFAT bind-mount fallback apply failed"
[ -L "$FALLBACK_CARD/Roms" ] || fail "exFAT fallback did not activate the ROM alias"
[ "$(readlink "$FALLBACK_CARD/Roms")" = "$FALLBACK_CARD/Games" ] || \
  fail "exFAT fallback ROM alias points to the wrong directory"
grep -F -q "B|$FALLBACK_CARD/Roms|$FALLBACK_CARD/Games" \
  "$FALLBACK_CARD/.baseos/frontend-paths/active" || \
  fail "exFAT fallback did not record bind-alias cleanup state"
# Simulate an interrupted/unmounted alias: cleanup must remove only the empty
# mountpoint left by the recorded bind alias and preserve the canonical ROM.
rm -f "$FALLBACK_CARD/Roms"
mkdir "$FALLBACK_CARD/Roms"
sh "$HELPER" cleanup "$FALLBACK_CARD" || fail "exFAT fallback stale-alias cleanup failed"
[ ! -e "$FALLBACK_CARD/Roms" ] || fail "exFAT fallback cleanup left an empty mountpoint"
[ -f "$FALLBACK_CARD/Games/FC/fallback.rom" ] || \
  fail "exFAT fallback cleanup modified canonical Games data"

echo "PASS: BaseOS path maps share frontend cores and preserve legacy ROM paths"
