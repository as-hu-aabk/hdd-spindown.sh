# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A single Bash daemon (`hdd-spindown.sh`) that puts disks into standby after a period of no I/O. It is meant for drives whose firmware does not support a timeout-based spindown (`hdparm -S`). It runs as a systemd service (`hdd-spindown.service`) and reads its configuration from `/etc/hdd-spindown.rc`.

The upstream author no longer has rotating disks and cannot test changes (see README, "State of Development"). Real behavior can only be checked on hardware with spinning disks.

## Commands

- Automatic setup: `./setup.sh` (root). Installs script and unit, generates `/etc/hdd-spindown.rc` from the rotating disks in `/sys/block` using by-id names (SSDs skipped, existing config kept), then enables and restarts the service. `./setup.sh -n` prints the generated config only; `TIMEOUT` sets the idle timeout (default 1800).
- Install: `make install` (supports `DESTDIR`, default `/`, and `PREFIX`, default `/usr`). This installs the script to `$PREFIX/bin`, the rc file to `/etc` (only if none exists), and the unit to `$PREFIX/lib/systemd/system`.
- Run against a local config: `CONFIG=./my.rc ./hdd-spindown.sh`. `CONFIG` overrides the default `/etc/hdd-spindown.rc`. The script loops forever and needs root for smartctl, hdparm and raw `dd` reads.
- Show power state of configured drives and exit: `hdd-spindown.sh status` (honours `CONFIG`). It shares `init_dev` (name resolution and openSeaChest selection) with the main loop's `check_dev`, and silences `log` via `QUIET`. Physical disks not in `CONF_DEV` are listed afterwards (SSDs detected via `/sys/block/<dev>/queue/rotational`).
- Version: `VERSION` at the top of `hdd-spindown.sh`, printed by `hdd-spindown.sh version` (works without a config) and logged at startup. When bumping it, also update the README line and add a `vX.Y.Z` git tag.
- Syntax check: `bash -n hdd-spindown.sh`. `shellcheck -x -e SC2004 hdd-spindown.sh setup.sh` should report nothing (SC2004 is style noise from the `ARRAY[$I]` indexing used throughout).
- There is no test suite, and there is no lint config.

## Architecture

- **Config**: the script `source`s the rc file as shell code. Every setting is a `CONF_*` variable. Defaults are applied after sourcing and then made `readonly`:
  - `CONF_INT`: 300
  - `CONF_READLEN`: 128 MiB
  - `CONF_SYSLOG`: 0
  - `CONF_FORCE_SATA`: 0
  - `CONF_SEACHEST`: auto

  To add an option: give it a default in the script, add a commented-out example to `hdd-spindown.rc`, and, if it needs a new external tool, add a conditional `check_req`.
- **Device list**: `CONF_DEV` is a Bash array of `"<name>|<timeout-seconds>"` entries, where `<name>` is either a kernel name (`sda`) or a `/dev/disk/by-id/` name. At startup these entries are split into the parallel arrays `DEVICES[]` and `TIMEOUT[]`. `check_dev` resolves by-id names to kernel names lazily, on first use, and writes the result back into `DEVICES[]`. Per-device state is held in two more parallel arrays, indexed the same way:
  - `COUNT[]`: the last read/write counts
  - `STAMP[]`: the time of the last activity
- **Main loop**: each iteration runs `update_presence`, then `check_dev` for each device, then sleeps `CONF_INT`.
  - Activity detection: `dev_stats` reads the read-I/O and write-I/O fields of `/sys/block/<dev>/stat`. If they have not changed and `TIMEOUT` has elapsed, the script calls `dev_spindown`, which runs `hdparm -y`.
- **Drive state**: all state checks go through `$SMARTCTL`, which is `smartctl` or `smartctl -d sat` when `CONF_FORCE_SATA=1` (for USB enclosures). `smartctl` has been used for this instead of hdparm since d7da889.
  - `dev_isup`: a drive is up if `smartctl -i -n standby` output contains ACTIVE or IDLE.
  - `dev_spindown`: skipped if the drive is already down or a SMART self-test is running (`selftest_active`).
  - openSeaChest branch: Seagate EPC drives report states such as IDLE_A that `hdparm -C` shows as `unknown`. For these drives `dev_isup` uses `openSeaChest_PowerControl --checkPowerMode`, where PM0/PM1 mean up and PM2/PM3 mean down, and `dev_spindown` uses `--transitionPower standby`. The choice is made per device in `check_dev` and stored in the associative array `SEACHEST[$DEV]`: `CONF_SEACHEST=auto` picks models starting with `ST` when the tool is installed, `1` forces it for every drive, `0` disables it.
  - Wake reporting: `DOWNSTAMP[$DEV]` records each successful spindown. When a drive that was spun down is found running again, `check_dev` logs the elapsed time and whether I/O counters changed.
- **Presence feature**: if `CONF_HOSTS` is set and any host in it answers a ping, the user counts as present. While the user is present, spindown is suppressed and drives that are down get spun up with a direct-I/O `dd` read of `CONF_READLEN` MiB.
- **Logging**: `log` sends messages to syslog (`logger -t hdd-spindown.sh`) when `CONF_SYSLOG=1`, and to stdout otherwise, which journald captures under systemd.
- **Dependencies** are checked at startup by `check_req`. When one is added or removed, update the README requirements list as well (see 919c9e4).
