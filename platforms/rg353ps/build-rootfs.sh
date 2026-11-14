#!/bin/sh
# Build the RG353PS BaseOS rootfs, including its diagnostic fallback UI and hardware tools.
# The Miyoo Flip stock-library harvest and all my355-specific scripts are excluded.
#
# ALPINE_MIRROR (optional): point apk at a mirror, e.g.
#   ALPINE_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.22 ./build-rootfs.sh
# Unset means the image default (dl-cdn.alpinelinux.org) is used. The value
# only changes /etc/apk/repositories inside the build container and the copy
# shipped in the target rootfs.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
. "$REPO_ROOT/tools/common.sh"

WORK="${RG353PS_WORK:-$REPO_ROOT/work/rg353ps}"
KERNEL_OUT="$WORK/kernel/output"
KERNEL_META="$KERNEL_OUT/kernel-build.json"
FIRMWARE_OUT="$WORK/firmware"
ROOTFS="$WORK/rootfs"
BASEOS_USB_PROFILE="${BASEOS_USB_PROFILE:-development}"
UMTP_COMMIT="d3fe71b68e9af5472e72a843cda2c31c20167231"
case "$BASEOS_USB_PROFILE" in
  development|release) ;;
  *) echo "BASEOS_USB_PROFILE must be development or release" >&2; exit 1 ;;
esac

for cmd in docker python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 1; }
done
[ -s "$KERNEL_META" ] || { echo "missing $KERNEL_META (run ./platforms/rg353ps/build-kernel.sh)" >&2; exit 1; }
[ -s "$FIRMWARE_OUT/firmware-manifest.txt" ] || "$HERE/build-firmware.sh"

KREL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kernel_release"])' "$KERNEL_META")"

# Release identity. /etc/baseos-release carries these two lines, and the update
# payload's manifest must agree with them or mkupdate.py refuses to build — a
# payload that claims a version the filesystem does not carry would be applied
# on every boot.
BASEOS_VERSION="$(tr -d ' \n' < "$REPO_ROOT/VERSION")"
[ -n "$BASEOS_VERSION" ] || { echo "VERSION is empty" >&2; exit 1; }
BASEOS_BUILD="$(git -C "$REPO_ROOT" describe --always --dirty 2>/dev/null || echo unknown)"
case "$BASEOS_BUILD" in *-dirty) BASEOS_BUILD="$BASEOS_BUILD-$(date -u +%Y%m%d%H%M%S)" ;; esac
mkdir -p "$WORK"
printf '%s\n' "$BASEOS_BUILD" > "$WORK/build-id"
MODULES_TARBALL="$KERNEL_OUT/modules-$KREL.tar.zst"
[ -s "$MODULES_TARBALL" ] || { echo "missing kernel modules bundle: $MODULES_TARBALL" >&2; exit 1; }
[ -s "$FIRMWARE_OUT/rtw88/rtw8821c_fw.bin" ] || { echo "missing RTL8821CS Wi-Fi firmware" >&2; exit 1; }
[ -s "$FIRMWARE_OUT/rtl_bt/rtl8821cs_fw.bin" ] || { echo "missing RTL8821CS Bluetooth firmware" >&2; exit 1; }
[ -s "$FIRMWARE_OUT/rtl_bt/rtl8821cs_config.bin" ] || { echo "missing required RTL8821CS Bluetooth config" >&2; exit 1; }

baseos_require_aarch64
mkdir -p "$WORK"

