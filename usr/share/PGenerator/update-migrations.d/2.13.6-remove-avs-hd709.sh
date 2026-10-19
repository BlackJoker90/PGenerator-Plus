#!/bin/sh

set -eu

# The AVS HD 709 diagnostic videos were dropped from the WebUI in 2.13.6; the
# built-in test images cover the same checks. Remove the bundled frame sets
# and the five source videos so an OTA installation matches the new release.
rm -rf -- /var/lib/PGenerator/diagseq /var/lib/PGenerator/diagseq_full

avs_dir="/var/lib/PGenerator/video/Basic Settings"
if [ -d "$avs_dir" ]; then
 rm -f -- "$avs_dir/1-Black Clipping.mp4" \
  "$avs_dir/2-APL Clipping.mp4" \
  "$avs_dir/3-White Clipping.mp4" \
  "$avs_dir/4-Flashing Color Bars.mp4" \
  "$avs_dir/5-Sharpness & Overscan.mp4"
 rmdir -- "$avs_dir" 2>/dev/null || true
fi

printf 'Removed AVS HD 709 videos for %s -> %s\n' \
 "${PG_UPDATE_FROM:-unknown}" "${PG_UPDATE_TO:-unknown}"
