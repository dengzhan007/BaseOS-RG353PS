#!/bin/sh
# RG353PS USB reconnect diagnostic capture.
#
# Read-only: enables a small set of dynamic-debug rules, watches the kernel log
# stream and samples USB state, then turns exactly those rules back off.
# It never writes USB/Runtime-PM/DHCP/supervisor state and never runs recovery.
#
# Verified on RG353PS BaseOS 1.2.4 / BusyBox 1.37.0:
#   - dmesg has no -w; /proc/kmsg is readable and is used as the live stream
#   - sleep 0.5 and awk fflush() both work
#   - debugfs is not mounted by default, so this script mounts it if needed
#
# Usage:  sh usb-reconnect-diag.sh
#         DIAG_SECONDS=5 DIAG_INTERVAL=0.5 sh usb-reconnect-diag.sh   (dry run)
# Output: /mnt/SDCARD/usb-reconnect-diag-YYYYMMDD-HHMMSS.log

DIAG_VERSION="1.1"
DIAG_SECONDS="${DIAG_SECONDS:-60}"
DIAG_INTERVAL="${DIAG_INTERVAL:-0.5}"
# Hard cap on the number of lines actually written to the log file.
DIAG_MAX_LOG_LINES="${DIAG_MAX_LOG_LINES:-20000}"

OUTDIR=/mnt/SDCARD
DBG=/sys/kernel/debug
CONTROL="$DBG/dynamic_debug/control"
LOG=
DEBUGFS_OWNED=0
RULES_ON=0
RULE_OK=0
RULE_FAILURES=
KMSG_PID=
SAMPLE_PID=
KMSG_METHOD=N/A
STOP=0

# Keep failures local: a missing sysfs node must not abort the capture.
set -u

# Safe before LOG exists (early preflight failures also run cleanup).
log_line() {
    [ -n "$LOG" ] && [ -f "$LOG" ] || return 0
    printf '%s\n' "$*" >>"$LOG" 2>/dev/null || :
}

readval() {
    if [ -r "$1" ]; then
        v=$(cat "$1" 2>/dev/null)
        if [ -n "$v" ]; then
            printf '%s' "$v" | tr '\n' ' '
            return
        fi
    fi
    printf 'N/A'
}

udc_snapshot() {
    out=
    for u in /sys/class/udc/*; do
        [ -d "$u" ] || continue
        n=${u##*/}
        out="$out${out:+,}$n{state=$(readval "$u/state"),cur=$(readval "$u/current_speed"),max=$(readval "$u/maximum_speed")}"
    done
    printf '%s' "${out:-N/A}"
}

