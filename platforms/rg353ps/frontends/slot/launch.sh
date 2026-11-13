#!/bin/sh
# BaseOS RG353PS launcher for the SDL2/KMSDRM Slot build.
#
# Managed package:
#   Frontends/<package-id>/{launch.sh,payload/,profiles/}
# Each profile gets an isolated SLOT_ROOT/.userdata; Games/ and Saves/ are
# bind-mounted from the common DATA root and therefore stay shared.
# Legacy card-root installations retain their original layout.
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
SLOT_STATE_MOUNTED=no
SLOT_STATES_MOUNTED=no
SLOT_CORE_LIB_MOUNTED=no
SLOT_SYSTEM_BIND_TARGETS=
SLOT_CORE_BIND_TARGETS=
SLOT_PID=
RUNTIME_SLOT="/tmp/baseos-slot-$${PROFILE_ID:-legacy}"

if [ -n "$PACKAGE_DIR" ]; then
  LOGDIR="$INSTANCE_DIR/logs"
  mkdir -p "$LOGDIR" 2>/dev/null || :

  # The managed package ID changes from slot-rg353ps to LUCKLUCK-SLOT when
  # the distribution folder is renamed. Preserve every existing profile's
  # settings and save states by copying its old instance once. Keep the old
  # directory as a rollback copy; never delete user data during migration.
  if [ "${BASEOS_PACKAGE_ID:-}" = "LUCKLUCK-SLOT" ] &&
     [ -n "$PROFILE_ID" ] && [ -d "$INSTANCE_DIR" ] && [ ! -L "$INSTANCE_DIR" ]; then
    LEGACY_INSTANCE_DIR="$SDCARD/.baseos/instances/slot-rg353ps--$PROFILE_ID"
    MIGRATION_MARKER="$INSTANCE_DIR/config/migrated-from-slot-rg353ps"
    if [ -d "$LEGACY_INSTANCE_DIR" ] && [ ! -L "$LEGACY_INSTANCE_DIR" ] &&
       [ ! -e "$MIGRATION_MARKER" ]; then
      mkdir -p "$INSTANCE_DIR/config"
      EXISTING_PROFILE_FILE="$INSTANCE_DIR/config/profile.conf"
      SAVED_PROFILE_FILE=
      if [ -f "$EXISTING_PROFILE_FILE" ]; then
        SAVED_PROFILE_FILE="$INSTANCE_DIR/config/profile.conf.migration-save.$"
        cp -p "$EXISTING_PROFILE_FILE" "$SAVED_PROFILE_FILE" || {
          echo "Could not preserve new profile metadata before package migration" >> "$LOGDIR/slot-session.log"
          exit 1
        }
      fi
      EXISTING_NEW_DATA=$(find "$INSTANCE_DIR" -type f \
        ! -path "$EXISTING_PROFILE_FILE" \
        ! -path "$MIGRATION_MARKER" -print -quit 2>/dev/null || :)
      if [ -z "$EXISTING_NEW_DATA" ]; then
        cp -a "$LEGACY_INSTANCE_DIR/." "$INSTANCE_DIR/" 2>/dev/null || {
          echo "Could not migrate legacy Slot instance data from $LEGACY_INSTANCE_DIR" >> "$LOGDIR/slot-session.log"
          [ -z "$SAVED_PROFILE_FILE" ] || mv -f "$SAVED_PROFILE_FILE" "$EXISTING_PROFILE_FILE"
          exit 1
        }
        if [ -n "$SAVED_PROFILE_FILE" ]; then
          mv -f "$SAVED_PROFILE_FILE" "$EXISTING_PROFILE_FILE" || {
            echo "Could not restore current profile metadata after instance migration" >> "$LOGDIR/slot-session.log"
            exit 1
          }
        fi
        : > "$MIGRATION_MARKER"
        sync
        echo "Migrated Slot profile data from legacy package identity: $PROFILE_ID" >> "$LOGDIR/slot-session.log"
      else
        [ -z "$SAVED_PROFILE_FILE" ] || rm -f "$SAVED_PROFILE_FILE"
        : > "$MIGRATION_MARKER"
        echo "Skipped legacy Slot data migration because the new profile instance already contains data: $PROFILE_ID" >> "$LOGDIR/slot-session.log"
      fi
    fi
  fi
fi

