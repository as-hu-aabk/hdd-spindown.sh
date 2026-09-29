#!/bin/bash

# hdd-spindown.sh
# ---------------
# Automatic Disk Standby Using Kernel Diskstats and hdparm
# (C) 2011-2021 Alexander Koch <mail@alexanderkoch.net>
#
# Released under the terms of the MIT License, see 'LICENSE'


readonly VERSION="2.0.0"

# default configuration file
readonly CONFIG="${CONFIG:-/etc/hdd-spindown.rc}"

if [ "$1" == "version" ]; then
	echo "hdd-spindown.sh $VERSION"
	exit 0
fi

# per-device state keyed by kernel device name
declare -A SEACHEST DOWNSTAMP


function check_req() {
	FAIL=0
	for CMD in $@; do
		which $CMD &>/dev/null && continue
		echo "error: missing '$CMD' executable in PATH" >&2
		FAIL=1
	done
	[ $FAIL -ne 0 ] && exit 1
}

function log() {
	[ -n "$QUIET" ] && return 0
	if [ $CONF_SYSLOG -eq 1 ]; then
		logger -t "hdd-spindown.sh" --id=$$ "$1"
	else
		echo "$1"
	fi
}

function selftest_active() {
	$SMARTCTL -a "/dev/$1" | grep -q "Self-test routine in progress"
	return $?
}

function dev_stats() {
	read R_IO R_M R_S R_T W_IO REST < "/sys/block/$1/stat"
	echo "$R_IO $W_IO"
}

function dev_isup() {
	if [ "${SEACHEST[$1]}" == "1" ]; then
		STATE="$($SEACHEST_CMD -d "/dev/$1" --checkPowerMode 2>&1)"
		echo "$STATE" | grep -q -e PM2 -e PM3 && return 1
		echo "$STATE" | grep -q -e PM0 -e PM1 && return 0
		# assume spinning so spindown is not silently skipped
		log "unknown power state for $1: $(echo "$STATE" | grep -m 1 'Device is')"
		return 0
	fi

	STATE="$($SMARTCTL -i -n standby "/dev/$1")"
	echo "$STATE" | grep -q -e ACTIVE -e IDLE && return 0
	echo "$STATE" | grep -q -i standby || log "unknown power state for $1"
	return 1
}

function dev_spindown() {
	# skip spindown if already spun down
	dev_isup "$1" || return 0

	# omit spindown if SMART Self-Test in progress
	selftest_active "$1" && return 0

	# spindown disk
	log "suspending $1"
	if [ "${SEACHEST[$1]}" == "1" ]; then
		$SEACHEST_CMD -d "/dev/$1" --transitionPower standby &>/dev/null
		RC=$?
		# fall back to Standby Immediate if power transition is unsupported
		if [ $RC -eq 4 ]; then
			$SEACHEST_CMD -d "/dev/$1" --spinDown &>/dev/null
			RC=$?
		fi
	else
		hdparm -qy "/dev/$1"
		RC=$?
	fi
	if [ $RC -gt 0 ]; then
		log "failed to suspend $1"
		return 1
	fi

	DOWNSTAMP[$1]=$(date +%s)
	return 0
}

function dev_spinup() {
	# skip spinup if already online
	dev_isup "$1" && return 0

	# read raw blocks, bypassing cache
	log "spinning up $1"
	unset "DOWNSTAMP[$1]"
	dd if=/dev/$1 of=/dev/null bs=1M count=$CONF_READLEN iflag=direct &>/dev/null
}

function update_presence() {
	# no action if no hosts defined
	[ -z "$CONF_HOSTS" ] && return 0

	# assume present if any host is ping'able
	for H in "${CONF_HOSTS[@]}"; do
		if ping -c 1 -q "$H" &>/dev/null; then
			if [ $USER_PRESENT -eq 0 ]; then
				log "active host detected ($H)"
				USER_PRESENT=1
			fi
			return 0
		fi
	done

	# absent
	if [ $USER_PRESENT -eq 1 ]; then
		log "all hosts inactive"
		USER_PRESENT=0
	fi

	return 0
}

function init_dev() {
	# initialize real device name
	DEV="${DEVICES[$1]}"
	if ! [ -e "/dev/$DEV" ]; then
		if [ -L "/dev/disk/by-id/$DEV" ]; then
			DEV="$(basename "$(readlink "/dev/disk/by-id/$DEV")")"
			log "recognized disk: ${DEVICES[$1]} --> $DEV"
			DEVICES[$1]="$DEV"
		else
			log "skipping missing device '$DEV'" >&2
			return 1
		fi
	fi

	# select openSeaChest for Seagate drives
	if [ -z "${SEACHEST[$DEV]}" ]; then
		SEACHEST[$DEV]=0
		if [ "$CONF_SEACHEST" == "1" ] || { [ "$CONF_SEACHEST" == "auto" ] && \
				[ $HAVE_SEACHEST -eq 1 ] && \
				grep -q '^ST' "/sys/block/$DEV/device/model" 2>/dev/null; }; then
			SEACHEST[$DEV]=1
			log "using openSeaChest for $DEV"
		fi
	fi
}

