---
name: verify
description: Verify PGenerator+ changes on the real Pi 4 at the HDMI output - build the renderer in the pgen-build VM, deploy safely, drive patterns over the Calman port and the WebUI API, and read back scanout pixels, CSC registers, the rgb quant range property and the AVI infoframe. Use after renderer, daemon, drm_override or vc4 changes.
---

# Verify PGenerator+ on the Pi

The surface is the HDMI signal of the Pi 4 at `192.168.1.235` (LG TV attached).
Evidence = what the Pi scans out and signals, not unit tests.
This proves the signal only. The local robustness pass (invalid input,
failing safeguards, repro against the old code; CLAUDE.md "Verify after a
change") is separate and still needed.

## Ground rules (from the user)

All Pi access goes through the `pi` skill: `P=.claude/skills/pi/scripts/pgen-pi`
(busy check, ssh/scp, snapshot/restore, deploy, restart, reboot; the guard
hook refuses raw ssh). Read `.claude/skills/pi/SKILL.md` first.

- Before any probe, restart or reboot: `$P busy` as its own step (FREE counts
  10 min for the hook). BUSY: read the reason lines; a real session (Calman
  VM 192.168.1.6 on 2101, classic on 2100, ColourSpace/PiTPG on 85) -> stop
  and ask. Our own probes (127.0.0.1, the Mac) do not count.
- Reboot, push, release: only with the user's explicit OK (the hook asks).
- Never POST `{}` or dummy bodies. Partial `/api/config` bodies
  (`{"max_bpc":"10"}`) are fine; the handler only touches given keys.
- `$P snapshot` before the first change, `$P restore` at the end.
- TV tests use a dim window (20 IRE / 10 %), not full white.

## Handle

```sh
P=.claude/skills/pi/scripts/pgen-pi
$P status
$P probes        # pgprobe.py, fbprobe, pitpgprobe.py -> /tmp (cleared on reboot)
```

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

```sh
$P deploy usr/sbin/PGeneratord usr/sbin/PGeneratord.dv usr/share/PGenerator/daemon.pm
```

It stops the daemon before installing (a running renderer is "Text file
busy"), backs up, checks md5, restarts and waits for ports 80/85/2100/2101.
By hand: the init script's stop runs `pkill -f` on `/usr/sbin/PGeneratord`,
`PGeneratord.pl`, `PGenerator_cmd.pl`, `PGenerator_serial.pl`; a command line
that names one of them is killed with it (the hook refuses that).
"Killed ... setsid sudo" in the start log is the sudo wrapper.

## Drive and read back

Run `pgprobe.py` on the Pi with all commands of one scenario in ONE call
(explicit bpc and the Calman range are per connection; closing hands the range
back to the WebUI and restarts the renderer):

```sh
$P ssh 'python3 /tmp/pgprobe.py "CONF_LEVEL:Bits 10" "RGB_S:0513,0513,0513,010" "post:{\"max_bpc\":\"8\"}" "RGB_S:0068,0068,0068,010"'
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
$P ssh 'L=""; for v in $(seq 0 255); do c=$(printf %04d $((v*4))); L="$L RGB_S:$c,$c,$c,010"; done; python3 /tmp/pgprobe.py $L' > $TMPDIR/sweep8.txt
python3 .claude/skills/verify/scripts/evalsweep.py $TMPDIR/sweep8.txt 8      # add "ycc" for YCbCr 4:4:4 (B=Y)
```

About 3 s per code (256 codes = ~13 min): run long sweeps with
`run_in_background`. One ssh call gives up after 600 s without output
(pi.exp idle timeout, `PI_TIMEOUT=` to change); pgprobe prints a line per code. The first line after a renderer restart can show the
previous frame (e.g. 30 for code 0064): re-probe it before calling it a bug.

## Flows worth driving

- RGB Limited 8 and 10 bpc: prop 3, unity CSC, AVI `12:a8:04:10`, codes = (code+2)>>2 capped at 255 (8 bpc: the daemon rounds to the nearest code, daemon.pm calman_scale_value) / exact (10 bpc), incl. codes off the 8-bit grid.
- RGB Full (`CONF_LEVEL:Range Full`): prop 2, AVI PB3 0x08.
- YCbCr (`CONF_LEVEL:Format YCC444_10`, `YCC422_10`): prop 3 (since 2.13.23; 1 made vc4 signal Q/YQ Full on modes without a CEA VIC), CSC unchanged (the YCbCr CSC ignores the range), AVI PB3 0x04 and PB5 YQ 0x00 also on mode 20 (VIC 0). `CONF_LEVEL:Range Full` on YCbCr stays prop 3 / Limited; full-range codes come as SOURCE_RANGE=FULL and are compressed (10 bit 0/205 -> 64/240). LLDV keeps prop 1.
- Dolby Vision LLDV (`post:{"signal_mode":"dv","dv_transport":"lldv"}`, back with `{"signal_mode":"sdr"}`): prop 1.
- Range change from WebUI (`post:{"rgb_quant_range":"2"}` then `"1"`): the renderer rejects the in-place reload (`grep rejected /tmp/pgenerator_debug.log`) and restarts; a new `AVI IF` line must follow. vc4 only reprograms CSC/infoframe on a modeset.
- Calman `CONF_FORMAT:1920x1080p 60` / `59.94`: EDID modes 21 / 22, never the userdef boot mode (VIC 0).
- WebUI bit depth during an open Calman session: 10-bit codes stay exact.
- Probes: `rgb_quant_range` 3 and 0 via WebUI, two range POSTs back to back, renderer restart (prop goes to 0 while it is down).

## Failure paths worth driving

The device side of the robustness pass; each must leave the renderer
running and the conf unchanged (md5 of `/etc/PGenerator/PGenerator.conf`
before and after).

- Malformed pattern line (`BG=broken,0,0`, `RGB=1,2`, a line without `=`)
  written straight into `/var/lib/PGenerator/running/operations.txt`, then
  `touch running/return` (the renderer reloads and removes it): the renderer
  keeps its pid and the scanout shows the valid lines drawn (window code
  changed, BG/RGB kept at the previous value). Its `pattern line ... ignored`
  message is not in `/tmp/pg_stderr.log` (the spawn log stayed empty in
  2.13.24 tests), so prove it by pid and scanout. The 2.13.23 renderer died
  on `BG=broken,0,0` and was not restarted until the next pattern request.
  Through the daemon the same BG is refused before it reaches the file.
- `POST /api/config` with a truncated body and matching Content-Length:
  `400`, conf unchanged.
- Signal Self-Test while the packet RAM cannot be read: the DV check says
  "Not verified" and the mode is not counted as passed.

## Where to look

- Daemon: `/tmp/pgenerator_debug.log`; patterns: `/var/log/PGenerator/calman-patches.log` (`range=LIMITED`, `bg=`); updater: `/var/log/PGenerator/update.log`; renderer stderr: `/tmp/pg_stderr.log`; drm_override: `/tmp/drm_override.log`.
- vc4 module: `/sys/module/vc4/srcversion` contains `RQ3V1` when a patched module is loaded; the renderer (ofxRPI4Window.cpp) and the WebUI (webui.pm rgbLimitedPassthroughSupported) test only for that. Known builds: `24E978B6C622711RQ3V1SPD` (RQ3 range patch + no SPD infoframe), `24E978B6C622RQ3V1SPDVIC` (+ D8: the real VIC in the Standard DV AVI, `vc4-rq3-nospd-dvvic.ko`). `$P status` prints it. SPD must never be on the wire: bit 3 of `HDMI_RAM_PACKET_CONFIG` stays 0.
- WebUI range text: `/var/lib/PGenerator/running/info/GET_OUTPUT_RANGE.info`.

`scripts/fbprobe` is prebuilt (armhf, libdrm). Source `scripts/fbprobe.c`; rebuild
in the pgen-build bionic sysroot like drm_override (`arm-linux-gnueabihf-gcc-7
--sysroot=/work/sysroot -march=armv6 -mfpu=vfp -mfloat-abi=hard -marm -O2
-I/work/sysroot/usr/include/libdrm ... -ldrm`).