extcon_snapshot() {
    out=
    for e in /sys/class/extcon/*; do
        [ -r "$e/name" ] || continue
        n=$(cat "$e/name" 2>/dev/null)
        s=$(cat "$e/state" 2>/dev/null | tr '\n' ' ')
        [ -n "$s" ] || s=N/A
        out="$out${out:+,}[${n:-N/A}]=$s"
    done
    printf '%s' "${out:-N/A}"
}

# Sum every CPU column of /proc/interrupts, not just CPU0. Keep the IRQ
# number and the interrupt name so the reader can tell which line moved.
# This is a read of /proc/interrupts only: no affinity or IRQ config changes.
irq_snapshot() {
    if [ ! -r /proc/interrupts ]; then
        printf 'N/A'
        return
    fi
    v=$(awk '
        NR == 1 {
            for (i = 1; i <= NF; i++)
                if ($i ~ /^CPU[0-9]+$/) ncpu++
            if (ncpu > 0) ncpu_known = 1
            next
        }
        # Fall back to the leading numeric columns if the header is unusual.
        !ncpu_known {
            for (i = 2; i <= NF; i++)
                if ($i ~ /^[0-9]+$/) ncpu++
                else break
            ncpu_known = 1
        }
        {
            low = tolower($0)
            if (low !~ /rockchip_usb2phy|dwc3|bvalid|otg/) next
            irq = $1
            gsub(/:/, "", irq)
            if (irq !~ /^[0-9]+$/) next
            sum = 0
            # Sum exactly the ncpu counter columns, not just CPU0.
            for (i = 2; i <= 1 + ncpu; i++)
                if (i <= NF && $i ~ /^[0-9]+$/) sum += $i
            # Everything after the CPU counters is the interrupt controller /
            # device description. Keep all of it, not just the last field.
            desc = ""
            for (i = 2 + ncpu; i <= NF; i++)
                desc = desc (desc == "" ? "" : " ") $i
            printf "%s%s(total=%s,desc=%s)", sep, irq, sum, desc
            sep = ","
        }
        END {
            if (sep == "") print "N/A"
            else print " cpus=" ncpu
        }
    ' /proc/interrupts 2>/dev/null | tr -d '\n')
    printf '%s' "${v:-N/A}"
}

release_snapshot() {
    if [ -r /etc/baseos-release ]; then
        grep -E 'BASEOS_(TARGET|VERSION|BUILD)=' /etc/baseos-release 2>/dev/null | tr '\n' ' '
    else
        printf 'N/A'
    fi
}

# The five selectors below are intentionally explicit. enable_rules() and
# disable_rules() are mirror images; do not add one without the other.
# Format strings were read back from the running kernel's
# /sys/kernel/debug/dynamic_debug/control, not guessed from docs.
# A write to control can succeed while matching no callsite at all (for
# example a format string that no longer exists in this kernel), so check both
# the write result and the flags read back from control.
rule_is_enabled() {
    case "$1" in
        'file '*)   key=${1#file } ;;
        'format '*) key=${1#format } ;;
        *) return 1 ;;
    esac
    key=${key% +p}
    key=$(printf '%s' "$key" | tr -d '"')
    grep -F "$key" "$CONTROL" 2>/dev/null | grep -q '=p '
}

# RULES_ON is set by the caller BEFORE the first selector is written, so an
# early exit or signal still makes cleanup() turn off all five selectors even
# when only some of them were enabled successfully.
enable_one_rule() {
    one_rule=$1
    if printf '%s\n' "$one_rule" >"$CONTROL" 2>/dev/null && rule_is_enabled "$one_rule"; then
        RULE_OK=$((RULE_OK + 1))
    else
        RULE_FAILURES="${RULE_FAILURES}${RULE_FAILURES:+|}$one_rule"
    fi
}

enable_rules() {
    RULE_OK=0
    RULE_FAILURES=
    enable_one_rule 'file phy-rockchip-inno-usb2.c +p'
    enable_one_rule 'format "RG353PS DWC3 device DISCONNECT event" +p'
    enable_one_rule 'format "RG353PS DWC3 device RESET event" +p'
    enable_one_rule 'format "RG353PS DWC3 device-event raw" +p'
    enable_one_rule 'format "RG353PS EP0 SETUP" +p'
}

disable_rules() {
    printf '%s\n' 'file phy-rockchip-inno-usb2.c -p' >"$CONTROL"
    printf '%s\n' 'format "RG353PS DWC3 device DISCONNECT event" -p' >"$CONTROL"
    printf '%s\n' 'format "RG353PS DWC3 device RESET event" -p' >"$CONTROL"
    printf '%s\n' 'format "RG353PS DWC3 device-event raw" -p' >"$CONTROL"
    printf '%s\n' 'format "RG353PS EP0 SETUP" -p' >"$CONTROL"
}

list_rules() {
    log_line '  file phy-rockchip-inno-usb2.c                         +p'
    log_line '  format "RG353PS DWC3 device DISCONNECT event"         +p'
    log_line '  format "RG353PS DWC3 device RESET event"              +p'
    log_line '  format "RG353PS DWC3 device-event raw"                +p'
    log_line '  format "RG353PS EP0 SETUP"                           +p'
}

# Live kernel stream. /proc/kmsg is a single-reader stream; no klogd or
# syslogd runs on this image. Keep the RG353PS traces, generic USB-subsystem
# messages and kernel warnings/errors, but drop the per-packet EP2 / bulk-out
# data-plane lines (one of them is dev_info_ratelimited and always on).
start_kmsg() {
    if [ -r /proc/kmsg ]; then
        KMSG_METHOD=/proc/kmsg
        # awk reads the stream directly: one process, so kill $! is clean and
        # no orphaned cat is left behind. /proc/kmsg blocks waiting for new
        # messages, and fflush() makes every matched line land in the log now.
        awk -v max="$DIAG_MAX_LOG_LINES" '
            {
                line = $0
                if (line ~ /EP2|bulk-out event|RESET EP2 snapshot/) next
                low = tolower(line)
                keep = 0
                if (index(line, "RG353PS") > 0) keep = 1
                else if (low ~ /dwc3|usb2phy|extcon/) keep = 1
                else if (line ~ /^<[1-4]>/) keep = 1
                else if (low ~ /warn|error|fail|oops|panic|call trace|bug:/) keep = 1
                # Generic USB subsystem events. Deliberately tokenised: a bare
                # "usb" would match ordinary prose, so require a bus number,
                # a known subsystem token, or a Rockchip USB tag. Examples:
                # "usb 1-1:", "usbcore:", "gadget:", "udc-core:", "xhci_hcd",
                # "typec", "role-switch", "rockchip_usb2phy".
                else if (low ~ /(^|[^a-z0-9_])(usbcore|usb[0-9]+|usb[ _-][0-9]|usb[-_](phy|gadget|role|core|host|device)|gadget|udc|xhci[a-z0-9_-]*|typec|ucsi|role-switch|rockchip[-_]?usb)/) keep = 1
                if (!keep) next
                if (n >= max) next
                n++
                print "[kmsg] " line
                fflush()
            }' /proc/kmsg >>"$LOG" 2>/dev/null &
        KMSG_PID=$!
    else
        log_line "kernel-stream=N/A (/proc/kmsg unreadable); dmesg tail will be appended at exit"
    fi
}

start_sampling() {
    ( n=0
      while :; do
        if [ "$n" -ge "$DIAG_MAX_LOG_LINES" ]; then break; fi
        printf '[sample] %s udc=%s extcon=%s irq=%s\n' \
            "$(date '+%F %T')" "$(udc_snapshot)" "$(extcon_snapshot)" "$(irq_snapshot)" \
            >>"$LOG" 2>/dev/null || :
        n=$((n + 1))
        sleep "$DIAG_INTERVAL"
      done ) &
    SAMPLE_PID=$!
}

write_header() {
    [ -n "$LOG" ] || return 0
    {
        echo "=== RG353PS USB reconnect diagnostic ==="
        echo "script_version=$DIAG_VERSION"
        echo "started=$(date '+%F %T %z')"
        echo "release=$(release_snapshot)"
        echo "kernel=$(uname -a 2>/dev/null || echo N/A)"
        echo "duration=${DIAG_SECONDS}s interval=${DIAG_INTERVAL}s"
        echo "log_line_limit=$DIAG_MAX_LOG_LINES"
        echo "dmesg_follow_flag=$(dmesg --help 2>&1 | grep -q -- '-w' && echo yes || echo no)"
        echo "kernel_stream=$KMSG_METHOD"
        echo "debugfs_mounted_by_script=$DEBUGFS_OWNED"
        echo "paths: udc=$(ls -d /sys/class/udc/* 2>/dev/null | wc -l | tr -d ' ') extcon=$(ls -d /sys/class/extcon/* 2>/dev/null | wc -l | tr -d ' ') proc_interrupts=$([ -r /proc/interrupts ] && echo yes || echo N/A) proc_kmsg=$([ -r /proc/kmsg ] && echo yes || echo N/A) baseos_release=$([ -r /etc/baseos-release ] && echo yes || echo N/A)"
        echo "udc_initial=$(udc_snapshot)"
        echo "extcon_initial=$(extcon_snapshot)"
        echo "irq_initial=$(irq_snapshot)"
        echo "--- dynamic debug selectors enabled by this script ---"
    } >>"$LOG"
    list_rules
    # Name every selector that failed to take effect, so a partial capture is
    # never mistaken for a complete one. enabled_rule_ok= counts successes.
    if [ -n "$RULE_FAILURES" ]; then
        printf '%s\n' "$RULE_FAILURES" | tr '|' '\n' | sed 's/^/rule_enable_failed=/' >>"$LOG"
    fi
    echo "enabled_rule_ok=$RULE_OK/5" >>"$LOG"
    if [ -r "$CONTROL" ]; then
        n=$(grep 'RG353PS' "$CONTROL" 2>/dev/null | grep -c '=p ')
        echo "enabled_rule_count=$n" >>"$LOG"
        echo "--- enabled rules as seen in control ---" >>"$LOG"
        grep 'RG353PS' "$CONTROL" 2>/dev/null | grep '=p ' >>"$LOG"
    else
        echo "enabled_rule_count=N/A" >>"$LOG"
    fi
    echo "--- capture start ---" >>"$LOG"
}

write_footer() {
    [ -n "$LOG" ] && [ -f "$LOG" ] || return 0
    {
        echo "--- capture end $(date '+%F %T %z') ---"
        echo "udc_final=$(udc_snapshot)"
        echo "extcon_final=$(extcon_snapshot)"
        echo "irq_final=$(irq_snapshot)"
    } >>"$LOG"
}

# Final guard: the cap applies to the TOTAL number of lines in the file, not
# just the kernel-stream section. Both producers already stop at the cap;
# this truncation covers header/footer/sample lines too. It runs only after
# both producers are stopped: truncating while two processes append to the
# same file would replace the inode under an open fd and lose their writes.
# This is a final-file limit, not a real-time disk-usage limit.
enforce_limit() {
    [ -n "$LOG" ] && [ -f "$LOG" ] || return 0
    total=$(wc -l <"$LOG" 2>/dev/null || echo 0)
    [ "$total" -gt "$DIAG_MAX_LOG_LINES" ] || return 0
    keep=$((DIAG_MAX_LOG_LINES - 1))
    head -n "$keep" "$LOG" >"$LOG.trim" 2>/dev/null || return 0
    mv "$LOG.trim" "$LOG" 2>/dev/null || :
    printf '[diag] log truncated to %s lines (limit)\n' "$DIAG_MAX_LOG_LINES" >>"$LOG"
}

cleanup() {
    trap - 0 1 2 15
    if [ -n "$KMSG_PID" ]; then kill "$KMSG_PID" 2>/dev/null || :; fi
    if [ -n "$SAMPLE_PID" ]; then kill "$SAMPLE_PID" 2>/dev/null || :; fi
    if [ -n "$KMSG_PID" ]; then wait "$KMSG_PID" 2>/dev/null || :; fi
    if [ -n "$SAMPLE_PID" ]; then wait "$SAMPLE_PID" 2>/dev/null || :; fi

    # Only ever turn off rules this script actually enabled.
    if [ "$RULES_ON" = 1 ] && [ -w "$CONTROL" ]; then
        disable_rules
        RULES_ON=0
        log_line "dynamic debug rules disabled"
    fi

    # If /proc/kmsg was unavailable, keep a final read-only dmesg snapshot.
    if [ "$KMSG_METHOD" = N/A ] && [ -n "$LOG" ]; then
        echo "--- dmesg tail at exit (filtered) ---" >>"$LOG"
        dmesg 2>/dev/null | grep -Ei 'RG353PS|dwc3|usb2phy|extcon|warn|error|fail' \
            | grep -vE 'EP2|bulk-out event|RESET EP2 snapshot' | tail -n 300 >>"$LOG"
    fi

    write_footer
    enforce_limit
    # Only unmount debugfs if this script mounted it. A pre-existing mount is
    # never touched, including on every early-exit path.
    if [ "$DEBUGFS_OWNED" = 1 ]; then
        umount "$DBG" 2>/dev/null || log_line "warning: could not umount debugfs (left mounted)"
    fi
    sync 2>/dev/null || :
    if [ -n "$LOG" ] && [ -f "$LOG" ]; then
        sz=$(wc -c <"$LOG" 2>/dev/null || echo N/A)
        echo "diagnostic log: $LOG"
        echo "log size: $sz bytes"
    fi
}

# Install the exit trap BEFORE any preflight step that can fail, so a debugfs
# mount done below is always undone on a later failure. cleanup() is safe when
# LOG is empty and when no rules were enabled.
STOP=0
trap 'STOP=1' 1 2 15
trap cleanup 0

# ---------------------------------------------------------------- preflight
if [ "$(id -u 2>/dev/null || echo 1)" != 0 ]; then
    echo "error: run as root" >&2
    exit 1
fi

if [ ! -d "$OUTDIR" ] || [ ! -w "$OUTDIR" ]; then
    echo "error: $OUTDIR is missing or not writable" >&2
    exit 1
fi

if [ ! -r "$CONTROL" ]; then
    mount -t debugfs none "$DBG" 2>/dev/null || {
        echo "error: could not mount debugfs" >&2
        exit 1
    }
    DEBUGFS_OWNED=1
fi
if [ ! -w "$CONTROL" ]; then
    echo "error: $CONTROL is not writable" >&2
    exit 1
fi

# Refuse to run if any rule we would later turn off is already enabled by
# somebody else. Other, unrelated dynamic-debug rules are left untouched.
CONFLICT=$(grep '=p ' "$CONTROL" 2>/dev/null | grep -E \
    'phy-rockchip-inno-usb2\.c|"RG353PS DWC3 device DISCONNECT|"RG353PS DWC3 device RESET|"RG353PS DWC3 device-event raw|"RG353PS EP0 SETUP' || :)
if [ -n "$CONFLICT" ]; then
    echo "error: overlapping dynamic-debug rules are already enabled." >&2
    echo "Refusing to run so cleanup cannot disable someone else's rules:" >&2
    printf '%s\n' "$CONFLICT" >&2
    exit 1
fi

STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$OUTDIR/usb-reconnect-diag-$STAMP.log"
suffix=0
while [ -e "$LOG" ]; do
    suffix=$((suffix + 1))
    LOG="$OUTDIR/usb-reconnect-diag-$STAMP-$suffix.log"
done
: >"$LOG" || {
    echo "error: cannot create $LOG" >&2
    exit 1
}

# ---------------------------------------------------------------- capture
# A long "sleep 60" would delay signal handling until it finished, leaving the
# debug rules on for a minute after Ctrl+C. One-second slices bound that delay
# to 1 s; the signal handler only sets a flag, and EXIT runs the real cleanup.
# RULES_ON goes high BEFORE the first selector is written: if only some rules
# enable, cleanup() must still attempt to disable all five of them.
RULES_ON=1
enable_rules
# Resolve the stream name before the header is written, so kernel_stream=
# describes the stream that will actually be started below.
if [ -r /proc/kmsg ]; then
    KMSG_METHOD=/proc/kmsg
else
    KMSG_METHOD=N/A
fi
# Write the complete header first. The two background producers only append,
# so their lines can never be interleaved ahead of the header.
write_header
start_kmsg
start_sampling
if [ -n "$RULE_FAILURES" ]; then
    echo "warning: some dynamic-debug rules did not enable; see rule_enable_failed= in the log" >&2
fi

echo ""
echo "=== USB reconnect diagnostic (v$DIAG_VERSION, ${DIAG_SECONDS}s) ==="
echo "log: $LOG"
echo ""
echo "CAPTURE STARTED. Now do exactly this:"
echo "  1. Unplug the OTG data cable."
echo "  2. Wait about 3 seconds."
echo "  3. Plug the cable back in."
echo "  4. Wait for the device to recover or for the capture to finish."
echo ""
echo "The script stops by itself, or press Ctrl+C to stop early."
echo ""

elapsed=0
while [ "$STOP" = 0 ] && [ "$elapsed" -lt "$DIAG_SECONDS" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
done
cleanup
