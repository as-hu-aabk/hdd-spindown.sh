#!/bin/bash

# hdd-spindown.sh
# ---------------
# Automatic Disk Standby Using Kernel Diskstats, hdparm and openSeaChest
# (C) 2011-2021 Alexander Koch <mail@alexanderkoch.net>
# (C) 2026 Attila Bartok <attila.bartok@alonesolution.com>
#
# Released under the terms of the MIT License, see 'LICENSE'
#
# Usage:
#   hdd-spindown.sh           run the monitoring loop (normally via systemd)
#   hdd-spindown.sh status    print the power state of all disks and exit
#   hdd-spindown.sh version   print the version and exit
#
# How it works:
#   Every CONF_INT seconds the read/write counters of each configured disk
#   are read from /sys/block/<dev>/stat. If they have not changed for the
#   disk's timeout, the disk is put into standby. Power state queries and
#   spindown use openSeaChest for Seagate drives (see CONF_SEACHEST) and
#   smartctl/hdparm for all others. None of the state queries wake up a disk.


readonly VERSION="2.0.2"

# default configuration file, may be overridden via environment
readonly CONFIG="${CONFIG:-/etc/hdd-spindown.rc}"

# 'version' needs neither a config file nor root privileges
if [ "$1" == "version" ]; then
	echo "hdd-spindown.sh $VERSION"
	exit 0
fi

# Global state
# ------------
# Indexed arrays, one entry per CONF_DEV entry (index = position in CONF_DEV):
#   DEVNAMES[i]  device name as configured (kernel name or by-id name)
#   DEVICES[i]   resolved kernel device name, e.g. 'sdc'
#   TIMEOUT[i]   idle timeout in seconds
#   COUNT[i]     last recorded "reads writes" counters
#   STAMP[i]     time (epoch seconds) of the last detected I/O
#
# Associative arrays keyed by kernel device name:
#   SEACHEST[dev]   1 if openSeaChest is used for this disk, 0 otherwise
#   DOWNSTAMP[dev]  time of the last successful spindown, unset once the
#                   disk was seen spinning again
declare -A SEACHEST DOWNSTAMP
# devices already reported as missing or skipped (value 'missing' or 'ssd'),
# keyed by name, so each is logged only once instead of every interval
declare -A REPORTED


# check_req <command>...
# Exit with an error if any of the given commands is not in PATH.
function check_req() {
	FAIL=0
	for CMD in "$@"; do
		which "$CMD" &>/dev/null && continue
		echo "error: missing '$CMD' executable in PATH" >&2
		FAIL=1
	done
	[ $FAIL -ne 0 ] && exit 1
}

# log <message>
# Write a message to syslog (CONF_SYSLOG=1) or stdout, which systemd
# forwards to the journal. Silenced while QUIET is set ('status' command).
function log() {
	[ -n "$QUIET" ] && return 0
	if [ "$CONF_SYSLOG" -eq 1 ]; then
		logger -t "hdd-spindown.sh" --id=$$ "$1"
	else
		echo "$1"
	fi
}

# selftest_active <dev>
# Return 0 if a SMART self-test is currently running on the disk.
function selftest_active() {
	$SMARTCTL -a "/dev/$1" | grep -q "Self-test routine in progress"
	return $?
}

# dev_stats <dev>
# Print the number of completed reads and writes of the disk, taken from
# fields 1 and 5 of /sys/block/<dev>/stat. Passthrough commands such as
# smartctl or openSeaChest queries do not change these counters.
function dev_stats() {
	read -r R_IO _ _ _ W_IO _ < "/sys/block/$1/stat"
	echo "$R_IO $W_IO"
}