echo "== building RG353PS BaseOS rootfs for kernel $KREL =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
  -v "$WORK":/work \
  -v "$HERE/rootfs":/rootfs-src:ro \
  -v "$HERE/src":/src:ro \
  -v "$REPO_ROOT/src":/baseos-src:ro \
  -v "$REPO_ROOT/assets":/assets:ro \
  -e KREL="$KREL" \
  -e BASEOS_VERSION="$BASEOS_VERSION" \
  -e BASEOS_BUILD="$BASEOS_BUILD" \
  -e BASEOS_USB_PROFILE="$BASEOS_USB_PROFILE" \
  -e UMTP_COMMIT="$UMTP_COMMIT" \
  -e ALPINE_MIRROR="${ALPINE_MIRROR:-}" \
  alpine:3.22 sh -euc '
    if [ -n "${ALPINE_MIRROR:-}" ]; then
      printf "%s\n%s\n" "$ALPINE_MIRROR/main" "$ALPINE_MIRROR/community" > /etc/apk/repositories
      echo "apk repositories now:"; cat /etc/apk/repositories
    fi
    apk add --no-cache busybox-static tar zstd build-base linux-headers sdl2-dev freetype-dev freetype-static zlib-static libpng-static bzip2-static brotli-static pkgconf git ca-certificates

    R=/work/rootfs
    rm -rf "$R"
    mkdir -p "$R"
    # BaseOS uses merged-/usr so BusyBox applet links and future packages agree
    # on executable paths. Keep this system independent of Miyoo vendor files.
    mkdir -p "$R/usr/bin" "$R/usr/sbin" "$R/usr/lib" "$R/usr/share"
    ln -s usr/bin "$R/bin"
    ln -s usr/sbin "$R/sbin"
    ln -s usr/lib "$R/lib"
    ln -s lib "$R/lib64"
    mkdir -p "$R/proc" "$R/sys" "$R/dev" "$R/run" "$R/tmp" "$R/var" \
      "$R/data" "$R/root" "$R/etc" "$R/mnt" "$R/mnt/boot" "$R/mnt/roms"

    cp /bin/busybox.static "$R/usr/bin/busybox"
    # This runs in the arm64 container (QEMU binfmt is registered by CI/local
    # setup), creating applet links inside the rootfs rather than on the host.
    chroot "$R" /usr/bin/busybox --install -s
    test -L "$R/sbin/init" || { echo "BusyBox init applet is unavailable" >&2; exit 1; }
    test -L "$R/sbin/modprobe" || { echo "BusyBox modprobe applet is unavailable" >&2; exit 1; }
    test -L "$R/sbin/getty" || { echo "BusyBox getty applet is unavailable" >&2; exit 1; }

    # Install the exact matching kernel modules produced by build-kernel.sh.
    mkdir -p "$R/lib/modules/$KREL"
    tar --zstd -xf "/work/kernel/output/modules-$KREL.tar.zst" -C "$R/lib/modules/$KREL"
    rm -f "$R/lib/modules/$KREL/build" "$R/lib/modules/$KREL/source"

    # Only the firmware required by the mainline RTL8821CS driver and signed
    # regulatory database is included; no broad firmware package is copied.
    mkdir -p "$R/lib/firmware"
    cp -a /work/firmware/. "$R/lib/firmware/"

    cp -a /rootfs-src/. "$R/"

    # Select the USB policy at image-build time. A card-side config may still
    # override these defaults without rebuilding or updating the system.
    case "$BASEOS_USB_PROFILE" in
      development)
        sed -i "s/^usb_profile=.*/usb_profile=development/; s/^ssh_debug=.*/ssh_debug=yes/; s/^usb_mtp=.*/usb_mtp=yes/" "$R/etc/baseos.conf"
        ;;
      release)
        sed -i "s/^usb_profile=.*/usb_profile=release/; s/^ssh_debug=.*/ssh_debug=no/; s/^usb_mtp=.*/usb_mtp=yes/" "$R/etc/baseos.conf"
        ;;
    esac
    echo "USB build profile: $BASEOS_USB_PROFILE"

    # Build the lightweight C MTP responder for the target arm64 Alpine rootfs.
    # Pin the upstream revision and include its GPL-3.0 license with the binary.
    UMTP_SRC=/tmp/uMTP-Responder
    git clone --quiet https://github.com/viveris/uMTP-Responder.git "$UMTP_SRC"
    git -C "$UMTP_SRC" checkout --quiet --detach "$UMTP_COMMIT"
    test "$(git -C "$UMTP_SRC" rev-parse HEAD)" = "$UMTP_COMMIT" || {
      echo "uMTP-Responder checkout does not match pinned commit" >&2
      exit 1
    }
    make -s -C "$UMTP_SRC" CC=gcc
    install -D -m 0755 "$UMTP_SRC/umtprd" "$R/usr/sbin/umtprd"
    install -D -m 0644 "$UMTP_SRC/LICENSE" "$R/usr/share/licenses/uMTP-Responder/LICENSE"
    printf "%s\n" "$UMTP_COMMIT" > "$R/usr/share/licenses/uMTP-Responder/source-commit"

    # Install v4l-utils and its shared-library dependencies into the target
    # rootfs. The build container is arm64, matching the RG353PS target.
    # Disable package scripts: this is a minimal diagnostic rootfs, not a full
    # Alpine installation, and target post-install hooks must not run at build.
    mkdir -p "$R/etc/apk/keys"
    cp -a /etc/apk/keys/. "$R/etc/apk/keys/"
    cp /etc/apk/repositories "$R/etc/apk/repositories"
    # dropbear + dnsmasq carry the USB debug channel: RNDIS gives the host a
    # network, dnsmasq hands it an address, dropbear answers on 22. It is off
    # unless baseos.conf says ssh_debug=yes, and it costs ~700 KB. busybox here
    # has no udhcpd applet, which is why the DHCP side is dnsmasq.
    OPENSSH_SERVER_PACKAGE="openssh-server>=10.0_p1-r11"
    apk --root "$R" --arch aarch64 --initdb --no-scripts --no-cache add \
      v4l-utils evtest alsa-utils iw libzip libgcc \
      wpa_supplicant dropbear dropbear-convert dnsmasq openssh-sftp-server "$OPENSSH_SERVER_PACKAGE" \
      mesa-egl mesa-gles mesa-gbm mesa-dri-gallium \
      libdrm-tests mesa-utils kmscube sdl2 sdl2_image sdl2_ttf \
      sgdisk partx blkid wipefs exfatprogs
    # Alpine Dropbear enables SFTP and points at this standalone OpenSSH subsystem.
    # Install only sftp-server; do not add or start a second SSH daemon.
    test -x "$R/usr/lib/ssh/sftp-server" || {
      echo "SFTP subsystem is missing from target rootfs" >&2
      exit 1
    }
    gcc -std=c11 -O2 -Wall -Wextra -Werror -static \
      -o "$R/usr/sbin/rg353ps-control-center" /src/rg353ps-control-center.c
    gcc -std=c11 -O2 -Wall -Wextra -Werror -static \
      -o "$R/usr/sbin/rg353ps-frontend-selector" /src/rg353ps-frontend-selector.c
    gcc -std=c11 -O2 -Wall -Wextra -Werror -static \
      -o "$R/usr/sbin/rg353ps-hotkeyd" /src/rg353ps-hotkeyd.c
    # gptslot is the only thing that may move boot/rootfs between their two
    # halves; an update is not possible without it. It lives in the shared
    # src/ directory (mounted as /baseos-src), not this platform-owned one.
    gcc -static -O2 -o "$R/usr/sbin/gptslot" /baseos-src/gptslot.c
    strip "$R/usr/sbin/gptslot"
    # Boot-stage clock. It is the only thing on the image that can see the time
    # before Linux initialised a clock, which is where the bootloader and the
    # kernel decompression hide. Small and static like the rest of these.
    gcc -std=c11 -O2 -Wall -Wextra -Werror -static \
      -o "$R/usr/sbin/boot-clock" /baseos-src/boot-clock.c
    strip "$R/usr/sbin/boot-clock"
    # Build upstream BaseOS framebuffer splash statically so the boot and
    # USB-storage UI needs no extra runtime libraries.
    mkdir -p "$R/usr/share/baseos"
    gcc -static -O2 $(pkg-config --cflags freetype2) \
      -o "$R/usr/bin/fbsplash" /baseos-src/fbsplash.c $(pkg-config --static --libs freetype2)
    strip "$R/usr/bin/fbsplash"
    cp /assets/boot.ttf "$R/usr/share/baseos/boot.ttf"
    test -x "$R/usr/bin/fbsplash" || { echo "BaseOS fbsplash was not built" >&2; exit 1; }
    test -s "$R/usr/share/baseos/boot.ttf" || { echo "BaseOS boot font is missing" >&2; exit 1; }
    # Build a target-native SDL2 KMSDRM/GLES test against the runtime library
    # already installed in the target rootfs. sdl2-dev is build-container only.
    gcc -std=c11 -O2 -Wall -Wextra -Werror \
      $(sdl2-config --cflags) -o "$R/usr/sbin/rg353ps-sdl2-test" \
      /src/rg353ps-sdl2-test.c $(sdl2-config --libs)
    test -x "$R/usr/sbin/rg353ps-hotkeyd" || {
      echo "global hotkey service was not built" >&2
      exit 1
    }
    test -x "$R/usr/sbin/rg353ps-sdl2-test" || {
      echo "SDL2 KMSDRM test program was not built" >&2
      exit 1
    }
    test -x "$R/usr/sbin/rg353ps-control-center" || {
      echo "interactive control UI was not built" >&2
      exit 1
    }
    test -x "$R/usr/sbin/rg353ps-frontend-selector" || {
      echo "frontend selector UI was not built" >&2
      exit 1
    }
    test -f "$R/usr/sbin/baseos-frontend-manager" || {
      echo "frontend package manager is missing" >&2
      exit 1
    }
    test -f "$R/usr/sbin/baseos-frontend-compat" || {
      echo "legacy frontend compatibility helper is missing" >&2
      exit 1
    }
    sh -n "$R/usr/sbin/baseos-frontend-manager"
    sh -n "$R/usr/sbin/baseos-frontend-compat"
    test -x "$R/usr/bin/v4l2-ctl" || {
      echo "v4l2-ctl was not installed into target rootfs" >&2
      exit 1
    }
    test -x "$R/usr/bin/evtest" || {
      echo "evtest was not installed into target rootfs" >&2
      exit 1
    }
    test -f "$R/usr/sbin/baseos-init-userdata" || { echo "user data initializer is missing" >&2; exit 1; }
    # Boot timing. rcS and the frontend supervisor both call these on the boot
    # path; a missing mark tool is silent by design, so the build is the only
    # place that can notice it disappeared.
    for boot_tool in usr/sbin/baseos-boot-mark usr/sbin/baseos-boot-report usr/sbin/boot-clock usr/sbin/baseos-prefetch-gl; do
      test -x "$R/$boot_tool" || { echo "boot timing tool is missing: $boot_tool" >&2; exit 1; }
    done
    test -x "$R/usr/bin/sgdisk" || test -x "$R/usr/sbin/sgdisk" || { echo "sgdisk is missing" >&2; exit 1; }
    test -x "$R/usr/bin/partx" || test -x "$R/usr/sbin/partx" || { echo "partx is missing" >&2; exit 1; }
    test -x "$R/usr/bin/blkid" || test -x "$R/usr/sbin/blkid" || { echo "blkid is missing" >&2; exit 1; }
    test -x "$R/usr/bin/wipefs" || test -x "$R/usr/sbin/wipefs" || { echo "wipefs is missing" >&2; exit 1; }
    test -x "$R/usr/bin/mkfs.exfat" || test -x "$R/usr/sbin/mkfs.exfat" || test -x "$R/sbin/mkfs.exfat" || { echo "mkfs.exfat is missing" >&2; exit 1; }
    test -e "$R/usr/lib/libzip.so.5" || { echo "libzip runtime is missing for mGBA" >&2; exit 1; }
    # SDL2 frontends and menu components may use image loading and TrueType
    # rendering. Keep both runtime libraries in the target image and fail the
    # build if APK stops providing the required SONAMEs.
    for runtime_lib in libSDL2_image-2.0.so.0 libSDL2_ttf-2.0.so.0; do
      test -e "$R/usr/lib/$runtime_lib" || {
        echo "required SDL2 runtime library is missing: $runtime_lib" >&2
        exit 1
      }
    done
    test -x "$R/usr/bin/aplay" || {
      echo "aplay was not installed into target rootfs" >&2
      exit 1
    }
    test -x "$R/usr/sbin/iw" || test -x "$R/usr/bin/iw" || {
      echo "iw was not installed into target rootfs" >&2
      exit 1
    }
    # WiFi control plane. wpa_supplicant is what makes "reconnect after wake"
    # possible at all; the two scripts below are the only supported entry
    # points (hotkeyd calls rg353ps-sleep, the frontend calls wifi-connect).
    for wifi_tool in usr/sbin/wpa_supplicant usr/sbin/wpa_cli; do
      test -x "$R/$wifi_tool" || {
        echo "WiFi tool is missing from target rootfs: $wifi_tool" >&2
        exit 1
      }
    done
    test -x "$R/usr/sbin/sshd" || {
      echo "OpenSSH sshd package is missing" >&2
      exit 1
    }
    test -x "$R/usr/lib/ssh/sshd-session" || {
      echo "OpenSSH sshd-session helper is missing" >&2
      exit 1
    }
    test -x "$R/usr/lib/ssh/sshd-auth" || {
      echo "OpenSSH sshd-auth helper is missing" >&2
      exit 1
    }
    test -x "$R/usr/bin/dropbearconvert" || test -x "$R/usr/sbin/dropbearconvert" || {
      echo "dropbearconvert package is missing" >&2
      exit 1
    }
    test -f "$R/usr/sbin/baseos-wifi-sftp" || {
      echo "Wi-Fi SFTP service script is missing" >&2
      exit 1
    }
    sh -n "$R/usr/sbin/baseos-wifi-sftp"
    for wifi_script in rg353ps-sleep rg353ps-wifi-connect rg353ps-wifi-cycle; do
      test -x "$R/usr/sbin/$wifi_script" || {
        echo "WiFi/sleep helper is missing or not executable: $wifi_script" >&2
        exit 1
      }
    done
    # udhcpc needs a lease handler; the Alpine one that ships in the rootfs
    # drives `ip` and writes /run/resolv.conf (the image links /etc/resolv.conf
    # there), so fail early rather than end up with an address but no DNS.
    test -x "$R/usr/share/udhcpc/default.script" || {
      echo "udhcpc default.script is missing" >&2
      exit 1
    }
    # Update machinery. gptslot is the only writer of the slot flip, and
    # baseos-release is what a payload is validated against.
    for upd_tool in usr/sbin/gptslot usr/sbin/baseos-update usr/sbin/baseos-frontend-paths usr/share/baseos/log.sh; do
      test -e "$R/$upd_tool" || {
        echo "update component is missing from target rootfs: $upd_tool" >&2
        exit 1
      }
    done

    chmod 0755 "$R/etc/init.d/rcS"
    chmod 0755 "$R/usr/bin/baseos-splash"
    chmod 0755 "$R/usr/sbin/baseos-mount-storage"
    chmod 0755 "$R/usr/sbin/baseos-init-userdata"
    chmod 0755 "$R/usr/sbin/baseos-usb-storage"
    chmod 0755 "$R/usr/sbin/baseos-frontend-session"
    chmod 0755 "$R/usr/sbin/baseos-frontend-paths"
    chmod 0755 "$R/usr/sbin/baseos-frontend-manager"
    chmod 0755 "$R/usr/sbin/baseos-frontend-compat"
    chmod 0755 "$R/usr/sbin/rg353ps-frontend-selector"
    chmod 0755 "$R/usr/sbin/baseos-boot-mark"
    chmod 0755 "$R/usr/sbin/baseos-boot-report"
    chmod 0755 "$R/usr/sbin/baseos-prefetch-gl"
    chmod 0755 "$R/usr/sbin/rg353ps-hotkeyd"
    chmod 0755 "$R/usr/sbin/baseos-update"
    chmod 0755 "$R/usr/sbin/gptslot"
    chmod 0755 "$R/usr/sbin/baseos-audio-init"
    chmod 0755 "$R/usr/sbin/baseos-audio-check"
    chmod 0755 "$R/usr/sbin/baseos-usb-debug"
    chmod 0755 "$R/usr/sbin/baseos-wifi-sftp"
    chmod 0755 "$R/usr/sbin/baseos-usb-mtp"
    chmod 0644 "$R/usr/sbin/baseos-usb-mode-lib"
    chmod 0755 "$R/usr/sbin/rg353ps-sleep"
    chmod 0755 "$R/usr/sbin/rg353ps-wifi-connect"
    chmod 0755 "$R/usr/sbin/rg353ps-wifi-cycle"
    chmod 0755 "$R/usr/sbin/rg353ps-v4l2-report"
    chmod 0755 "$R/usr/sbin/rg353ps-jpeg-encode-test"
    chmod 0755 "$R/usr/sbin/rg353ps-hardware-audit"
    chmod 0755 "$R/usr/sbin/rg353ps-suspend-audit"
    chmod 0755 "$R/usr/sbin/rg353ps-suspend-test"
    chmod 0755 "$R/usr/sbin/rg353ps-graphics-stack-test"
    chmod 0755 "$R/usr/sbin/rg353ps-sdl2-test"
    chmod 0755 "$R/usr/sbin/rg353ps-control-center"
    chmod 1777 "$R/tmp"
    # The debug channel ships a fixed dropbear host key. Without one dropbear
    # mints a fresh key on first boot, so every reflash changes the fingerprint
    # and the host stops connecting with "REMOTE HOST IDENTIFICATION HAS
    # CHANGED". Git cannot carry mode 0600, so set it here; dropbear refuses a
    # group/world-readable host key.
    chmod 0600 "$R/etc/dropbear/dropbear_ed25519_host_key"
    mkdir -p "$R/mnt/SDCARD" "$R/run" "$R/root" "$R/var/empty" "$R/etc/wpa_supplicant"
    ln -sfn /mnt/SDCARD "$R/mnt/sdcard"
    # Alpine OpenSSH is built with privilege separation enabled. Package
    # install hooks are disabled for this image, so create its locked service
    # account explicitly; sshd drops its pre-authentication child to this UID.
    printf "root:x:0:0:root:/root:/bin/sh\nsshd:x:22:22:SSH privilege separation:/var/empty:/sbin/nologin\n" > "$R/etc/passwd"
    printf "root:x:0:\nsshd:x:22:\n" > "$R/etc/group"
    chmod 0755 "$R/var/empty"
    # Root carries the existing password for USB debugging and the SFTP-only
    # Wi-Fi account. Wi-Fi sshd forces internal-sftp and chroots to /mnt/SDCARD;
    # it does not offer an interactive root shell. The hash is baked in rather
    # than computed here because the build container (alpine:3.22) has neither
    # mkpasswd nor openssl, and a random salt would make every build differ.
    # USB Dropbear stays bound to 192.168.42.1 and controlled by ssh_debug.
    # Wi-Fi OpenSSH is separately bound to wlan0 and restricted to SFTP in
    # /mnt/SDCARD. To change the shared root password, regenerate with the
    # same fixed salt:
    BASEOS_ROOT_HASH="\$6\$baseosrg\$ZjVux5iPKMrAFlY4uyVHbIxb.NTUSifHTjYkVcmdQc9sCCS0ZsTZaZZzL51lBu6k6D2.J7X9B5IitsGVmat9j/"
    printf "root:%s:19000:0:99999:7:::\nsshd:!:19000:0:99999:7:::\n" "$BASEOS_ROOT_HASH" > "$R/etc/shadow"
    # Validate the exact SFTP-only configuration with the same OpenSSH binary
    # and host key conversion that will run on the handheld.
    chroot "$R" /usr/bin/dropbearconvert dropbear openssh \
      /etc/dropbear/dropbear_ed25519_host_key /run/baseos-wifi-sftp-test-key
    chmod 0600 "$R/run/baseos-wifi-sftp-test-key"
    cat > "$R/run/baseos-wifi-sftp-build-test.conf" <<EOF