cleanup_slot_profile() {
  if [ -n "$SLOT_PID" ]; then
    kill "$SLOT_PID" 2>/dev/null || :
    wait "$SLOT_PID" 2>/dev/null || :
    SLOT_PID=
  fi
  if [ "$SLOT_USERDATA_MOUNTED" = yes ]; then
    umount "$SLOT_ROOT/.userdata" 2>/dev/null || echo "WARNING: could not unmount profile userdata" >> "$LOGDIR/slot-session.log"
    SLOT_USERDATA_MOUNTED=no
  fi
  if [ "$SLOT_STATE_MOUNTED" = yes ]; then
    umount "$SLOT_ROOT/System/slot.state" 2>/dev/null || echo "WARNING: could not unmount profile slot.state" >> "$LOGDIR/slot-session.log"
    SLOT_STATE_MOUNTED=no
  fi
  for system_target in $SLOT_SYSTEM_BIND_TARGETS; do
    umount "$system_target" 2>/dev/null || echo "WARNING: could not unmount profile system state $system_target" >> "$LOGDIR/slot-session.log"
  done
  SLOT_SYSTEM_BIND_TARGETS=
  if [ "$SLOT_STATES_MOUNTED" = yes ]; then
    umount "$SLOT_ROOT/States" 2>/dev/null || echo "WARNING: could not unmount profile save states" >> "$LOGDIR/slot-session.log"
    SLOT_STATES_MOUNTED=no
  fi
  for core_target in $SLOT_CORE_BIND_TARGETS; do
    umount "$core_target" 2>/dev/null || echo "WARNING: could not unmount shared core $core_target" >> "$LOGDIR/slot-session.log"
  done
  SLOT_CORE_BIND_TARGETS=
  if [ "$SLOT_CORE_LIB_MOUNTED" = yes ]; then
    umount "$SLOT_ROOT/System/lib" 2>/dev/null || echo "WARNING: could not unmount shared core libraries" >> "$LOGDIR/slot-session.log"
    SLOT_CORE_LIB_MOUNTED=no
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

if [ -n "$PACKAGE_DIR" ]; then
  [ -n "$INSTANCE_DIR" ] || {
    echo "Managed Slot package has no profile instance directory" >> "$LOGDIR/slot-session.log"
    exit 1
  }
  if [ -d "$PACKAGE_DIR/payload" ]; then
    SLOT_PAYLOAD_SOURCE=$PACKAGE_DIR/payload
  else
    SLOT_PAYLOAD_SOURCE=$PACKAGE_DIR
  fi
  SLOT_ROOT="$INSTANCE_DIR/slot-root"
  AGS_ROOT=$SLOT_ROOT
  SYSTEM="$SLOT_ROOT/System"
  mkdir -p "$SLOT_ROOT" "$SDCARD/Games" "$SDCARD/Saves" || {
    echo "Could not create managed Slot mount roots" >> "$LOGDIR/slot-session.log"
    exit 1
  }
  if ! mount --bind "$SLOT_PAYLOAD_SOURCE" "$SLOT_ROOT"; then
    echo "Could not expose package payload at $SLOT_ROOT" >> "$LOGDIR/slot-session.log"
    exit 1
  fi
  SLOT_PAYLOAD_MOUNTED=yes

  # These empty directories are mount targets inside the package root. ROMs
  # and saves are never copied into the frontend package.
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

  # Per-profile application state must not live in the shared package payload.
  # Slot stores favourites and frontend preferences in System/slot.state; the
  # other files below hold visual/input configuration and the derived library
  # cache. Bind each file to this profile's persistent System directory.
  PROFILE_SYSTEM_DIR="$INSTANCE_DIR/system"
  mkdir -p "$PROFILE_SYSTEM_DIR" "$INSTANCE_DIR/config" "$SLOT_ROOT/System" || {
    echo "Could not prepare profile system state" >> "$LOGDIR/slot-session.log"
    exit 1
  }
  mount_profile_system_file() {
    state_name=$1
    state_source="$PROFILE_SYSTEM_DIR/$state_name"
    state_target="$SLOT_ROOT/System/$state_name"
    if [ ! -f "$state_source" ]; then
      # Seed each profile once from an old card-root installation when
      # available; otherwise copy the package's default state file.
      if [ -f "$SDCARD/System/$state_name" ] && [ ! -L "$SDCARD/System/$state_name" ]; then
        cp -p "$SDCARD/System/$state_name" "$state_source" || {
          echo "Could not migrate legacy Slot state: $state_name" >> "$LOGDIR/slot-session.log"
          exit 1
        }
      elif [ -f "$state_target" ] && [ ! -L "$state_target" ]; then
        cp -p "$state_target" "$state_source" || {
          echo "Could not seed profile Slot state: $state_name" >> "$LOGDIR/slot-session.log"
          exit 1
        }
      else
        : > "$state_source"
      fi
    fi
    [ -e "$state_target" ] || : > "$state_target"
    mount --bind "$state_source" "$state_target" || {
      echo "Could not bind profile Slot state: $state_name" >> "$LOGDIR/slot-session.log"
      exit 1
    }
    SLOT_SYSTEM_BIND_TARGETS="$state_target $SLOT_SYSTEM_BIND_TARGETS"
  }
  # Keep legacy System/ state files available as read-only migration
  # fallbacks. Slot's main state and its cache now write below the directory-
  # mounted .userdata tree: their atomic temp-file + rename writes must not
  # target a single-file bind mount.
  for state_name in slot.state theme.txt mask.txt overlay.txt shelf.txt cc.txt \
                    display.txt audio.txt open.txt selected_core.ini library.cache \
                    palette.v2 display.v2; do
    mount_profile_system_file "$state_name"
  done

  # Save states are rewind/resume snapshots, not the shared battery saves
  # under Saves/. Keep snapshots in each profile's instance directory.
  PROFILE_STATES_DIR="$INSTANCE_DIR/states"
  mkdir -p "$PROFILE_STATES_DIR" "$SLOT_ROOT/States" || {
    echo "Could not prepare profile save-state directory" >> "$LOGDIR/slot-session.log"
    exit 1
  }
  STATES_SEED_MARKER="$INSTANCE_DIR/config/slot-states-seeded"
  if [ ! -e "$STATES_SEED_MARKER" ]; then
    if [ -d "$SDCARD/States" ]; then
      cp -a "$SDCARD/States/." "$PROFILE_STATES_DIR/" 2>/dev/null || {
        echo "Could not migrate legacy save states" >> "$LOGDIR/slot-session.log"
        exit 1
      }
    elif [ -d "$SLOT_ROOT/States" ]; then
      cp -a "$SLOT_ROOT/States/." "$PROFILE_STATES_DIR/" 2>/dev/null || {
        echo "Could not seed profile save states" >> "$LOGDIR/slot-session.log"
        exit 1
      }
    fi
    : > "$STATES_SEED_MARKER"
  fi
  if ! mount --bind "$PROFILE_STATES_DIR" "$SLOT_ROOT/States"; then
    echo "Could not bind profile save-state directory" >> "$LOGDIR/slot-session.log"
    exit 1
  fi
  SLOT_STATES_MOUNTED=yes

  # Existing LUCKLUCK-SLOT installs keep emulator cores in the DATA-root
  # System/ directory. Prefer the future BaseOS shared core namespace when it
  # is populated; otherwise bind the already-installed core pack into this
  # profile root. Each profile therefore sees one shared copy of each core.
  SLOT_CORE_SOURCE="$SDCARD/.baseos/shared/cores/slot-rg353ps"
  SLOT_CORE_PACK_FOUND=no
  for candidate_core in "$SLOT_CORE_SOURCE"/*_libretro.so; do
    [ -f "$candidate_core" ] || continue
    SLOT_CORE_PACK_FOUND=yes
    break
  done
  [ "$SLOT_CORE_PACK_FOUND" = yes ] || SLOT_CORE_SOURCE="$SDCARD/System"
  if [ -d "$SLOT_CORE_SOURCE/lib" ]; then
    mkdir -p "$SLOT_ROOT/System/lib"
    if mount --bind "$SLOT_CORE_SOURCE/lib" "$SLOT_ROOT/System/lib"; then
      SLOT_CORE_LIB_MOUNTED=yes
    else
      echo "Could not bind shared core dependency directory" >> "$LOGDIR/slot-session.log"
      exit 1
    fi
  fi
  for core_name in mgba gpsp fceumm supafaust fbneo genesis_plus_gx pcsx_rearmed pce_fast; do
    core_source="$SLOT_CORE_SOURCE/${core_name}_libretro.so"
    [ -f "$core_source" ] || continue
    core_target="$SLOT_ROOT/System/${core_name}_libretro.so"
    [ -e "$core_target" ] || : > "$core_target"
    if mount --bind "$core_source" "$core_target"; then
      SLOT_CORE_BIND_TARGETS="$core_target $SLOT_CORE_BIND_TARGETS"
    else
      echo "Could not bind shared emulator core: $core_name" >> "$LOGDIR/slot-session.log"
      exit 1
    fi
  done

  SLOT_USERDATA_DIR="$INSTANCE_DIR/userdata/slot"
  SLOT_USERDATA_TARGET="$SLOT_ROOT/.userdata"
  mkdir -p "$SLOT_USERDATA_DIR" || {
    echo "Could not create profile userdata directory" >> "$LOGDIR/slot-session.log"
    exit 1
  }
  SEED_MARKER="$INSTANCE_DIR/config/slot-userdata-seeded"
  if [ ! -e "$SEED_MARKER" ]; then
    # One-time migration from an older root-level Slot installation.
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
