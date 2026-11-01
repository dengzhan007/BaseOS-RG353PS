#!/bin/sh
# BaseOS RG353PS launcher for the SDL2/KMSDRM Slot build.
#
# This frontend owns the power key. It draws its own shutdown screen and flushes
# its saves before powering off, which is what a handheld user expects from a
# hold, and nothing behind it can produce that picture. A tap still suspends the
# whole unit: BASEOS_SLEEP points Slot's doze at rg353ps-sleep, so the tap costs
# a real s2idle instead of a dark panel over a running CPU. rg353ps-hotkeyd sees
# the marker below and keeps its hands off the key while this frontend runs.
# baseos: power-owned
set -eu

SDCARD="${BASEOS_FRONTEND_ROOT:-/mnt/SDCARD}"
SYSTEM="$SDCARD/System"
LOGDIR="$SDCARD/Logs"

mkdir -p "$LOGDIR" "$SDCARD/Games" "$SDCARD/Saves" 2>/dev/null || :
export SLOT_ROOT="$SDCARD"
export BASEOS_TARGET=rg353ps
export BASEOS_MODEL=rg353ps
export BASEOS_PANEL_ROTATION_CCW=0
# Slot runs this when a tap puts the unit to sleep. It blocks until the button
# wakes the unit, which is exactly the contract doze() expects.
export BASEOS_SLEEP=/usr/sbin/rg353ps-sleep
export SDL_VIDEODRIVER=kmsdrm
export SDL_AUDIODRIVER=alsa
export SDL_JOYSTICK_DISABLE_UDEV=1
export SDL_HIDAPI_JOYSTICK_DISABLE_UDEV=1
export LD_LIBRARY_PATH="$SYSTEM/lib:$SYSTEM:/usr/lib:/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if [ ! -f "$SYSTEM/slot" ]; then
  echo "Slot binary missing: $SYSTEM/slot" >> "$LOGDIR/slot.log"
  exit 127
fi

# Windows/exFAT user partitions may not preserve Unix executable bits and
# do not provide a POSIX chmod model. Stage the launcher binary onto writable
# tmpfs before executing it; ROMs, saves and cores stay on the user partition.
RUNTIME_SLOT="/tmp/baseos-slot"
if ! cp "$SYSTEM/slot" "$RUNTIME_SLOT"; then
  echo "Could not stage Slot binary to $RUNTIME_SLOT" >> "$LOGDIR/slot.log"
  exit 126
fi
chmod 0755 "$RUNTIME_SLOT" || {
  echo "Could not make staged Slot binary executable" >> "$LOGDIR/slot.log"
  exit 126
}

# Create missing content directories and migrate only Slot's own config if needed.
"$RUNTIME_SLOT" --init-root "$SDCARD" >> "$LOGDIR/slot-session.log" 2>&1 || {
  echo "Slot root initialization failed at $(date)" >> "$LOGDIR/slot-session.log"
  exit 1
}

echo "BaseOS RG353PS Slot launch: $(date)" >> "$LOGDIR/slot-session.log"
exec "$RUNTIME_SLOT" >> "$LOGDIR/slot.log" 2>&1