# dev_isup <dev>
# Return 0 if the disk is spinning (active or idle), 1 if it is in standby.
# Querying the state does not wake up the disk.
function dev_isup() {
	if [ "${SEACHEST[$1]}" == "1" ]; then
		# openSeaChest reports ATA power modes:
		# PM0 active, PM1 idle (incl. EPC Idle_A/B/C), PM2 standby, PM3 sleep
		STATE="$($SEACHEST_CMD -d "/dev/$1" --checkPowerMode 2>&1)"
		echo "$STATE" | grep -q -e PM2 -e PM3 && return 1
		echo "$STATE" | grep -q -e PM0 -e PM1 && return 0
		# assume spinning so spindown is not silently skipped
		log "unknown power state for $1: $(echo "$STATE" | grep -m 1 'Device is')"
		return 0
	fi

	# '-n standby' makes smartctl skip the query instead of waking the disk;
	# its output then mentions STANDBY instead of ACTIVE or IDLE
	STATE="$($SMARTCTL -i -n standby "/dev/$1")"
	echo "$STATE" | grep -q -e ACTIVE -e IDLE && return 0
	echo "$STATE" | grep -q -i standby || log "unknown power state for $1"
	return 1
}

# dev_spindown <dev>
# Put the disk into standby unless it already is or a self-test is running.
# Return 1 if the spindown command failed, 0 otherwise.
function dev_spindown() {
	# skip spindown if already spun down
	dev_isup "$1" || return 0

	# omit spindown if SMART Self-Test in progress
	selftest_active "$1" && return 0

	# spindown disk
	log "suspending $1"
	if [ "${SEACHEST[$1]}" == "1" ]; then
		# standby is the EPC Standby_Z condition on drives supporting EPC
		$SEACHEST_CMD -d "/dev/$1" --transitionPower standby &>/dev/null
		RC=$?
		# fall back to Standby Immediate if power transition is unsupported
		# (openSeaChest exit code 4 = operation not supported)
		if [ $RC -eq 4 ]; then
			$SEACHEST_CMD -d "/dev/$1" --spinDown &>/dev/null
			RC=$?
		fi
	else
		# ATA Standby Immediate
		hdparm -qy "/dev/$1"
		RC=$?
	fi
	if [ $RC -gt 0 ]; then
		log "failed to suspend $1"
		return 1
	fi

	# remember the spindown so a later wakeup can be reported
	DOWNSTAMP[$1]=$(date +%s)
	return 0
}

# dev_spinup <dev>
# Spin up the disk by reading from it, unless it is already spinning.
function dev_spinup() {
	# skip spinup if already online
	dev_isup "$1" && return 0

	# read raw blocks, bypassing cache
	log "spinning up $1"
	# intentional wakeup, do not report it as unexpected
	unset "DOWNSTAMP[$1]"
	dd if="/dev/$1" of=/dev/null bs=1M count="$CONF_READLEN" iflag=direct &>/dev/null
}

# update_presence
# Presence feature: set USER_PRESENT=1 if any host in CONF_HOSTS answers a
# ping, 0 otherwise. While a user is present, disks are kept spinning.
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

