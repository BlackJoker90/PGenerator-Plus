#!/usr/bin/env python3
# Runs ON THE PI (python3.5: no f-strings, no capture_output/text=).
# Drives the Calman UPGCI port in ONE connection and prints the signal state
# after each pattern: connector "rgb quant range", link bpc, CSC, AVI
# infoframe, scanout pixel (fbprobe) and the relevant conf keys.
#
#   python3 /tmp/pgprobe.py CMD [CMD ...]
#     CMD = any UPGCI command, e.g. "CONF_LEVEL:Bits 10", "CONF_FORMAT:1920x1080p 60",
#           "RGB_S:0512,0512,0512,010" (10-bit codes, window 10 %)
#           "post:{json}"  WebUI POST /api/config with that partial body
#           "sleep:N"      wait N seconds
#   Every RGB_S/RGB_A/RGB_B is followed by a state line.
#
# Keep the connection open: explicit bpc and the Calman range are per session,
# and closing it hands the range back to the WebUI setting (renderer restart).
import socket, subprocess, sys, time

def sh(c):
    return subprocess.Popen(c, shell=True, stdout=subprocess.PIPE, universal_newlines=True).communicate()[0]

def state(tag):
    prop = sh("modetest -M vc4 -c 2>/dev/null | awk '/rgb quant range/{p=1} p&&/value/{print $2; exit}'").strip()
    regs = sh("grep -E 'DEEP_COLOR_CONFIG_1|CSC_12_11 |CSC_CTL ' /sys/kernel/debug/dri/1/hdmi0_regs | tr -s ' ' | sed 's/HDMI_//g' | tr '\\n' ' '")
    avi = sh("dmesg | grep 'AVI IF' | tail -1 | sed 's/.*AVI IF: //' | cut -c1-26").strip()
    fb = sh("/tmp/fbprobe 2>&1 | sed -n '1s/.*format \\([A-Z0-9]*\\).*/\\1/p;2p' | tr '\\n' ' '").strip()
    conf = sh("grep -E '^(mode_idx|max_bpc|rgb_quant_range|color_format|signal_mode)=' /etc/PGenerator/PGenerator.conf | tr '\\n' ' '")
    print("  [%s] prop=%s %s AVI=%s | %s | %s" % (tag, prop, regs, avi, fb, conf))
    sys.stdout.flush()

s = socket.create_connection(("127.0.0.1", 2100), timeout=30)
for c in sys.argv[1:]:
    if c.startswith("sleep:"):
        time.sleep(float(c[6:])); continue
    if c.startswith("post:"):
        out = sh("curl -s -m 30 -X POST -H 'Content-Type: application/json' -d '%s' http://127.0.0.1/api/config" % c[5:])
        print("POST %s -> %s" % (c[5:], out.strip()[:100])); time.sleep(15); continue
    t = time.time()
    s.sendall(b"\x02" + c.encode() + b"\x03")
    r = s.recv(4096)
    print("%s %s (%.1fs)" % (c, "ACK" if r[:1] == b"\x06" else "NAK %r" % r[:30], time.time() - t))
    sys.stdout.flush()
    if c.split(":")[0] in ("RGB_S", "RGB_A", "RGB_B"):
        time.sleep(3)
        state(c.split(":", 1)[1])
    elif c.startswith("CONF_"):
        time.sleep(10)  # format/bit-depth changes restart the renderer
s.sendall(b"\x02TERM\x03")
s.close()
