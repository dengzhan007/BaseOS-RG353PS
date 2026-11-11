#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/platforms/rg353ps/rootfs/usr/sbin/baseos-audio-init"

sh -n "$SCRIPT"

off_line=$(awk '/^[[:space:]]*pin_hardware off$/ { print NR; exit }' "$SCRIPT")
warmup_line=$(awk '/^if ! softvol_present; then$/ { print NR; exit }' "$SCRIPT")
open_line=$(awk '/aplay -q -D default -t raw -f S16_LE -r 48000 -c 2/ { print NR; exit }' "$SCRIPT")
on_line=$(awk 'NR > warmup && /^pin_hardware$/ { print NR; exit }' warmup="$warmup_line" "$SCRIPT")

[ -n "$off_line" ] && [ -n "$warmup_line" ] && [ -n "$open_line" ] && [ -n "$on_line" ] || {
    echo "missing audio initialization ordering markers" >&2
    exit 1
}
[ "$warmup_line" -lt "$off_line" ] || {
    echo "speaker switch must be gated inside the first-softvol initialization block" >&2
    exit 1
}
[ "$off_line" -lt "$open_line" ] || {
    echo "speaker switch must be off before the first PCM open" >&2
    exit 1
}
[ "$open_line" -lt "$on_line" ] || {
    echo "normal speaker output must be restored after PCM warm-up" >&2
    exit 1
}

grep -Fq 'speaker_switch=${1:-on}' "$SCRIPT"
grep -Fq 'switch_value=$speaker_switch' "$SCRIPT"
grep -Fq 'if [ -s "$STATE" ] && alsactl -f "$STATE" restore' "$SCRIPT"

if grep -Eq 'AUDIO_DIAG_SPEAKER_SWITCH_OFF|baseos-audio-diagnostic-speaker-off|skipped saved ALSA state restore' "$SCRIPT"; then
    echo "diagnostic-only permanent mute/restore suppression must not ship" >&2
    exit 1
fi

echo "PASS: first PCM opens with internal speaker switch off, then normal output and ALSA restore remain enabled"
