#!/bin/sh
# BaseOS RG353PS launcher for the SDL2/KMSDRM Slot build.
#
# Managed package:
#   Frontends/<package-id>/{launch.sh,payload/,profiles/}
# Each configuration profile receives its own SLOT_ROOT/.userdata, while
# Games/ and Saves/ are bind-mounted from the common DATA root.
#
# Legacy card-root installation keeps its original layout.
# baseos: volume-owned
# baseos: power-owned
set -eu

SDCARD="${BASEOS_CARD_ROOT:-${BASEOS_FRONTEND_ROOT:-/mnt/SDCARD}}"
PACKAGE_DIR="${BASEOS_PACKAGE_DIR:-}"
INSTANCE_DIR="${BASEOS_INSTANCE_DIR:-}"
PROFILE_ID="${BASEOS_PROFILE_ID:-}"
SLOT_ROOT=$SDCARD
AGS_ROOT=$SDCARD
SYSTEM=$SDCARD/System
LOGDIR=$SDCARD/Logs
SLOT_PAYLOAD_MOUNTED=no
SLOT_GAMES_MOUNTED=no
SLOT_SAVES_MOUNTED=no
SLOT_USERDATA_MOUNTED=no
SLOT_PID=
RUNTIME_SLOT="/tmp/baseos-slot-$${PROFILE_ID:-legacy}"

if [ -n "$PACKAGE_DIR" ]; then
  if [ -d "$PACKAGE_DIR/payload" ]; then
    SLOT_PAYLOAD_SOURCE=$PACKAGE_DIR/payload
  else
    SLOT_PAYLOAD_SOURCE=$PACKAGE_DIR
  fi
  SLOT_ROOT="${INSTANCE_DIR}/slot-root"
  AGS_ROOT=$SLOT_ROOT
  LOGDIR="$INSTANCE_DIR/logs"
  SYSTEM="$SLOT_ROOT/System"
  mkdir -p "$SLOT_ROOT" "$SDCARD/Games" "$SDCARD/Saves" "$LOGDIR" || :
  if ! mount --bind "$SLOT_PAYLOAD_SOURCE" "$SLOT_ROOT"; then
    echo "Could not expose package payload at $SLOT_ROOT" >> "$LOGDIR/slot-session.log"
    exit 1
  fi
  SLOT_PAYLOAD_MOUNTED=yes

  # Mount shared user content over the package's canonical content paths.
  # These directories are created inside the package payload only as empty
  # mount targets; actual ROMs and saves remain in the common DATA folders.
  mkdir -p "$SLOT_ROOT/Games" "$SLOT_ROOT/Saves" "$SLOT_ROOT/.userdata" || {
    echo "Could not prepare Slot shared-resource mount points" >> "$LOGDIR/slot-session.log"
    exit 1
  }
  if ! mount --bind "$SDCARD/Games" "$SLOT_ROOT/Games"; then
    echo "Could not bind shared Games directory" >> "$LOGDIR/slot-session.log"
    exit 1
  fi
  SLOT_GAMES_MOUNTED=yes
  if ! mount --bind "$SDCARD/Saves" "$SLOT_ROOT/Saves"; then
    echo "Could not bind shared Saves directory" >> "$LOGDIR/slot-session.log"
    exit 1
  fi
  SLOT_SAVES_MOUNTED=yes

  SLOT_USERDATA_DIR="$INSTANCE_DIR/userdata/slot"
  SLOT_USERDATA_TARGET="$SLOT_ROOT/.userdata"
  mkdir -p "$SLOT_USERDATA_DIR" || {
    echo "Could not create profile userdata directory" >> "$LOGDIR/slot-session.log"
    exit 1
  }
  SEED_MARKER="$INSTANCE_DIR/config/slot-userdata-seeded"
  if [ ! -e "$SEED_MARKER" ]; then
    # Preserve data from the existing root-level Slot install. If no previous
    # install exists, start with an empty profile rather than sharing defaults.
    if [ -d "$SDCARD/.userdata" ]; then
      cp -a "$SDCARD/.userdata/." "$SLOT_USERDATA_DIR/" 2>/dev/null || {
        echo "Could not seed profile userdata from legacy .userdata" >> "$LOGDIR/slot-session.log"
        exit 1
      }
    fi
    : > "$SEED_MARKER"
  fi
  if ! mount --bind "$SLOT_USERDATA_DIR" "$SLOT_USERDATA_TARGET"; then
    echo "Could not bind profile userdata at $SLOT_USERDATA_TARGET" >> "$LOGDIR/slot-session.log"
    exit 1
  fi
  SLOT_USERDATA_MOUNTED=yes
fi

mkdir -p "$LOGDIR" "$SDCARD/Games" "$SDCARD/Saves" 2>/dev/null || :
export SLOT_ROOT
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

# exFAT does not preserve executable bits reliably. Stage the binary on tmpfs.
if ! cp "$SYSTEM/slot" "$RUNTIME_SLOT"; then
  echo "Could not stage Slot binary to $RUNTIME_SLOT" >> "$LOGDIR/slot.log"
  exit 126
fi
chmod 0755 "$RUNTIME_SLOT" || {
  echo "Could not make staged Slot binary executable" >> "$LOGDIR/slot.log"
  exit 126
}

cleanup_slot_profile() {
  if [ -n "$SLOT_PID" ]; then
    kill "$SLOT_PID" 2>/dev/null || :
    wait "$SLOT_PID" 2>/dev/null || :
    SLOT_PID=
  fi
  # Unmount nested paths before the package payload mount.
  if [ "$SLOT_USERDATA_MOUNTED" = yes ]; then
    umount "$SLOT_ROOT/.userdata" 2>/dev/null || echo "WARNING: could not unmount profile userdata" >> "$LOGDIR/slot-session.log"
    SLOT_USERDATA_MOUNTED=no
  fi
  if [ "$SLOT_SAVES_MOUNTED" = yes ]; then
    umount "$SLOT_ROOT/Saves" 2>/dev/null || echo "WARNING: could not unmount shared Saves" >> "$LOGDIR/slot-session.log"
    SLOT_SAVES_MOUNTED=no
  fi
  if [ "$SLOT_GAMES_MOUNTED" = yes ]; then
    umount "$SLOT_ROOT/Games" 2>/dev/null || echo "WARNING: could not unmount shared Games" >> "$LOGDIR/slot-session.log"
    SLOT_GAMES_MOUNTED=no
  fi
  if [ "$SLOT_PAYLOAD_MOUNTED" = yes ]; then
    umount "$SLOT_ROOT" 2>/dev/null || echo "WARNING: could not unmount package payload" >> "$LOGDIR/slot-session.log"
    SLOT_PAYLOAD_MOUNTED=no
  fi
}
trap cleanup_slot_profile EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Initialize on the profile root: System comes from the package, ROMs/saves
# are shared mounts, and .userdata belongs to this selected configuration.
"$RUNTIME_SLOT" --init-root "$SLOT_ROOT" >> "$LOGDIR/slot-session.log" 2>&1 || {
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

# Preserve the old root-level exec path for legacy installations.
exec "$RUNTIME_SLOT" >> "$LOGDIR/slot.log" 2>&1
