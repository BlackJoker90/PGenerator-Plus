#!/bin/sh
set -eu

# Two leftovers of the BiasiLinux base image that cost time (measured on
# the Pi 4, 2026-11-16). PG_MIGRATION_ROOT: a tree to work on instead of /
# (tests).
root=${PG_MIGRATION_ROOT:-}

# /etc/cron.d/extra drops the page cache every 10 minutes
# ("echo 3 >/proc/sys/vm/drop_caches"). Afterwards the daemon, the
# renderer and every picture are read from the SD card again; in the boot
# of 2026-11-16 it fired in the middle of the daemon's start. The Pi 4 has
# about 3.4 GB free. Only that line goes: a file holding nothing else is
# removed, other lines in it stay.
cron="$root/etc/cron.d/extra"
if [ -f "$cron" ] && grep -q 'drop_caches' "$cron"; then
 if grep -v -E '^[[:space:]]*(#|$)' "$cron" | grep -q -v 'drop_caches'; then
  tmp="$cron.pgen-tmp"
  # Other lines are there, so grep exits 0, or 2 on a failed write: then
  # the file stays as it was and the update reports the migration failed.
  if ! grep -v 'drop_caches' "$cron" > "$tmp" || [ ! -s "$tmp" ]; then
   rm -f -- "$tmp"
   echo "ERROR: /etc/cron.d/extra not rewritten" >&2
   exit 1
  fi
  chmod 0644 "$tmp"
  mv -f "$tmp" "$cron"
  echo "Removed the drop_caches line from /etc/cron.d/extra"
 else
  rm -f -- "$cron"
  echo "Removed /etc/cron.d/extra (drop_caches every 10 minutes)"
 fi
fi

# rc2.d/S97ntpdate runs ntpdate before rcPGenerator, when eth0 has no link
# yet (link up at 18.7 s of uptime, rcPGenerator at 18.0 s on 2026-11-16)
# and WiFi is not started: it cannot reach the pool and only delays the
# boot. ntpd (S98ntp, "-g" in /etc/default/ntp) sets the clock once the
# network is there, also a clock far off. The ntpdate program stays
# (pgenerator-update calls it itself).
for dir in rc2.d rc3.d rc4.d rc5.d; do
 for link in "$root/etc/$dir"/S*ntpdate; do
  [ -L "$link" ] || continue
  case "$(readlink "$link")" in
   *init.d/ntpdate) rm -f -- "$link"; echo "Removed /etc/$dir/$(basename "$link")" ;;
  esac
 done
done
