#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/platforms/rg353ps/rootfs/usr/sbin/baseos-audio-init"

sh -n "$SCRIPT"

off_line=$(awk '/^[[:space:]]*pin_hardware off$/ { print NR; exit }' "$SCRIPT")
check_line=$(awk '/^if ! softvol_present; then$/ { print NR; exit }' "$SCRIPT")
open_line=$(awk '/aplay -q -D default -t raw -f S16_LE -r 48000 -c 2/ { print NR; exit }' "$SCRIPT")
mute_line=$(awk '/cset name="\$SOFTVOL_CTL" 0/ { print NR; exit }' "$SCRIPT")
on_line=$(awk 'NR > mute && /^pin_hardware$/ { print NR; exit }' mute="$mute_line" "$SCRIPT")
settle_line=$(awk 'NR > on && /^sleep 0\.1$/ { print NR; exit }' on="$on_line" "$SCRIPT")

[ -n "$off_line" ] && [ -n "$check_line" ] && [ -n "$open_line" ] && [ -n "$mute_line" ] && [ -n "$on_line" ] && [ -n "$settle_line" ] || {
    echo "missing audio initialization ordering markers" >&2
    exit 1
}
[ "$off_line" -lt "$check_line" ] && [ "$off_line" -lt "$open_line" ] || {
    echo "speaker endpoint must be off before softvol check and first PCM open" >&2
    exit 1
}
[ "$open_line" -lt "$mute_line" ] && [ "$mute_line" -lt "$on_line" ] || {
    echo "softvol must be at minimum before speaker endpoint is re-enabled" >&2
    exit 1
}
[ "$on_line" -lt "$settle_line" ] || {
    echo "speaker route must settle before restoring the normal volume" >&2
    exit 1
}
grep -Fq 'if [ -s "$STATE" ] && alsactl -f "$STATE" restore' "$SCRIPT"
if grep -Eq 'AUDIO_DIAG_SPEAKER_SWITCH_OFF|baseos-audio-diagnostic-speaker-off|skipped saved ALSA state restore' "$SCRIPT"; then
    echo "diagnostic-only permanent mute/restore suppression must not ship" >&2
    exit 1
fi
echo "PASS: speaker path is gated before PCM, attenuated before enable, then user volume/ALSA restore remain enabled"
