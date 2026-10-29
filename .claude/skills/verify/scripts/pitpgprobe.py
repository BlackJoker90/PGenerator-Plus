#!/usr/bin/env python3
# Runs ON THE PI (python3.5: no f-strings). Drives port 85 as a PiTPG
# protocol 2 client (ColourSpace's "PiTPG" entry) in ONE connection and
# prints each reply, its time, and after patches and test patterns the
# signal state (as pgprobe.py) plus scanout pixels.
#
#   python3 /tmp/pitpgprobe.py ARG [ARG ...]
#     ARG = a JSON request without "id", e.g. '{"op":"hello","protocol":2}'
#           "fb:x,y[;x,y...]"  scanout pixels (fbprobe) at these points
#           "sleep:N"          wait N seconds
#           "raw:HEX"          send these bytes as they are (robustness)
#   The id is added (1, 2, ...). A reply longer than 300 chars is cut.
import json, socket, struct, subprocess, sys, time

def sh(c):
    return subprocess.Popen(c, shell=True, stdout=subprocess.PIPE, universal_newlines=True).communicate()[0]

def state(tag):
    prop = sh("modetest -M vc4 -c 2>/dev/null | awk '/rgb quant range/{p=1} p&&/value/{print $2; exit}'").strip()
    regs = sh("grep -E 'DEEP_COLOR_CONFIG_1|CSC_12_11 |CSC_CTL ' /sys/kernel/debug/dri/1/hdmi0_regs | tr -s ' ' | sed 's/HDMI_//g' | tr '\\n' ' '")
    avi = sh("dmesg | grep 'AVI IF' | tail -1 | sed 's/.*AVI IF: //' | cut -c1-26").strip()
    fb = sh("/tmp/fbprobe 2>&1 | sed -n '1s/.*format \\([A-Z0-9]*\\).*/\\1/p;2p' | tr '\\n' ' '").strip()
    conf = sh("grep -E '^(mode_idx|max_bpc|rgb_quant_range|color_format|is_hdr|eotf)=' /etc/PGenerator/PGenerator.conf | tr '\\n' ' '")
    print("  [%s] prop=%s %s AVI=%s | %s | %s" % (tag, prop, regs, avi, fb, conf))
    sys.stdout.flush()

def pixels(spec):
    for p in spec.split(";"):
        x, y = p.split(",")
        out = sh("/tmp/fbprobe %s %s 2>&1 | sed -n 2p" % (x, y)).strip()
        print("  fb(%s,%s) %s" % (x, y, out))
    sys.stdout.flush()

def recv_reply(s):
    buf = b""
    while len(buf) < 4:
        d = s.recv(65536)
        if not d:
            return None
        buf += d
    n = struct.unpack(">I", buf[:4])[0]
    while len(buf) < 4 + n:
        d = s.recv(65536)
        if not d:
            return None
        buf += d
    return buf[4:4 + n].decode("utf-8", "replace")

s = socket.create_connection(("127.0.0.1", 85), timeout=30)
s.sendall(b"PTG2")
rid = 0
for a in sys.argv[1:]:
    if a.startswith("sleep:"):
        time.sleep(float(a[6:])); continue
    if a.startswith("fb:"):
        pixels(a[3:]); continue
    if a.startswith("raw:"):
        s.sendall(bytes.fromhex(a[4:]))
        try:
            r = s.recv(65536)
            print("raw %s -> %r" % (a[4:24], r[:80]))
        except Exception as e:
            print("raw %s -> %s" % (a[4:24], e))
        continue
    rid += 1
    req = json.loads(a)
    req["id"] = rid
    t = time.time()
    s.sendall(struct.pack(">I", len(json.dumps(req))) + json.dumps(req).encode())
    r = recv_reply(s)
    dt = time.time() - t
    if r is None:
        print("%s -> connection closed (%.2fs)" % (a[:80], dt)); break
    print("%s -> %s (%.2fs)" % (a[:80], r if len(r) <= 300 else r[:300] + "...", dt))
    sys.stdout.flush()
    if req.get("op") in ("patch", "test_pattern"):
        time.sleep(1)
        state(req.get("op"))
s.close()
