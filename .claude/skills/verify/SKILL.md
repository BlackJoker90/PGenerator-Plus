---
name: verify
description: Verify PGenerator+ changes on the real Pi 4 at the HDMI output - build the renderer in the pgen-build VM, deploy safely, drive patterns over the Calman port and the WebUI API, and read back scanout pixels, CSC registers, the rgb quant range property and the AVI infoframe. Use after renderer, daemon, drm_override or vc4 changes.
---

# Verify PGenerator+ on the Pi

The surface is the HDMI signal of the Pi 4 at `192.168.1.235` (LG TV attached).
Evidence = what the Pi scans out and signals, not unit tests.

## Ground rules (from the user)

- Before any probe, restart or reboot: Calman must be idle.
  `scripts/pi_calman_busy.sh` on the Pi (FREE/BUSY), plus
  `netstat -tn | grep -E ':210[01] .*ESTAB'`. Calman VM 192.168.1.6 uses
  port 2101. BUSY or user session visible in `/var/log/PGenerator/calman-patches.log`
  (`peer=192.168.1.6`) -> stop and ask. Run the check as its own step, never
  chained in front of a probe. Your own probes (`peer=127.0.0.1` or the Mac)
  also count as activity for 15 min: if BUSY, look at the peers in the last
  lines of calman-patches.log before deciding.
- Reboot, push, release: only with the user's explicit OK.
- Never POST `{}` or dummy bodies. Partial `/api/config` bodies
  (`{"max_bpc":"10"}`) are fine; the handler only touches given keys.
- Back up before overwriting (`/root/pgen-backups/<file>.before-<change>`),
  guard copies with `[ -s new ]`, compare md5 afterwards.
- Restore the user's state at the end (back up `/etc/PGenerator/PGenerator.conf`
  first, compare after).
- TV tests use a dim window (20 IRE / 10 %), not full white.

## Handle

All Pi access needs `dangerouslyDisableSandbox: true` (LAN).
`PGPASS` = root password from README.md (Login section); never write it to a file.

```sh
V=.claude/skills/verify/scripts
PGPASS='...' $V/pi.exp ssh 'uptime'
PGPASS='...' $V/pi.exp scp $V/pgprobe.py $V/fbprobe $V/pi_calman_busy.sh /tmp/
```

`/tmp` on the Pi is cleared on reboot: re-copy the probes after one.

### Build the renderer (PGeneratord, PGeneratord.dv, drm_override.so)

```sh
prlctl exec pgen-build 'sh /media/psf/Home/PGenerator-Plus/tools/renderer-build/build-in-vm.sh > /root/build.log 2>&1; echo rc=$?; md5sum /srv/bionic/work/out/*'
prlctl exec pgen-build 'cp /srv/bionic/work/out/* /media/psf/Home/PGenerator-Plus/build/renderer-out/'
```

`grep error` on the log matches `-Werror`; trust `rc` and new md5s.
`tools/renderer-build/verify.sh` wants SSH key auth to the Pi and fails at that
step; the VM-side checks (qemu smoke test: "Only on Distro BiasiLinux ..."
means every lib and symbol resolved) can be run on their own.
`prlctl exec` output with non-ASCII characters fails with
"PrlJob_GetResult: Invalid argument": pipe through `tr -cd '[:print:]\n'`.

### Deploy

The running renderer cannot be overwritten ("Text file busy"). Stop first, and
never put "PGenerator" in your own command line: `/etc/init.d/PGenerator stop`
runs `pkill -f /usr/sbin/PGeneratord...` and kills a wrapper shell that mentions it.

```sh
pi.exp ssh '/etc/init.d/PGenerator stop'           # session may drop; that is fine
pi.exp ssh '[ -s /tmp/new ] && cp /tmp/new /usr/sbin/PGeneratord && cp /tmp/new /usr/sbin/PGeneratord.dv && sync && md5sum /usr/sbin/PGeneratord*'
pi.exp ssh 'setsid /etc/init.d/PGenerator start </dev/null >/tmp/pgen-restart.log 2>&1 &'
```

"Killed ... setsid sudo" in the start log is the sudo wrapper; check that
`PGeneratord.pl` listens on 80/2100/2101.

## Drive and read back

Run `pgprobe.py` on the Pi with all commands of one scenario in ONE call
(explicit bpc and the Calman range are per connection; closing hands the range
back to the WebUI and restarts the renderer):

