# hdd-spindown.sh

Automatic Disk Standby using Kernel diskstats, hdparm and openSeaChest

Version 2.0.1 (`hdd-spindown.sh version`)


## Summary

**hdd-spindown.sh** is a rather simple Bash script that enables automatic disk
standby for drives that do not support timeout-based spindown by firmware
(e.g. `-S` parameter for `hdparm`).

Seagate drives with Extended Power Conditions (EPC), such as the Exos series,
are supported via Seagate's `openSeaChest` tools, see *Seagate Drives* below.


## Usage, Requirements

The quickest way to set it up is the setup script, run as root:

    # ./setup.sh

It installs the script and service unit, generates `/etc/hdd-spindown.rc`
with all rotating disks found (SSDs are skipped, an existing configuration is
kept), and enables and starts the service. `./setup.sh -n` only prints the
configuration it would generate; `TIMEOUT=3600 ./setup.sh` changes the idle
timeout of generated entries (default 1800 seconds).

**hdd-spindown.sh** is best run via systemd, using the service unit provided.
In order to enable it, simply issue

    $ systemctl enable hdd-spindown.service

and adapt configuration file `/etc/hdd-spindown.rc` to suit your needs.

To print the current power state of all configured drives without waking
them up, run

    $ hdd-spindown.sh status

Apart from *coreutils* the following is required:
 * **smartctl:** for detection of drive status and SMART self-checks
 * **hdparm** for actually initiating drive standby
 * **grep** for utility output parsing

The following is optional, depending on the features used:
 * **logger** if syslog interface enabled
 * **ping** if host monitoring enabled
 * **openSeaChest_PowerControl** for Seagate drives using EPC power states,
   which `hdparm` and `smartctl` do not report reliably (used automatically
   when installed, see `CONF_SEACHEST`)


## Configuration

**hdd-spindown.sh** uses a simple shell-style configuration file for setting
the disks to monitor. An example may look like this:

    # configuration file for hdd-spindown.sh
    
    CONF_INT=300
    
    CONF_DEV=( "ata-WDC_WD50EFRX-68MYMN1_WD-WX31DA43KKCY|5400" \
               "ata-WDC_WD50EFRX-68MYMN1_WD-WX81DA4HNEH5|5400" \
               "ata-WDC_WD20EARS-00MVWB0_WD-WCAZA5755786|5400" \
               "ata-WDC_WD20EARS-00MVWB0_WD-WMAZA3570471|5400" )
  
`CONF_INT` specifies the monitoring interval in seconds while `CONF_DEV`
features a list of devices to monitor, as well as their timeout value in
seconds, separated by the pipe symbol '|'.

Note that devices may be specified using their ID (as shown) or device
name (e.g. 'sda'). The interval option may be omitted, which sets the
default interval of 5 minutes.

For a complete list of options please see the example `hdd-spindown.rc`.


## Seagate Drives

Many Seagate drives (e.g. Exos X16/X22) implement Extended Power Conditions
(EPC). Their idle states such as *Idle_A* or *Idle_B* are reported by
`hdparm -C` as `unknown`, so power state detection and spindown via
`hdparm`/`smartctl` are unreliable for them.

If `openSeaChest_PowerControl` (from Seagate's
[openSeaChest](https://github.com/Seagate/openSeaChest) utilities) is
installed, **hdd-spindown.sh** uses it for these drives:

 * power state: `openSeaChest_PowerControl --checkPowerMode`
   (PM0/PM1 = spinning, PM2 = standby)
 * spindown: `openSeaChest_PowerControl --transitionPower standby`
   (EPC *Standby_Z*), falling back to `--spinDown` if unsupported

This is controlled by the option `CONF_SEACHEST`:

 * `auto` (default): use openSeaChest for drives whose model starts with `ST`,
   if the tool is installed; other drives keep using `smartctl`/`hdparm`
 * `1`: use openSeaChest for all drives (the tool becomes mandatory)
 * `0`: never use openSeaChest

`hdd-spindown.sh status` shows which tool is used for each drive. When a drive
wakes up again after spindown, a log line like

    sdc woke up within 300s of spindown (I/O: yes)

tells whether the wakeup was caused by I/O (some process accessing the disk)
or not (drive firmware or passthrough commands).


## State of Development

I have replaced all of my rotating disks with flash based storage. I will
happily accept pull requests for improvements or bug fixes, but I will not be
able to test anything myself.

This fork (version 2.0.0) adds Seagate/openSeaChest support, the `status`
command, `setup.sh` and wakeup logging. It was developed on a system with
Seagate Exos ST22000NM000C and ST16000NM000J drives alongside a WD Red.


## License

This software is released under the terms of the MIT License, see file
*LICENSE*.
