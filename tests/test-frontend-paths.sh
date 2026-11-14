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

echo "PASS: BaseOS path maps share frontend cores and preserve legacy ROM paths"
