#!/bin/sh
# BaseOS RG353PS launcher for the SDL2/KMSDRM Slot build.
#
# Managed package mode:
#   Frontends/<package-id>/{launch.sh,System or payload/System,profiles/}
#   Each package/profile gets a private .userdata bind mount while Games/ and
#   Saves/ remain on the shared DATA root.
#
# Legacy mode retains the historical card-root layout.
# baseos: volume-owned
# baseos: power-owned
set -eu

SDCARD="${BASEOS_CARD_ROOT:-${BASEOS_FRONTEND_ROOT:-/mnt/SDCARD}}"
PACKAGE_DIR="${BASEOS_PACKAGE_DIR:-}"
INSTANCE_DIR="${BASEOS_INSTANCE_DIR:-}"
PROFILE_ID="${BASEOS_PROFILE_ID:-}"
if [ -n "$PACKAGE_DIR" ]; then
  if [ -d "$PACKAGE_DIR/payload/System" ]; then
    SYSTEM="$PACKAGE_DIR/payload/System"
    AGS_ROOT="$PACKAGE_DIR/payload"
  elif [ -d "$PACKAGE_DIR/System" ]; then
    SYSTEM="$PACKAGE_DIR/System"
    AGS_ROOT="$PACKAGE_DIR"
  else
    echo "Slot package has no System directory: $PACKAGE_DIR" >&2
    exit 127
  fi
else
  SYSTEM="$SDCARD/System"
  AGS_ROOT="$SDCARD"
fi

if [ -n "$PACKAGE_DIR" ] && [ -n "$INSTANCE_DIR" ]; then
  LOGDIR="$INSTANCE_DIR/logs"
else
  LOGDIR="$SDCARD/Logs"
fi
mkdir -p "$LOGDIR" "$SDCARD/Games" "$SDCARD/Saves" 2>/dev/null || :
export SLOT_ROOT="$SDCARD"
export AGS_ROOT
export AGS_NET_MODULE=rtw88_8821cs
export BASEOS_TARGET=rg353ps
export BASEOS_MODEL=rg353ps
export BASEOS_PANEL_ROTATION_CCW=0
export BASEOS_SLEEP=/usr/sbin/rg353ps-sleep
export SDL_VIDEODRIVER=kmsdrm
export SDL_AUDIODRIVER=alsa
export SDL_JOYSTICK_DISABLE_UDEV=1
export SDL_HIDAPI_JOYSTICK_DISABLE_UDEV=1
export BASEOS_PROFILE_ID="$PROFILE_ID"
export LD_LIBRARY_PATH="$SYSTEM/lib:$SYSTEM:/usr/lib:/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if [ ! -f "$SYSTEM/slot" ]; then
  echo "Slot binary missing: $SYSTEM/slot" >> "$LOGDIR/slot.log"
  exit 127
fi

# On exFAT, executable mode bits are not a reliable property of extracted
# files. Stage the executable on tmpfs before running it.
RUNTIME_SLOT="/tmp/baseos-slot-$${PROFILE_ID:-legacy}"
if ! cp "$SYSTEM/slot" "$RUNTIME_SLOT"; then
  echo "Could not stage Slot binary to $RUNTIME_SLOT" >> "$LOGDIR/slot.log"
  exit 126
fi
chmod 0755 "$RUNTIME_SLOT" || {
  echo "Could not make staged Slot binary executable" >> "$LOGDIR/slot.log"
  exit 126
}

SLOT_USERDATA_MOUNTED=no
SLOT_USERDATA_TARGET=
SLOT_USERDATA_DIR=
SLOT_PID=
cleanup_slot_profile() {
  if [ -n "$SLOT_PID" ]; then
    kill "$SLOT_PID" 2>/dev/null || :
    wait "$SLOT_PID" 2>/dev/null || :
    SLOT_PID=
  fi
  if [ "$SLOT_USERDATA_MOUNTED" = yes ] && [ -n "$SLOT_USERDATA_TARGET" ]; then
    umount "$SLOT_USERDATA_TARGET" 2>/dev/null || {
      echo "WARNING: could not unmount profile userdata at $SLOT_USERDATA_TARGET" >> "$LOGDIR/slot-session.log"
    }
    SLOT_USERDATA_MOUNTED=no
  fi
}
trap cleanup_slot_profile EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "$PACKAGE_DIR" ] && [ -n "$INSTANCE_DIR" ]; then
  SLOT_USERDATA_DIR="$INSTANCE_DIR/userdata/slot"
  SLOT_USERDATA_TARGET="$SDCARD/.userdata"
  mkdir -p "$SLOT_USERDATA_DIR" "$SLOT_USERDATA_TARGET" 2>/dev/null || {
    echo "Could not create profile userdata directories" >> "$LOGDIR/slot-session.log"
    exit 1
  }

  # Each new profile starts from a copy of any legacy .userdata tree exactly
  # once. Later writes go to the profile's own directory and cannot cross-talk.
  SEED_MARKER="$INSTANCE_DIR/config/slot-userdata-seeded"
  if [ ! -e "$SEED_MARKER" ]; then
    if [ -d "$SLOT_USERDATA_TARGET" ]; then
      cp -a "$SLOT_USERDATA_TARGET/." "$SLOT_USERDATA_DIR/" 2>/dev/null || {
        echo "Could not seed profile userdata from legacy .userdata" >> "$LOGDIR/slot-session.log"
        exit 1
      }
    fi
    : > "$SEED_MARKER"
  fi

  if grep -q " $SLOT_USERDATA_TARGET " /proc/mounts 2>/dev/null; then
    echo "Another profile userdata mount is still active at $SLOT_USERDATA_TARGET" >> "$LOGDIR/slot-session.log"
    exit 1
  fi
  if ! mount --bind "$SLOT_USERDATA_DIR" "$SLOT_USERDATA_TARGET"; then
    echo "Could not bind profile userdata to $SLOT_USERDATA_TARGET" >> "$LOGDIR/slot-session.log"
    exit 1
  fi
  SLOT_USERDATA_MOUNTED=yes
fi

# The root path stays on the shared card for Games/ and Saves/. The profile
# userdata bind above isolates Slot's own settings, lists, favorites and cache.
"$RUNTIME_SLOT" --init-root "$SDCARD" >> "$LOGDIR/slot-session.log" 2>&1 || {
  echo "Slot root initialization failed at $(date)" >> "$LOGDIR/slot-session.log"
  exit 1
}

echo "BaseOS RG353PS Slot launch: $(date) profile=${PROFILE_ID:-legacy}" >> "$LOGDIR/slot-session.log"
if [ -n "$PACKAGE_DIR" ]; then
  "$RUNTIME_SLOT" >> "$LOGDIR/slot.log" 2>&1 &
  SLOT_PID=$!
  if wait "$SLOT_PID"; then
    SLOT_STATUS=0
  else
    SLOT_STATUS=$?
  fi
  SLOT_PID=
  exit "$SLOT_STATUS"
fi

# Preserve the legacy exec contract: BaseOS supervises the Slot process itself.
exec "$RUNTIME_SLOT" >> "$LOGDIR/slot.log" 2>&1
