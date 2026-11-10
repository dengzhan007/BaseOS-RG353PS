#!/bin/sh
# Regression test for first-boot USB profile inheritance.
#
# This test exercises the REAL ensure_card_config() from baseos-init-userdata
# and the REAL config_value() from baseos-usb-debug. Both function bodies are
# extracted verbatim from the production scripts; only the three hard-coded
# config file paths in config_value() are redirected into a temporary sandbox.
# Nothing here reads or writes the real /mnt/SDCARD, /mnt/boot or /etc.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
USB="$ROOT/platforms/rg353ps"
INIT="$USB/rootfs/usr/sbin/baseos-init-userdata"
DBG="$USB/rootfs/usr/sbin/baseos-usb-debug"
ETC_SOURCE="$USB/rootfs/etc/baseos.conf"

# Always build the sandbox under a POSIX path. Some Git Bash installations
# honour a Windows-style TMPDIR (C:\\...), which breaks the path substitution
# used to redirect config_value() into the sandbox.
TMP="$(mktemp -d /tmp/rg353ps-usb-profile.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PASS=0
FAIL=0
ok() { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
eq() { # name got want
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got='$2' want='$3')"; fi
}

# --- Extract the real production functions ---------------------------------
sed -n '/^ensure_card_config()/,/^}/p' "$INIT" > "$TMP/ensure.sh"
sed -n '/^config_value()/,/^}/p' "$DBG" > "$TMP/config_value.raw"
grep -Fq 'cat > "$USERDATA/baseos.conf"' "$TMP/ensure.sh" || {
    echo "could not extract the real ensure_card_config()" >&2; exit 1; }
grep -Fq 'for cfg in /mnt/SDCARD/baseos.conf' "$TMP/config_value.raw" || {
    echo "could not extract the real config_value()" >&2; exit 1; }

# Build a resolver that uses the real config_value() body with the three
# absolute paths redirected to sandbox files.
make_resolver() { # card boot etc
    sed -e "s#/mnt/SDCARD/baseos.conf#$1#g" \
        -e "s#/mnt/boot/baseos.conf#$2#g" \
        -e "s#/etc/baseos.conf#$3#g" \
        "$TMP/config_value.raw" > "$TMP/config_value.sh"
}

resolve() { # key card boot etc
    make_resolver "$2" "$3" "$4"
    {
        cat "$TMP/config_value.sh"
        printf 'config_value "%s"\n' "$1"
    } > "$TMP/resolve.sh"
    sh "$TMP/resolve.sh"
}

seed() { # card_dir -- runs the REAL ensure_card_config()
    {
        printf 'USERDATA="%s"\n' "$1"
        printf 'log() { :; }\n'
        cat "$TMP/ensure.sh"
        printf 'ensure_card_config\n'
    } > "$TMP/seed.sh"
    sh "$TMP/seed.sh"
}

active_line() { # key file
    grep -E "^[[:space:]]*$1[[:space:]]*=" "$2" 2>/dev/null | tail -1 || :
}

# --- 1. Fresh-card seed must not contain an active ssh_debug / usb_mtp -----
mkdir -p "$TMP/card1"
seed "$TMP/card1"
CARD1="$TMP/card1/baseos.conf"
[ -s "$CARD1" ] || { echo "seed produced no card config" >&2; exit 1; }
eq "1 fresh card seed has no active ssh_debug" "$(active_line ssh_debug "$CARD1")" ""
eq "1 fresh card seed has no active usb_mtp" "$(active_line usb_mtp "$CARD1")" ""
if grep -Eq '^#[[:space:]]*ssh_debug=yes' "$CARD1"; then
    ok "1 seed keeps ssh_debug=yes as a commented example"
else
    bad "1 seed lost the commented ssh_debug example"
fi
if grep -Fq 'debug=no' "$CARD1"; then
    ok "1 seed keeps existing debug=no setting"
else
    bad "1 seed dropped debug=no"
fi

# --- Build development / release image configs from the real /etc template --
sed -e 's/^usb_profile=.*/usb_profile=development/' \
    -e 's/^ssh_debug=.*/ssh_debug=yes/' \
    -e 's/^usb_mtp=.*/usb_mtp=yes/' "$ETC_SOURCE" > "$TMP/etc_development"
sed -e 's/^usb_profile=.*/usb_profile=release/' \
    -e 's/^ssh_debug=.*/ssh_debug=no/' \
    -e 's/^usb_mtp=.*/usb_mtp=yes/' "$ETC_SOURCE" > "$TMP/etc_release"
