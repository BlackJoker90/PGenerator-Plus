#!/usr/bin/env python3
# Compare pgprobe.py output of grey RGB_S sweeps with the expected scanout code.
#   evalsweep.py OUTPUT.txt BITS [ycc]   (BITS = link bpc, 8 or 10)
# Expected in RGB Limited passthrough / RGB Full: R=G=B=code at 10 bpc; at
# 8 bpc the daemon rounds to the nearest code, (code+2)>>2, top code 255
# (daemon.pm calman_scale_value). With "ycc" (YCbCr 4:4:4: R=Cb G=Cr B=Y)
# only B=Y is compared.
import re, sys

bits = int(sys.argv[2]) if len(sys.argv) > 2 else 8
ycc = len(sys.argv) > 3 and sys.argv[3] == "ycc"


def expected(code):
    if bits >= 10:
        return code
    shift = 10 - bits
    if code >= 1023:
        return (1 << bits) - 1
    return min((code + (1 << (shift - 1))) >> shift, (1 << bits) - 1)


ok, bad = 0, []
for line in open(sys.argv[1]):
    m = re.search(r"\[(\d{4}),\d{4},\d{4},\d+\].*?R=(\d+) G=(\d+) B=(\d+)", line)
    if not m:
        continue
    code = int(m.group(1))
    exp = expected(code)
    got = tuple(int(x) for x in m.groups()[1:])
    if (got[2] == exp) if ycc else (got == (exp,) * 3):
        ok += 1
    else:
        bad.append((code, exp, got))
print("exact %d, off %d" % (ok, len(bad)))
for b in bad[:20]:
    print("  code %04d expected %d got %s" % b)
sys.exit(1 if bad else 0)
