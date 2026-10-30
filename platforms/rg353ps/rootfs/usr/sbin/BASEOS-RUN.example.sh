#!/bin/sh
# RG353PS headless field test - stage the WiFi SDIO power-cycle helpers and run
# a real deep-suspend current measurement without a serial console.
#
# HOW THIS RUNS
#   /etc/init.d/rcS executes /mnt/boot/BASEOS-RUN.SH at boot when it exists:
#       /bin/sh "$BOOT_TASK" >> /mnt/boot/BASEOS-RUN-LOG.txt 2>&1
#   so everything printed here lands in BASEOS-RUN-LOG.txt on the boot
#   partition, and rcS blocks until this script returns.
#
# WHAT IT DOES
#   stage 0  copy the two helpers from the boot partition into /usr/sbin
#   stage 1  cycle-test: unbind + rebind the SDIO WiFi function with NO suspend.
#            Proves the driver recovers before anything risky happens.
#   stage 2  deep suspend with WiFi unbound, RTC-woken, then rebind and report.
#            rcS stays blocked for the whole sleep, so the frontend only starts
#            after the measurement is finished.
#
# SAFETY
#   * This file deletes itself first, so a stale copy can never suspend the unit
#     on every boot.
#   * Stage 2 only runs if stage 1 passed.
#   * If the RTC alarm does not fire, press the power button to wake the unit.

set -u

BOOT=/mnt/boot
SLEEP_SECS=3600          # <-- adjust if you want a longer sleep window
SETTLE_SECS=10

echo "=============================================================="
echo "RG353PS headless WiFi/suspend test"
echo "started: $(date 2>/dev/null || echo unknown)"
echo "boot partition: $BOOT"
echo "sleep window: ${SLEEP_SECS}s"
echo "=============================================================="

# --- stay idempotent -------------------------------------------------------
if rm -f "$BOOT/BASEOS-RUN.SH" 2>/dev/null; then
  echo "removed BASEOS-RUN.SH so this test cannot repeat on the next boot"
else
  echo "WARNING: could not remove BASEOS-RUN.SH; it may run again next boot"
fi

# --- stage 0: install helpers ---------------------------------------------
echo
echo "=== stage 0: install helpers into /usr/sbin ==="
for f in rg353ps-wifi-cycle rg353ps-suspend-deep; do
  if [ ! -f "$BOOT/$f" ]; then
    echo "ERROR: $BOOT/$f is missing; aborting"
    exit 1
  fi
  if cp -f "$BOOT/$f" "/usr/sbin/$f" && chmod 755 "/usr/sbin/$f"; then
    echo "  installed /usr/sbin/$f"
  else
    echo "ERROR: failed to install /usr/sbin/$f; aborting"
    exit 1
  fi
done

# The regulator must be switchable or every later step measures the same 41 mA
# and tells us nothing. Refuse to burn an hour on a known-dead configuration.
echo
echo "=== device tree: WiFi rail ==="
VCW=
for p in /proc/device-tree/regulator-vcc-wifi \
         /proc/device-tree/soc/regulator-vcc-wifi \
         /proc/device-tree/soc@0/regulator-vcc-wifi; do
  [ -d "$p" ] && { VCW="$p"; break; }
done
[ -n "$VCW" ] || VCW=$(find /proc/device-tree -name 'regulator-vcc-wifi' 2>/dev/null | head -1)

if [ -z "$VCW" ]; then
  # Not fatal: the lookup may simply not match this DTB layout. Dump what the
  # regulator class reports instead and let the report decide.
  echo "  regulator-vcc-wifi node NOT FOUND via the usual paths"
  echo "  regulator class says:"
  for r in /sys/class/regulator/regulator.*; do
    [ -d "$r" ] || continue
    echo "    $(cat "$r/name" 2>/dev/null): $(cat "$r/state" 2>/dev/null)"
  done
else
  echo "  node: ${VCW#/proc/device-tree/}"
  if [ -e "$VCW/regulator-always-on" ]; then
    echo "  regulator-always-on: PRESENT"
    echo
    echo "ABORTING: vcc_wifi is regulator-always-on, so mmc_power_off() cannot"
    echo "cut the rail and this test would just reproduce the 41 mA baseline."
    echo "Replace device_trees/rk3566-anbernic-rg353ps.dtb with the A variant"
    echo "(no regulator-always-on on vcc_wifi) and boot again."
    exit 1
  fi
  echo "  regulator-always-on: absent  <-- rail is switchable, continuing"
fi

SMMC=
for p in /proc/device-tree/mmc@fe000000 \
         /proc/device-tree/soc/mmc@fe000000 \
         /proc/device-tree/soc@0/mmc@fe000000; do
  [ -d "$p" ] && { SMMC="$p"; break; }
done
[ -n "$SMMC" ] || SMMC=$(find /proc/device-tree -name 'mmc@fe000000' 2>/dev/null | head -1)
if [ -n "$SMMC" ]; then
  echo "  sdio host status: $(tr -d '\0' < "$SMMC/status" 2>/dev/null)"
  if [ -e "$SMMC/keep-power-in-suspend" ]; then
    echo "  keep-power-in-suspend: present (harmless once the function driver is unbound)"
  else
    echo "  keep-power-in-suspend: absent"
  fi
else
  echo "  mmc@fe000000 node NOT FOUND"
fi

# --- stage 1: prove the round trip is safe --------------------------------
echo
echo "=== stage 1: SDIO unbind/rebind round trip (no suspend) ==="
/usr/sbin/rg353ps-wifi-cycle status

if /usr/sbin/rg353ps-wifi-cycle cycle-test; then
  echo "STAGE 1 PASSED: the WiFi function came back without suspending"
else
  echo "STAGE 1 FAILED: not suspending; the driver did not recover"
  /usr/sbin/rg353ps-wifi-cycle status
  echo
  echo "Leaving the system running normally. Check the messages above and the"
  echo "dmesg excerpt below, then report back before trying deep suspend."
  dmesg 2>/dev/null | grep -iE 'mmc2|sdio|rtw88|cfg80211' | tail -40
  exit 1
fi

# --- stage 2: the actual measurement --------------------------------------
echo
echo "=== stage 2: deep suspend, WiFi power cut, RTC wake in ${SLEEP_SECS}s ==="
echo "A detailed report will appear next to this one as"
echo "  $BOOT/rg353ps-suspend-deep-<timestamp>.txt"
echo "The screen will go dark. If it is still dark after $((SLEEP_SECS / 60)) minutes,"
echo "press the power button once to wake the unit."
echo

/usr/sbin/rg353ps-suspend-deep --wifi-off --settle "$SETTLE_SECS" --wake-after "$SLEEP_SECS"
RC=$?
echo "stage 2 exit status: $RC"

# --- wrap up ---------------------------------------------------------------
echo
echo "=== final state ==="
/usr/sbin/rg353ps-wifi-cycle status
dmesg 2>/dev/null | grep -iE 'suspend|resume|mmc2|sdio|rtw88|vcc_wifi' | tail -60

echo
echo "=============================================================="
echo "finished: $(date 2>/dev/null || echo unknown)"
echo "Read BASEOS-RUN-LOG.txt and rg353ps-suspend-deep-*.txt off the card."
echo "=============================================================="

exit "$RC"
