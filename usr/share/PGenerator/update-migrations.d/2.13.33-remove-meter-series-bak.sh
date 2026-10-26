#!/bin/sh

set -eu

# meter_series.sh.bak was a stale copy of an old measurement script that
# shipped by mistake; nothing calls it. Remove it so an OTA installation
# matches the new release.
rm -f -- /usr/bin/meter_series.sh.bak

printf 'Removed meter_series.sh.bak for %s -> %s\n' \
 "${PG_UPDATE_FROM:-unknown}" "${PG_UPDATE_TO:-unknown}"
