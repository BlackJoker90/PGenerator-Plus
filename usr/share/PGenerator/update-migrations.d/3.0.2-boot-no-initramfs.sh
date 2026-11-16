#!/bin/sh
set -eu

# Boot the Pi 4 without the 23 MB initramfs. The firmware loads the kernel
# about 2.5 s sooner without it, and the kernel mounts the root
# filesystem at 1.9 s instead of 6.0 s (its /init starts udev, sleeps and
# polls the mount once a second). Measured on the Pi 4 on 2026-11-16, same
# 3.0.1 software, two boots each: the picture at 21-22 s of uptime instead
# of 25 s; Bluetooth, WiFi and the access point come up as before. The
# kernel finds the root partition by its PARTUUID (ext4 and the SD driver
# are built in); a LABEL needs the initramfs.
#
# The change takes effect on the next reboot. It is made only where it was
# tested: a Raspberry Pi 4 whose root filesystem is on the SD card.
# cmdline.txt is written before config.txt: in between, the initramfs
# still boots with root=PARTUUID (its mount is util-linux 2.26, the same
# as the system's, and resolves the tag); the other order, root=LABEL
# without an initramfs, would not boot. The initramfs.gz file stays on the
# boot partition, so re-enabling its config.txt line goes back.
#
# The WebUI edits config.txt in the copy under /boot/loader/boot_dir and
# copies it onto the boot partition (device-bootloader). That copy is set
# to the boot partition's files afterwards, so a later GPU memory change
# keeps the initramfs line commented out (the copy had also missed
# disable_splash and max_usb_current that the image put on the partition).
#
# Tests: PG_MIGRATION_ROOT (a tree in place of /), PG_BOOT_DIR (an already
# mounted boot partition), PG_ROOT_DEVNAME, PG_ROOT_PARTUUID, PG_MODEL,
# PG_KERNEL_CONFIG.
root=${PG_MIGRATION_ROOT:-}

skip() { echo "Boot without initramfs: not changed ($1)"; exit 0; }

model=${PG_MODEL:-$(tr -d '\000' < /proc/device-tree/model 2>/dev/null || true)}
case "$model" in
 "Raspberry Pi 4 "*) ;;
 *) skip "model \"$model\", tested on the Raspberry Pi 4 only" ;;
esac

if [ -n "${PG_ROOT_DEVNAME:-}" ]; then
 root_dev=$PG_ROOT_DEVNAME
else
 majmin=$(mountpoint -d / 2>/dev/null || true)
 root_dev=$(sed -n 's/^DEVNAME=//p' "/sys/dev/block/$majmin/uevent" 2>/dev/null || true)
fi
case "$root_dev" in
 mmcblk[0-9]p[0-9]) ;;
 *) skip "root filesystem on \"$root_dev\", tested on the SD card only" ;;
esac

kconfig=${PG_KERNEL_CONFIG:-/boot/config-$(uname -r)}
for opt in CONFIG_EXT4_FS CONFIG_MMC_BLOCK CONFIG_MMC_SDHCI_IPROC CONFIG_MSDOS_PARTITION; do
 grep -q "^$opt=y\$" "$kconfig" 2>/dev/null || skip "$opt not built into the kernel ($kconfig)"
done

partuuid=${PG_ROOT_PARTUUID:-$(blkid -s PARTUUID -o value "/dev/$root_dev" 2>/dev/null || true)}
echo "$partuuid" | grep -q -E '^[0-9a-f]{8}-[0-9a-f]{2}$' || skip "no PARTUUID for /dev/$root_dev (\"$partuuid\")"

mounted=""
if [ -n "${PG_BOOT_DIR:-}" ]; then
 boot=$PG_BOOT_DIR
else
 boot_dev=$(blkid -L BOOT_PG 2>/dev/null || true)
 case "$boot_dev" in
  "/dev/${root_dev%p[0-9]}p"[0-9]) ;;
  *) skip "boot partition \"$boot_dev\" is not on the root filesystem's card" ;;
 esac
 boot=$(mktemp -d /tmp/pgen-bootfat.XXXXXX)
 # Not mountable now (e.g. held read-only elsewhere): the update goes on
 # and the boot keeps its initramfs; failing would block every update.
 if ! mount -t vfat "$boot_dev" "$boot"; then
  rmdir "$boot" 2>/dev/null || true
  skip "could not mount $boot_dev"
 fi
 mounted=1
fi
cleanup() { if [ -n "$mounted" ]; then umount "$boot" 2>/dev/null || true; rmdir "$boot" 2>/dev/null || true; fi; }
trap cleanup EXIT