```sh
pi.exp ssh 'python3 /tmp/pgprobe.py "CONF_LEVEL:Bits 10" "RGB_S:0513,0513,0513,010" "post:{\"max_bpc\":\"8\"}" "RGB_S:0068,0068,0068,010"'
```

State line per pattern:
`prop=` connector rgb quant range (0 Default, 1 Limited, 2 Full, 3 Limited
without CSC = patched vc4), `DEEP_COLOR_CONFIG_1` 0x204 = 8 bpc / 0x205 = 10 bpc,
`CSC_12_11` 0x2000 = unity / 0x1b80 = 16-235 compression, `CSC_CTL` 0x7f = 4:2:2,
`AVI=` PB0..PB4 (PB1 0x12 RGB / 0x52 YCbCr444 / 0x32 YCbCr422, PB3 0x04 Limited
/ 0x08 Full, PB4 = VIC, 0x10 = 1080p60), then the scanout pixel
(`AR24` 8 bit, `AB30` 10 bit; in YCbCr444 R=Cb G=Cr B=Y) and conf keys.

The scanout is the wire whenever CSC is unity (YCbCr, RGB Full, RGB Limited with
prop 3). With prop 1 or 0 the kernel compresses after the framebuffer, so the
scanout does not prove wire codes.

Sweeps: build the code list in the Pi shell and evaluate on the Mac:

```sh
pi.exp ssh 'L=""; for v in $(seq 0 255); do c=$(printf %04d $((v*4))); L="$L RGB_S:$c,$c,$c,010"; done; python3 /tmp/pgprobe.py $L' > $TMPDIR/sweep8.txt
python3 .claude/skills/verify/scripts/evalsweep.py $TMPDIR/sweep8.txt 8
```

About 3 s per code (256 codes = ~13 min): run long sweeps with
`run_in_background`. The first line after a renderer restart can show the
previous frame (e.g. 30 for code 0064): re-probe it before calling it a bug.

## Flows worth driving

- RGB Limited 8 and 10 bpc: prop 3, unity CSC, AVI `12:a8:04:10`, codes = code>>2 (8 bpc) / exact (10 bpc), incl. codes off the 8-bit grid.
- RGB Full (`CONF_LEVEL:Range Full`): prop 2, AVI PB3 0x08.
- YCbCr (`CONF_LEVEL:Format YCC444_10`, `YCC422_10`): prop never 3, CSC unchanged.
- Dolby Vision LLDV (`post:{"signal_mode":"dv","dv_transport":"lldv"}`, back with `{"signal_mode":"sdr"}`): prop 1.
- Range change from WebUI (`post:{"rgb_quant_range":"2"}` then `"1"`): the renderer rejects the in-place reload (`grep rejected /tmp/pgenerator_debug.log`) and restarts; a new `AVI IF` line must follow. vc4 only reprograms CSC/infoframe on a modeset.
- Calman `CONF_FORMAT:1920x1080p 60` / `59.94`: EDID modes 21 / 22, never the userdef boot mode (VIC 0).
- WebUI bit depth during an open Calman session: 10-bit codes stay exact.
- Probes: `rgb_quant_range` 3 and 0 via WebUI, two range POSTs back to back, renderer restart (prop goes to 0 while it is down).

## Where to look

- Daemon: `/tmp/pgenerator_debug.log`; patterns: `/var/log/PGenerator/calman-patches.log` (`range=LIMITED`, `bg=`); updater: `/var/log/PGenerator/update.log`; renderer stderr: `/tmp/pg_stderr.log`; drm_override: `/tmp/drm_override.log`.
- vc4 module: `/sys/module/vc4/srcversion` is `24E978B6C622711RQ3V1SPD` when the patched module is loaded (RQ3 range patch + no SPD infoframe; the renderer looks for `RQ3V1`). SPD must never be on the wire: bit 3 of `HDMI_RAM_PACKET_CONFIG` stays 0.
- WebUI range text: `/var/lib/PGenerator/running/info/GET_OUTPUT_RANGE.info`.

`scripts/fbprobe` is prebuilt (armhf, libdrm). Source `scripts/fbprobe.c`; rebuild
in the pgen-build bionic sysroot like drm_override (`arm-linux-gnueabihf-gcc-7
--sysroot=/work/sysroot -march=armv6 -mfpu=vfp -mfloat-abi=hard -marm -O2
-I/work/sysroot/usr/include/libdrm ... -ldrm`).
