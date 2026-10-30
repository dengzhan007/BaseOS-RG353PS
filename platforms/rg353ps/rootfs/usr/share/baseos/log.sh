# Boot record keeping, sourced by everything that logs.
#
# One log: /mnt/boot/baseos.log, copied line for line to the data volume when
# one is mounted, so it can be read on any computer without adb. It appends
# across boots; rcS's boot record is what delimits them.
#
# RG353PS has no separate /data filesystem: the boot volume is the persistent
# place available before the data volume is mounted, and it is FAT, so it is
# also the one a PC can read straight off the card.
#
# Builtins only. Every caller is on the boot path, where a fork costs ~8 ms.

BASEOS_LOG=/mnt/boot/baseos.log
BASEOS_LOG_CARD=/mnt/SDCARD/baseos.log
BASEOS_LOG_TAG="${0##*/}"

# Uptime breadcrumb in /run, read back by the boot-time measurements.
mark() {
	read -r _up _rest < /proc/uptime
	echo "$_up" > "$1"
}

# $LOG_DESTS: the copies whose filesystem is mounted right now. On the mounts
# rather than the directories, because writing through an unmounted mount point
# leaves a stray file on the root filesystem — which at shutdown is already on
# its way to read-only.
#
# debug= in baseos.conf decides whether the data-volume copy is written too. The
# two copies are identical line for line, and the boot one is the one a PC can
# read off the card, so the duplicate is the one to drop. Same switch as
# baseos-usb-storage and rg353ps-hotkeyd use. The card copy of baseos.conf wins
# over /etc, so it can be turned on without rebuilding anything.
config_debug_flag() {
	_cfg=""
	for _c in /mnt/boot/baseos.conf /etc/baseos.conf; do
		[ -r "$_c" ] || continue
		while IFS='=' read -r _k _v; do
			case "$_k" in debug) _cfg="$_v"; break ;; esac
		done < "$_c"
		[ -n "$_cfg" ] && break
	done
	case "$_cfg" in yes|YES|Yes|1|on) printf 'yes' ;; *) printf 'no' ;; esac
}

log_dests() {
	_boot=""; _card=""
	LOG_DEBUG=$(config_debug_flag)
	while read -r _ _m _; do
		case "$_m" in
			/mnt/boot) _boot="$BASEOS_LOG" ;;
			/mnt/SDCARD) [ "$LOG_DEBUG" = yes ] && _card="$BASEOS_LOG_CARD" ;;
		esac
	done < /proc/mounts
	LOG_DESTS="$_boot $_card"
}

log() {
	read -r _up _rest < /proc/uptime
	log_dests
	for _f in $LOG_DESTS; do
		echo "$_up $BASEOS_LOG_TAG: $*" >> "$_f" 2>/dev/null
	done
	# The boot copy appends across boots, so bound it: a card that has been
	# updated a few dozen times still reads fine, but a card that has been
	# updated a few hundred times does not need the first one. Trimmed from the
	# tail, keeping the most recent history.
	if [ -f "$BASEOS_LOG" ]; then
		_lines=$(wc -l < "$BASEOS_LOG" 2>/dev/null || echo 0)
		case "$_lines" in
			''|*[!0-9]*) _lines=0 ;;
		esac
		if [ "$_lines" -gt 400 ]; then
			tail -n 200 "$BASEOS_LOG" > "$BASEOS_LOG.tmp" 2>/dev/null &&
				mv "$BASEOS_LOG.tmp" "$BASEOS_LOG" 2>/dev/null ||
				rm -f "$BASEOS_LOG.tmp" 2>/dev/null
		fi
	fi
	return 0
}