# init_dev <index>
# Resolve the kernel device name of CONF_DEV entry <index> into DEV (and
# DEVICES[index]) and decide whether openSeaChest is used for it.
# Return 0 if the disk can be monitored, 1 if it is missing, 2 if it is an
# SSD. Called on every check, so a disk attached later is picked up.
function init_dev() {
	# initialize real device name, re-resolving the configured name if the
	# device vanished (e.g. disk re-attached under a different node)
	DEV="${DEVICES[$1]}"
	if ! [ -e "/dev/$DEV" ]; then
		NAME="${DEVNAMES[$1]}"
		if [ -L "/dev/disk/by-id/$NAME" ]; then
			# by-id name: follow the symlink to the kernel name
			DEV="$(basename "$(readlink "/dev/disk/by-id/$NAME")")"
			log "recognized disk: $NAME --> $DEV"
			DEVICES[$1]="$DEV"
		elif [ -e "/dev/$NAME" ]; then
			# kernel name that is present (again)
			DEV="$NAME"
			DEVICES[$1]="$DEV"
		else
			[ -z "${REPORTED[$NAME]}" ] && log "skipping missing device '$NAME'"
			REPORTED[$NAME]=missing
			return 1
		fi
		# present again, report it if it goes missing later
		unset "REPORTED[$NAME]"
	fi

	# SSDs need no spindown
	if [ "$(cat "/sys/block/$DEV/queue/rotational" 2>/dev/null)" == "0" ]; then
		[ -z "${REPORTED[$DEV]}" ] && log "skipping $DEV: SSD, no spindown needed"
		REPORTED[$DEV]=ssd
		return 2
	fi

	# select openSeaChest for Seagate drives (decided once per device);
	# Seagate model numbers start with 'ST', e.g. 'ST22000NM000C'
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

# check_dev <index>
# One monitoring step for CONF_DEV entry <index>: report unexpected
# wakeups, handle user presence, and spin the disk down once it has been
# idle for its timeout.
function check_dev() {
	init_dev "$1" || return 0

	# initialize r/w timestamp
	[ -z "${STAMP[$1]}" ] && STAMP[$1]=$(date +%s)

	# report drives that woke up since the last spindown; changed counters
	# mean some process accessed the disk, unchanged ones point to the
	# drive itself or to passthrough commands (e.g. smartd without -n)
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
			if [ $(($(date +%s) - ${STAMP[$1]})) -ge "${TIMEOUT[$1]}" ]; then
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


# read config file (plain shell code defining CONF_* variables)
if ! [ -r "$CONFIG" ]; then
	echo "error: unable to read config file '$CONFIG', aborting." >&2
	exit 1
else
	# shellcheck source=hdd-spindown.rc
	source "$CONFIG"
fi

# apply defaults for options not set in the config file
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

# check prerequisites; optional tools only if the related feature is used
check_req date hdparm smartctl dd cut grep
[ -n "$CONF_HOSTS" ] && check_req ping
[ "$CONF_SYSLOG" -eq 1 ] && check_req logger
[ "$CONF_SEACHEST" == "1" ] && check_req openSeaChest_PowerControl
# in 'auto' mode openSeaChest is used only if installed
HAVE_SEACHEST=0
which openSeaChest_PowerControl &>/dev/null && HAVE_SEACHEST=1
readonly SEACHEST_CMD="openSeaChest_PowerControl --noBanner"

# pre-set smartctl call ('-d sat' for USB enclosures that need it)
[ "$CONF_FORCE_SATA" -eq 1 ] && SMARTCTL=" -d sat"
readonly SMARTCTL="smartctl${SMARTCTL}"

# refuse to work without disks defined
if [ -z "$CONF_DEV" ]; then
	echo "error: missing configuration parameter 'CONF_DEV', aborting." >&2
	exit 1
fi

# initialize device arrays by splitting CONF_DEV entries 'name|timeout';
# names are resolved to kernel names later by init_dev
DEV_MAX=$((${#CONF_DEV[@]} - 1))
for I in $(seq 0 $DEV_MAX); do
	DEVICES[$I]="$(echo "${CONF_DEV[$I]}" | cut -d '|' -f 1)"
	DEVNAMES[$I]="${DEVICES[$I]}"
	TIMEOUT[$I]="$(echo "${CONF_DEV[$I]}" | cut -d '|' -f 2)"
done

# print power state of all configured devices and exit
if [ "$1" == "status" ]; then
	# no log messages, only the status table
	QUIET=1
	{
	# configured disks
	for I in $(seq 0 $DEV_MAX); do
		NAME="${DEVNAMES[$I]}"
		init_dev "$I"
		case $? in
			1) echo "$NAME: missing"; continue ;;
			2) echo "$DEV ($NAME, SSD): not monitored, no spindown needed"; continue ;;
		esac
		TOOL=smartctl
		[ "${SEACHEST[$DEV]}" == "1" ] && TOOL=openSeaChest
		if dev_isup "$DEV"; then STATE="active/idle"; else STATE="standby"; fi
		echo "$DEV ($NAME, $TOOL): $STATE"
	done

	# list remaining physical disks, e.g. SSDs that need no spindown;
	# entries without a 'device' link (md, loop, ...) are not physical disks
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

# main loop
USER_PRESENT=0
log "hdd-spindown.sh $VERSION, using ${CONF_INT}s interval"

while true; do
	update_presence

	for I in $(seq 0 $DEV_MAX); do
		check_dev "$I"
	done

	sleep "$CONF_INT"
done