function check_dev() {
	init_dev "$1" || return 0

	# initialize r/w timestamp
	[ -z "${STAMP[$1]}" ] && STAMP[$1]=$(date +%s)

	# report drives that woke up since the last spindown
	if [ -n "${DOWNSTAMP[$DEV]}" ] && dev_isup "$DEV"; then
		IO=no
		[ "${COUNT[$1]}" != "$(dev_stats "$DEV")" ] && IO=yes
		log "$DEV woke up within $(($(date +%s) - ${DOWNSTAMP[$DEV]}))s of spindown (I/O: $IO)"
		unset "DOWNSTAMP[$DEV]"
	fi

	# check for user presence, spin up if required
	if [ $USER_PRESENT -eq 1 ]; then
		dev_isup "$DEV" || dev_spinup "$DEV"
	fi

	# refresh r/w stats
	COUNT_NEW="$(dev_stats "$DEV")"

	# spindown logic if stats equal previous recordings
	if [ "${COUNT[$1]}" == "$COUNT_NEW" ]; then
		# skip spindown if user present
		if [ $USER_PRESENT -eq 0 ]; then
			# check against idle timeout
			if [ $(($(date +%s) - ${STAMP[$1]})) -ge ${TIMEOUT[$1]} ]; then
				# spindown disk
				dev_spindown "$DEV"
			fi
		fi
	else
		# update r/w timestamp
		COUNT[$1]="$COUNT_NEW"
		STAMP[$1]=$(date +%s)
	fi
}


# read config file
if ! [ -r "$CONFIG" ]; then
	echo "error: unable to read config file '$CONFIG', aborting." >&2
	exit 1
else
    source "$CONFIG"
fi

# default watch interval: 300s
readonly CONF_INT=${CONF_INT:-300}
# default spinup read size: 128MiB
readonly CONF_READLEN=${CONF_READLEN:-128}
# default syslog usage: disabled
readonly CONF_SYSLOG=${CONF_SYSLOG:-0}
# default force SATA device type: disabled
readonly CONF_FORCE_SATA=${CONF_FORCE_SATA:-0}
# default openSeaChest usage: auto-detect Seagate drives
readonly CONF_SEACHEST=${CONF_SEACHEST:-auto}

# check prerequisites
check_req date hdparm smartctl dd cut grep
[ -n "$CONF_HOSTS" ] && check_req ping
[ $CONF_SYSLOG -eq 1 ] && check_req logger
[ "$CONF_SEACHEST" == "1" ] && check_req openSeaChest_PowerControl
HAVE_SEACHEST=0
which openSeaChest_PowerControl &>/dev/null && HAVE_SEACHEST=1
readonly SEACHEST_CMD="openSeaChest_PowerControl --noBanner"

# pre-set smartctl call
[ $CONF_FORCE_SATA -eq 1 ] && SMARTCTL=" -d sat"
readonly SMARTCTL="smartctl${SMARTCTL}"

# refuse to work without disks defined
if [ -z "$CONF_DEV" ]; then
	echo "error: missing configuration parameter 'CONF_DEV', aborting." >&2
	exit 1
fi

# initialize device arrays
DEV_MAX=$((${#CONF_DEV[@]} - 1))
for I in $(seq 0 $DEV_MAX); do
	DEVICES[$I]="$(echo "${CONF_DEV[$I]}" | cut -d '|' -f 1)"
	TIMEOUT[$I]="$(echo "${CONF_DEV[$I]}" | cut -d '|' -f 2)"
done

# print power state of all configured devices and exit
if [ "$1" == "status" ]; then
	QUIET=1
	{
	for I in $(seq 0 $DEV_MAX); do
		NAME="${DEVICES[$I]}"
		if ! init_dev $I; then
			echo "$NAME: missing"
			continue
		fi
		TOOL=smartctl
		[ "${SEACHEST[$DEV]}" == "1" ] && TOOL=openSeaChest
		if dev_isup "$DEV"; then STATE="active/idle"; else STATE="standby"; fi
		echo "$DEV ($NAME, $TOOL): $STATE"
	done

	# list remaining physical disks, e.g. SSDs that need no spindown
	for B in /sys/block/*; do
		DEV="$(basename "$B")"
		[ -e "$B/device" ] || continue
		[[ " ${DEVICES[*]} " == *" $DEV "* ]] && continue
		NAME="$(basename "$(find /dev/disk/by-id -lname "*/$DEV" -name 'ata-*' | head -n 1)")"
		if [ "$(cat "$B/queue/rotational")" == "0" ]; then
			echo "$DEV (${NAME:-$DEV}, SSD): not monitored, no spindown needed"
		else
			echo "$DEV (${NAME:-$DEV}, HDD): not monitored"
		fi
	done
	# sort by device name, shorter first (sdz before sdaa)
	} | awk '{ print length($1), $0 }' | sort -k1,1n -k2,2 | cut -d ' ' -f 2-
	exit 0
fi

USER_PRESENT=0
log "hdd-spindown.sh $VERSION, using ${CONF_INT}s interval"

while true; do
	update_presence

	for I in $(seq 0 $DEV_MAX); do
		check_dev $I
	done

	sleep $CONF_INT
done
