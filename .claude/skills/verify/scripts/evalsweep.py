#!/usr/bin/env python3
# Compare pgprobe.py output of grey RGB_S sweeps with the expected scanout code.
#   evalsweep.py OUTPUT.txt BITS      (BITS = link bpc, 8 or 10)
# Expected in RGB Limited passthrough / RGB Full / YCbCr Y: code >> (10 - BITS).
import re, sys

bits = int(sys.argv[2]) if len(sys.argv) > 2 else 8
ok, bad = 0, []
for line in open(sys.argv[1]):
    m = re.search(r"\[(\d{4}),\d{4},\d{4},\d+\].*?R=(\d+) G=(\d+) B=(\d+)", line)
    if not m:
        continue
    code = int(m.group(1))
    exp = code >> (10 - bits)
    got = tuple(int(x) for x in m.groups()[1:])
    if got == (exp,) * 3:
        ok += 1
    else:
        bad.append((code, exp, got))
print("exact %d, off %d" % (ok, len(bad)))
for b in bad[:20]:
    print("  code %04d expected %d got %s" % b)
sys.exit(1 if bad else 0)