Port 2222
AddressFamily inet
ListenAddress 127.0.0.1
HostKey /run/baseos-wifi-sftp-test-key
PidFile /run/baseos-wifi-sftp-test.pid
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthorizedKeysFile /root/.ssh/authorized_keys
AllowUsers root
StrictModes yes
ChrootDirectory /mnt/SDCARD
ForceCommand internal-sftp -d / -u 022
Subsystem sftp internal-sftp
DisableForwarding yes
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
PermitTTY no
PermitUserRC no
PermitUserEnvironment no
LoginGraceTime 20
MaxAuthTries 3
MaxSessions 2
MaxStartups 3:30:10
LogLevel VERBOSE
EOF
    chroot "$R" /usr/sbin/sshd -t -f /run/baseos-wifi-sftp-build-test.conf
    rm -f "$R/run/baseos-wifi-sftp-test-key" "$R/run/baseos-wifi-sftp-build-test.conf"
    ln -sfn /proc/mounts "$R/etc/mtab"
    ln -sfn /run/resolv.conf "$R/etc/resolv.conf"
    # baseos-audio-init writes the softvol definition at boot, and the root
    # filesystem is mounted read-only. /run is tmpfs, so the write lands there
    # through this link; ALSA reads /etc/asound.conf exactly as before. A
    # dangling link is harmless: alsa-lib treats ENOENT as "no config", which is
    # the state the image shipped in anyway.
    ln -sfn /run/asound.conf "$R/etc/asound.conf"
    # The root filesystem is mounted read-only and stays that way, so anything a
    # boot writes has to be RAM or a link into it. The three links above are
    # what makes that true for mount state, DNS and the ALSA softvol
    # definition; if one of them silently disappears the write fails with EROFS
    # and the failure is easy to miss - no sound, or no DNS, with a clean boot
    # log. Checked here, after they are made.
    for writable in etc/mtab etc/resolv.conf etc/asound.conf; do
      test -L "$R/$writable" || {
        echo "$writable must be a symlink into RAM for the read-only root" >&2
        exit 1
      }
    done
    printf "BaseOS RG353PS rootfs\n" > "$R/etc/motd"
    printf "%s\n" "$KREL" > "$R/etc/baseos-kernel-release"

    cat > "$R/etc/baseos-release" <<EOF
