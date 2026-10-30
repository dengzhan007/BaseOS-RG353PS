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
log_dests() {
	_boot=""; _card=""
	while read -r _ _m _; do
		case "$_m" in
			/mnt/boot) _boot="$BASEOS_LOG" ;;
			/mnt/SDCARD) _card="$BASEOS_LOG_CARD" ;;
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
	return 0
}
