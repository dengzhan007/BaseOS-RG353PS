#!/bin/sh
# Local regression tests for the two awk programs inside usb-reconnect-diag.sh.
# Both programs are extracted from the product script at run time, so the
# tests cannot silently drift away from what the device actually executes.
#
# Usage: sh test-usb-reconnect-diag-awk.sh [path/to/usb-reconnect-diag.sh]
# No device access, no root, no USB state changes.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${1:-"$HERE/usb-reconnect-diag.sh"}
# Relative to the current directory: some sandboxes reject rm -rf on paths
# that carry a Windows drive prefix.
TMP=.usb-diag-awk-test.$$
mkdir -p "$TMP" || exit 1
trap 'rm -rf "./$TMP"' 0 1 2 15

if [ ! -r "$SCRIPT" ]; then
    echo "FAIL: cannot read $SCRIPT" >&2
    exit 1
fi

# ---- extract the live kernel-stream filter -------------------------------
awk '
    /^[[:space:]]*awk -v max=/ { f = 1; next }
    f && /^[[:space:]]*}[[:space:]]*. \/proc\/kmsg/ { print "}"; exit }
    f { print }
' "$SCRIPT" >"$TMP/kmsg.awk"

# ---- extract the IRQ snapshot filter ------------------------------------
awk '
    /v=\$\(awk .$/ { f = 1; next }
    f && /^[[:space:]]*. \/proc\/interrupts/ { exit }
    f { print }
' "$SCRIPT" >"$TMP/irq.awk"

for f in "$TMP/kmsg.awk" "$TMP/irq.awk"; do
    if [ ! -s "$f" ]; then
        echo "FAIL: awk program not extracted from $SCRIPT ($f)" >&2
        exit 1
    fi
done

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
keep() { grep -Fq "$1" "$TMP/kmsg.out" && ok "kept: $1" || bad "MISSING: $1"; }
drop() { grep -Fq "$1" "$TMP/kmsg.out" && bad "UNEXPECTED: $1" || ok "dropped: $1"; }

# ---------------------------------------------------------------- samples
# 1 RG353PS PHY / DWC3, 2 plain enumeration, 3 usbcore, 4 gadget/UDC,
# 5 xHCI, 6 typec/role-switch, 7 Rockchip USB, 8 WARNING/ERROR,
# 9 unrelated prose (including a bare "usb"), 10 high-frequency data plane.
cat >"$TMP/kmsg.sample" <<'SAMPLE'
<7>[ 1.000000] rockchip_usb2phy: RG353PS BVALID IRQ entry: irq=20 pending=1 mode=2 state=1 bvalid=1
<7>[ 2.000000] dwc3 fcc00000.usb: RG353PS EP0 SETUP type=21 req=00 value=0000 index=0000 len=12
<6>[ 3.000000] usb 1-1: new high-speed USB device number 2 using xhci_hcd
<6>[ 4.000000] usbcore: registered new interface driver usb-storage
<6>[ 5.000000] gadget: high-speed config #1
<6>[ 5.100000] udc-core: fcc00000.usb: gadget unbound
<6>[ 6.000000] xhci_hcd 0000:00:14.0: new USB bus registered, assigned bus number 1
<6>[ 7.000000] typec port0: partner attached
<6>[ 7.100000] role-switch: switched to device
<6>[ 8.000000] rockchip_usb2phy fe8a0000.usb2phy: VBUS valid
<6>[ 9.000000] WARNING: at drivers/usb/dwc3/core.c:123
<3>[ 9.100000] dwc3: probe failed with error -110
<6>[10.000000] scheduler: completely unrelated kernel chatter
<6>[10.100000] my usb drive is slow today and this is prose, not a subsystem event
<7>[11.000000] dwc3: RG353PS EP2 REQMAP v17 phase=before-command cmd=4
<6>[11.100000] dwc3: RG353PS DWC3 bulk-out event epnum=2 event=2 status=6
<7>[11.200000] dwc3: RG353PS RESET EP2 snapshot flags=00000000
SAMPLE

cat >"$TMP/irq.sample" <<'SAMPLE'
           CPU0       CPU1       CPU2       CPU3
 20:          1          2          3          4  GICv3 167 Level     rockchip_usb2phy
 21:          5          6          7          8  GICv3 168 Level     rockchip_usb2phy
 31:         10         20         30         40  GICv3 201 Level     dwc3
 99:        100        200        300        400  GICv3 999 Level     timer
SAMPLE

echo "=== 样本输入：kmsg（17 行）==="
cat -n "$TMP/kmsg.sample"
echo
echo "=== 实际输出：kmsg 过滤（max=200）==="
awk -v max=200 -f "$TMP/kmsg.awk" "$TMP/kmsg.sample" | tee "$TMP/kmsg.out"
echo

echo "=== kmsg 断言 ==="
keep 'RG353PS BVALID IRQ entry'
keep 'RG353PS EP0 SETUP'
keep 'usb 1-1: new high-speed USB device'
keep 'usbcore: registered new interface driver'
keep 'gadget: high-speed config'
keep 'udc-core:'
keep 'xhci_hcd 0000:00:14.0'
keep 'typec port0'
keep 'role-switch:'
keep 'rockchip_usb2phy fe8a0000.usb2phy: VBUS valid'
keep 'WARNING: at drivers/usb/dwc3/core.c'
keep 'probe failed with error'
drop 'completely unrelated kernel chatter'
drop 'my usb drive is slow'
drop 'EP2 REQMAP'
drop 'bulk-out event'
drop 'RESET EP2 snapshot'

echo
echo "=== 样本输入：/proc/interrupts（4 CPU）==="
cat -n "$TMP/irq.sample"
echo
echo "=== 实际输出：IRQ 快照 ==="
awk -f "$TMP/irq.awk" "$TMP/irq.sample" | tee "$TMP/irq.out"
echo
echo "=== IRQ 断言 ==="
irq_out=$(cat "$TMP/irq.out")
for want in '20(total=10,desc=GICv3 167 Level rockchip_usb2phy)' \
            '21(total=26,desc=GICv3 168 Level rockchip_usb2phy)' \
            '31(total=100,desc=GICv3 201 Level dwc3)' \
            'cpus=4'; do
    case "$irq_out" in
        *"$want"*) ok "IRQ: $want" ;;
        *)         bad "IRQ MISSING: $want" ;;
    esac
done
case "$irq_out" in
    *'99('*) bad 'IRQ: unrelated timer IRQ was included' ;;
    *)       ok  'IRQ: unrelated timer IRQ excluded' ;;
esac
empty=$(awk -f "$TMP/irq.awk" /dev/null)
[ "$empty" = 'N/A' ] && ok 'IRQ: empty input -> N/A' || bad "IRQ: empty input gave '$empty'"

echo
echo "=== 总行数上限（kmsg max=3）==="
awk -v max=3 -f "$TMP/kmsg.awk" "$TMP/kmsg.sample" >"$TMP/limit.out"
n=$(wc -l <"$TMP/limit.out" | tr -d ' ')
cat "$TMP/limit.out"
[ "$n" = 3 ] && ok "limit: 3 lines written" || bad "limit: wrote $n lines"

echo
echo "=== 结果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ] || exit 1
exit 0