BASEOS_TARGET=rg353ps
BASEOS_VERSION=$BASEOS_VERSION
BASEOS_BUILD=$BASEOS_BUILD
# fbsplash reads this; the RG353PS panel is mounted upright.
BASEOS_PANEL_ROTATION_CCW=0
EOF
    grep -q "^BASEOS_VERSION=" "$R/etc/baseos-release" || {
      echo "baseos-release carries no BASEOS_VERSION; .bosupd payloads could not be validated" >&2
      exit 1
    }

    cat > "$R/etc/baseos-build.json" <<EOF
{
  "target": "Anbernic RG353PS",
  "kernel_release": "$KREL",
  "userspace": "static BusyBox",
  "purpose": "RG353PS BaseOS system image",
  "frontend_model": "external; generic adapters discovered from TF2 then TF1",
  "diagnostic_ui": true,
  "hardware_tested": false
}
EOF
    echo "rootfs prepared at $R"
  '

for file in "$ROOTFS/usr/bin/busybox" "$ROOTFS/usr/bin/baseos-splash" "$ROOTFS/usr/bin/fbsplash" "$ROOTFS/sbin/init" "$ROOTFS/etc/init.d/rcS" "$ROOTFS/usr/sbin/baseos-mount-storage" "$ROOTFS/usr/sbin/baseos-init-userdata" "$ROOTFS/usr/sbin/baseos-usb-storage" "$ROOTFS/usr/sbin/baseos-usb-mtp" "$ROOTFS/usr/sbin/baseos-usb-mode-lib" "$ROOTFS/usr/sbin/umtprd" "$ROOTFS/etc/umtprd/umtprd.conf" "$ROOTFS/usr/sbin/baseos-frontend-session" "$ROOTFS/usr/sbin/baseos-frontend-discovery" "$ROOTFS/usr/sbin/rg353ps-hotkeyd" "$ROOTFS/usr/sbin/rg353ps-hardware-audit" "$ROOTFS/usr/sbin/rg353ps-suspend-audit" "$ROOTFS/usr/sbin/rg353ps-suspend-test" "$ROOTFS/usr/sbin/rg353ps-graphics-stack-test" "$ROOTFS/usr/sbin/rg353ps-sdl2-test" "$ROOTFS/usr/sbin/rg353ps-control-center" "$ROOTFS/etc/baseos.conf" "$ROOTFS/etc/baseos-release" \
  "$ROOTFS/etc/baseos/bootlogo.bmp" \
  "$ROOTFS/etc/dropbear/dropbear_ed25519_host_key" \
  "$ROOTFS/usr/sbin/baseos-update" "$ROOTFS/usr/sbin/gptslot" \
  "$ROOTFS/usr/sbin/rg353ps-sleep" "$ROOTFS/usr/sbin/rg353ps-wifi-connect" \
  "$ROOTFS/usr/sbin/wpa_supplicant" "$ROOTFS/lib/modules/$KREL/modules.dep"; do
  # A symlink is accepted even when it cannot be followed here: the rootfs uses
  # absolute links (/bin/sh -> /usr/bin/busybox) that only resolve inside the
  # image, so -e alone reports every one of them as missing on the host.
  { [ -e "$file" ] || [ -L "$file" ]; } || {
    echo "rootfs missing required file: $file" >&2
    exit 1
  }