cmdline="$boot/cmdline.txt"
config="$boot/config.txt"
[ -s "$cmdline" ] || skip "no cmdline.txt on the boot partition"
[ -s "$config" ] || skip "no config.txt on the boot partition"
[ -s "$boot/kernel7l.img" ] || skip "no kernel7l.img on the boot partition"

# Writes NEW over FILE through FILE.pgen-tmp; a failed or empty write leaves
# FILE as it was and fails the migration (pgenerator-update reports it).
replace() {
 file=$1 new=$2
 if ! printf '%s' "$new" > "$file.pgen-tmp" || [ ! -s "$file.pgen-tmp" ]; then
  echo "ERROR: $(basename "$file") on the boot partition not rewritten" >&2
  rm -f -- "$file.pgen-tmp" 2>/dev/null || true
  exit 1
 fi
 mv -f -- "$file.pgen-tmp" "$file"
 sync
}

fail() { echo "ERROR: $*" >&2; exit 1; }
# The root= tokens of a cmdline, one per line. The kernel uses the last.
root_tokens() { printf '%s\n' "$1" | tr ' ' '\n' | grep '^root=' || true; }
# Lines in a text ("" counts 0; a missing last newline does not matter).
lines() { printf '%s' "$1" | sed -n '$='; }

changed=""
old_cmdline=$(cat "$cmdline") || fail "cmdline.txt not readable"
tokens=$(root_tokens "$old_cmdline")
[ -n "$tokens" ] || skip "cmdline.txt has no root= entry"
if [ "$tokens" != "root=PARTUUID=$partuuid" ]; then
 # One root= token, in the place of the first: with a second one left the
 # kernel would take that (e.g. a LABEL it cannot resolve without the
 # initramfs).
 new_cmdline=$(printf '%s\n' "$old_cmdline" | awk -v r="root=PARTUUID=$partuuid" \
  '{o="";for(i=1;i<=NF;i++){t=$i;if(t~/^root=/){if(d)continue;t=r;d=1};o=o (o==""?"":" ") t};print o}') \
  || fail "cmdline.txt not rewritten (awk)"
 [ "$(root_tokens "$new_cmdline")" = "root=PARTUUID=$partuuid" ] || fail "cmdline.txt not rewritten (root= reads back \"$(root_tokens "$new_cmdline" | tr '\n' ' ')\")"
 cp -p "$cmdline" "$boot/cmdline.txt.initramfs" || fail "cmdline.txt.initramfs not written"
 replace "$cmdline" "$new_cmdline
"
 changed=1
 echo "cmdline.txt: root=PARTUUID=$partuuid (was: $(printf '%s' "$tokens" | tr '\n' ' ' | sed 's/ $//'))"
fi

if grep -q -E '^[[:space:]]*initramfs[[:space:]]' "$config"; then
 new_config=$(sed -E 's/^([[:space:]]*initramfs[[:space:]])/#\1/' "$config") || fail "config.txt not rewritten (sed)"
 # Every line still there: only one line changes, by a leading "#".
 [ -n "$new_config" ] && [ "$(lines "$new_config")" = "$(lines "$(cat "$config")")" ] \
  || fail "config.txt not rewritten (new text has $(lines "$new_config") lines, the file $(lines "$(cat "$config")"))"
 cp -p "$config" "$boot/config.txt.initramfs" || fail "config.txt.initramfs not written"
 replace "$config" "$new_config
"
 changed=1
 echo "config.txt: initramfs line commented out"
fi

# Read back what the next boot will use.
[ "$(root_tokens "$(cat "$cmdline")")" = "root=PARTUUID=$partuuid" ] || fail "cmdline.txt does not read back one root=PARTUUID=$partuuid"
! grep -q -E '^[[:space:]]*initramfs[[:space:]]' "$config" || fail "config.txt still loads the initramfs"

# The WebUI's copy: a failure here would let its next config.txt write
# bring the initramfs line back, so it fails the migration (a retry of the
# update runs it again).
copy="$root/boot/loader/boot_dir"
if [ -d "$copy" ]; then
 for f in cmdline.txt config.txt; do
  if ! cmp -s "$boot/$f" "$copy/$f"; then
   if ! cp "$boot/$f" "$copy/$f.pgen-tmp" || ! mv -f "$copy/$f.pgen-tmp" "$copy/$f"; then
    rm -f -- "$copy/$f.pgen-tmp" 2>/dev/null || true
    fail "/boot/loader/boot_dir/$f not set to the boot partition's"
   fi
   echo "/boot/loader/boot_dir/$f set to the boot partition's"
  fi
 done
fi

[ -n "$changed" ] && echo "Boot without initramfs from the next reboot on"
exit 0