: > "$TMP/boot_absent"
eq "2 development image config really says ssh_debug=yes" \
   "$(active_line ssh_debug "$TMP/etc_development" | sed 's/.*=//')" "yes"
eq "3 release image config really says ssh_debug=no" \
   "$(active_line ssh_debug "$TMP/etc_release" | sed 's/.*=//')" "no"

# --- 2/3. Fresh card inherits the image profile ---------------------------
eq "2 development + fresh card resolves ssh_debug=yes" \
   "$(resolve ssh_debug "$CARD1" "$TMP/boot_absent" "$TMP/etc_development")" "yes"
eq "3 release + fresh card resolves ssh_debug=no" \
   "$(resolve ssh_debug "$CARD1" "$TMP/boot_absent" "$TMP/etc_release")" "no"

# --- 4/5. Explicit card values still win in BOTH directions ----------------
mkdir -p "$TMP/card_yes" "$TMP/card_no"
printf 'debug=no\nusb_debug=yes\n' > "$TMP/card_yes/baseos.conf"
printf 'debug=no\nusb_debug=no\n' > "$TMP/card_no/baseos.conf"
eq "4 card ssh_debug=yes overrides release image no" \
   "$(resolve ssh_debug "$TMP/card_yes/baseos.conf" "$TMP/boot_absent" "$TMP/etc_release")" "yes"
eq "5 card ssh_debug=no overrides development image yes" \
   "$(resolve ssh_debug "$TMP/card_no/baseos.conf" "$TMP/boot_absent" "$TMP/etc_development")" "no"

# --- 6. usb_mtp inherits the image when the card leaves it unset ------------
eq "6a usb_mtp inherits image yes" \
   "$(resolve usb_mtp "$CARD1" "$TMP/boot_absent" "$TMP/etc_release")" "yes"
sed 's/^usb_mtp=.*/usb_mtp=no/' "$TMP/etc_release" > "$TMP/etc_release_nomtp"
eq "6b usb_mtp inherits image no" \
   "$(resolve usb_mtp "$CARD1" "$TMP/boot_absent" "$TMP/etc_release_nomtp")" "no"
mkdir -p "$TMP/card_mtp_no"
printf 'debug=no\nusb_mtp=no\n' > "$TMP/card_mtp_no/baseos.conf"
eq "6c explicit card usb_mtp=no still overrides image yes" \
   "$(resolve usb_mtp "$TMP/card_mtp_no/baseos.conf" "$TMP/boot_absent" "$TMP/etc_release")" "no"

# --- 7. An existing non-empty card config is never rewritten ---------------
mkdir -p "$TMP/card_existing"
printf '# owner-owned config\ndebug=yes\nusb_debug=no\nusb_mtp=no\n' > "$TMP/card_existing/baseos.conf"
BEFORE="$(sha256sum "$TMP/card_existing/baseos.conf" | cut -d' ' -f1)"
seed "$TMP/card_existing"
AFTER="$(sha256sum "$TMP/card_existing/baseos.conf" | cut -d' ' -f1)"
eq "7 existing non-empty card config is byte-identical after seeding" "$AFTER" "$BEFORE"
eq "7 existing card ssh_debug=no is preserved" \
   "$(resolve ssh_debug "$TMP/card_existing/baseos.conf" "$TMP/boot_absent" "$TMP/etc_development")" "no"

# --- 8. Sandbox-only: no real mount point was touched ----------------------
case "$TMP" in
    /tmp/*|/var/tmp/*) ok "8 tests run inside a temporary sandbox ($TMP)" ;;
    *) bad "8 unexpected temp root: $TMP" ;;
esac
if grep -nE '(>|>>|cp |mv |rm )[[:space:]]*"?/(mnt/SDCARD|mnt/boot|etc)/baseos\.conf' "$TMP/seed.sh" >/dev/null 2>&1; then
    bad "8 seed harness attempted to write a real mount point"
else
    ok "8 seed harness writes only into the sandbox"
fi
eq "8 resolver uses redirected paths" \
   "$(grep -c '/mnt/SDCARD/baseos.conf' "$TMP/config_value.sh" || :)" "0"

printf '\nRan %d checks: %d passed, %d failed\n' "$((PASS + FAIL))" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "RG353PS USB profile inheritance regression checks passed"