done

# Generate the default boot artwork offline with the H700 BaseOS fbsplash method.
"$REPO_ROOT/tools/make-bootlogo.sh"
install -m 0644 "$WORK/bootlogo.bmp" "$ROOTFS/etc/baseos/bootlogo.bmp"
python3 - "$ROOTFS/etc/baseos/bootlogo.bmp" <<'PY'
import struct, sys
from pathlib import Path
p = Path(sys.argv[1])
data = p.read_bytes()
assert data[:2] == b"BM", "bootlogo is not a BMP"
width, height = struct.unpack_from("<ii", data, 18)
planes, bpp = struct.unpack_from("<HH", data, 26)
compression = struct.unpack_from("<I", data, 30)[0]
assert (width, abs(height), planes, bpp, compression) == (640, 480, 1, 24, 0), (
    "unexpected bootlogo format: {}x{}, {} planes, {}bpp, compression={}".format(
        width, height, planes, bpp, compression
    )
)
assert len(data) >= 921654, "bootlogo is truncated: {} bytes".format(len(data))
print("Offline fbsplash bootlogo verified: 640x480 24bpp ({} bytes)".format(len(data)))
PY


echo "RG353PS rootfs ready: $ROOTFS"
echo "Kernel release: $KREL"
echo "This rootfs includes system services and a diagnostic UI; game frontends are installed separately."
