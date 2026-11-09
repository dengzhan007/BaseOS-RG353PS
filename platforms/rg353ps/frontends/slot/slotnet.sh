#!/bin/sh
# BaseOS compatibility adapter for Slot's card-side System/slotnet.sh contract.
#
# Slot expects:
#   scan -> SSID<TAB>signal-dBm<TAB>secured(0|1)
#   up   -> start Wi-Fi + DHCP and write the assigned address to /tmp/slot-ip
#   down -> stop the Wi-Fi session started through this adapter
#
# The RG353PS BaseOS owns the actual radio stack through
# /usr/sbin/rg353ps-wifi-connect. Keep the frontend-facing contract here rather
# than teaching the frontend about BaseOS internals.
set -u

HELPER=/usr/sbin/rg353ps-wifi-connect
IP_FILE=/tmp/slot-ip

die() {
  echo "slotnet.sh: $*" >&2
  exit 1
}

[ -x "$HELPER" ] || die "$HELPER is missing"
[ "$#" -ge 1 ] || die "usage: $0 up|down|scan|status"

wait_for_ip() {
  rm -f "$IP_FILE" 2>/dev/null || :
  i=0
  while [ "$i" -lt 300 ]; do
    ip_addr=$(ip -4 -o addr show dev wlan0 2>/dev/null | awk 'NR==1 { split($4, a, "/"); print a[1] }')
    case "$ip_addr" in
      ""|127.*) ;;
      *)
        printf '%s\n' "$ip_addr" > "$IP_FILE.tmp" &&
          mv -f "$IP_FILE.tmp" "$IP_FILE"
        return 0
        ;;
    esac
    sleep 0.2
    i=$((i + 1))
  done
  "$HELPER" status >&2 || :
  return 1
}

case "$1" in
  up)
    "$HELPER" up || exit $?
    wait_for_ip || die "Wi-Fi started but DHCP did not assign an IPv4 address within 60 seconds"
    ;;
  down)
    "$HELPER" down
    rc=$?
    rm -f "$IP_FILE" "$IP_FILE.tmp" 2>/dev/null || :
    exit "$rc"
    ;;
  scan)
    # BaseOS helper order: signal<TAB>flags<TAB>frequency<TAB>SSID.
    # Slot parser order: SSID<TAB>signal<TAB>secured.
    "$HELPER" scan | awk -F '\t' '
      NF >= 4 {
        signal = $1
        flags = $2
        ssid = $4
        secured = (flags ~ /(WPA|RSN|WEP)/) ? 1 : 0
        if (ssid != "") printf "%s\t%s\t%d\n", ssid, signal, secured
      }
    '
    ;;
  status)
    "$HELPER" status
    ;;
  *)
    die "unknown command '$1' (up|down|scan|status)"
    ;;
esac
