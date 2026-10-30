#!/usr/bin/env python3
# Runs ON THE PI as root (python3.5: no f-strings). Saves the user's state
# before a test and gives it back afterwards, the way pi_hdmi_run.py does it
# (tools/, give_back): the signal through partial /api/config bodies as the
# WebUI sends them, then the side keys, then the DV keys, then the pattern.
#   python3 pi_state.py save LABEL      conf + pattern to /root/pgen-backups/state-LABEL/
#   python3 pi_state.py diff LABEL      what the conf holds now that the saved one did not
#   python3 pi_state.py restore LABEL   give it back; exit 0 only when the conf is
#                                       the saved one again (every key) and the
#                                       renderer came up
#   python3 pi_state.py show            the signal keys now
# Exit 1: error or not back (the reasons are printed), 2: usage, 3: the
# signal keys are back but other keys differ (printed; none of them is
# written: they are not the signal, and the user decides about them).
# PGEN_CONF, PGEN_API, PGEN_STATE_DIR, PGEN_OPS override the paths (tests).
import json, os, re, shutil, signal, sys, time, urllib.request

CONF = os.environ.get("PGEN_CONF", "/etc/PGenerator/PGenerator.conf")
API = os.environ.get("PGEN_API", "http://127.0.0.1")
STATE_DIR = os.environ.get("PGEN_STATE_DIR", "/root/pgen-backups")
OPS = os.environ.get("PGEN_OPS", "/var/lib/PGenerator/running/operations.txt")
RET = os.path.join(os.path.dirname(OPS), "return")
TEST_LOCK = "/tmp/pgen-signal-test.lock"
DEPLOY_LOCK = "/tmp/pgen-deploy.lock"
SELFTEST_STATE = "/tmp/pgen-selftest.json"
DV_AB_STATE = "/root/dv_vsif_ab.state.json"
# As pi_hdmi_run.py: the signal keys, the pre-DV values the WebUI stores on
# entering DV and the SDR colorimetry it stores on leaving SDR, and the keys
# written on entering DV and read only in DV (command.pm: dv_interface only
# with dv_status=1).
KEYS = ("color_format", "max_bpc", "rgb_quant_range", "colorimetry", "dv_transport", "dv_map_mode")
SIDE_KEYS = ("pre_dv_rgb_quant_range", "pre_dv_max_bpc", "pre_dv_color_format", "sdr_colorimetry")
DV_KEYS = ("dv_profile", "dv_color_space", "dv_interface")
# The rest of the signal (webui.pm @WEBUI_PRESET_KEYS): the mode and the
# HDR metadata of the DRM infoframe. Given back after the signal POST (a
# signal_mode sets primaries itself, webui_apply_config), only when they
# differ. eotf follows the mode and is compared, not posted.
META_KEYS = ("mode_idx", "mode_label", "primaries", "max_luma", "min_luma", "max_cll", "max_fall")
LABEL_RX = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


def out(s):
    # Never raises: the Mac side going away (ssh cut, Bash timeout) must not
    # stop a restore half-way (SIGPIPE and SIGHUP are ignored in main).
    try:
        sys.stdout.write(s + "\n")
        sys.stdout.flush()
    except (OSError, ValueError):
        pass


def read_conf(path=CONF):
    c = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if "=" in line:
                k, v = line.rstrip("\r\n").split("=", 1)
                c[k] = v
    return c


def perl_int(v):
    """Perl's int() of a conf value, as in pi_hdmi_run.py."""
    m = re.match(r"[ \t\n\r\f\x0b]*([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?|[+-]?(?:inf|nan))", v or "", re.I)
    if not m:
        return 0
    try:
        return int(float(m.group(1)))
    except (OverflowError, ValueError):
        return 1


def mode(c):
    """The signal mode from the flags, as command.pm signal_mode_from_conf."""
    if perl_int(c.get("dv_status")) or perl_int(c.get("is_ll_dovi")) or perl_int(c.get("is_std_dovi")):
        return "dv"
    if perl_int(c.get("is_hdr")):
        return "hlg" if perl_int(c.get("eotf")) == 3 else "hdr10"
    return "sdr"


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def pid_alive(pid):
    try:
        pid = int(pid)
        if pid <= 0:
            return False
        os.kill(pid, 0)
    except (TypeError, ValueError, ProcessLookupError):
        return False
    except PermissionError:
        pass
    return True


def others_busy():
    """Why a signal test, a deploy or the WebUI self-test is under way, or "".
    A restore under any of them would fight it for the signal."""
    if os.path.isdir(TEST_LOCK) and pid_alive(read_text(TEST_LOCK + "/pid")):
        return "a signal test holds %s" % TEST_LOCK
    if os.path.isdir(DEPLOY_LOCK):
        return "a deploy holds %s" % DEPLOY_LOCK
    st = read_text(SELFTEST_STATE)
    if re.search(r'"state"\s*:\s*"running"', st):
        m = re.search(r'"pid"\s*:\s*(\d+)', st)
        try:
            age = time.time() - os.stat(SELFTEST_STATE).st_mtime
        except OSError:
            age = 0
        # Without a pid yet: written in the last 5 s (as webui.pm judges it).
        if (m and pid_alive(m.group(1))) or (not m and age < 5):
            return "the WebUI signal self-test is running"
    if os.path.exists(DV_AB_STATE):
        return "dv_vsif_ab.pl is not restored yet (%s)" % DV_AB_STATE
    return ""


def state_dir(label):
    if not LABEL_RX.match(label or ""):
        out("STOP: label must be 1-64 of A-Z a-z 0-9 . _ - (got %r)" % label)
        sys.exit(2)
    return os.path.join(STATE_DIR, "state-" + label)


def copy_checked(src, dst):
    shutil.copy2(src, dst)
    with open(src, "rb") as a, open(dst, "rb") as b:
        if a.read() != b.read():
            raise OSError("copy of %s differs" % src)


def save(label):
    d = state_dir(label)
    if os.path.exists(d):
        out("STOP: %s exists already (a snapshot with that label); pick another label" % d)
        return 1
    os.makedirs(d)
    copy_checked(CONF, os.path.join(d, "PGenerator.conf"))
    if os.path.isfile(OPS):
        copy_checked(OPS, os.path.join(d, "operations.txt"))
    c = read_conf(os.path.join(d, "PGenerator.conf"))
    meta = {"label": label, "time": int(time.time()), "mode": mode(c),
            "pattern": os.path.isfile(os.path.join(d, "operations.txt"))}
    with open(os.path.join(d, "meta.json"), "w") as f:
        json.dump(meta, f)
    if not os.path.getsize(os.path.join(d, "meta.json")):
        raise OSError("meta.json empty")
    out("saved %s: mode=%s %s" % (d, meta["mode"], " ".join("%s=%s" % (k, c.get(k, "-")) for k in KEYS)))
    return 0


def load(label):
    d = state_dir(label)
    path = os.path.join(d, "PGenerator.conf")
    if not os.path.isfile(path):
        out("STOP: no snapshot %s" % d)
        sys.exit(1)
    return d, read_conf(path)


def differences(now, user):
    """[(key, now, was)] over every key of both confs, mode first."""
    d = []
    if mode(now) != mode(user):
        d.append(("mode", mode(now), mode(user)))
    for k in sorted(set(now) | set(user)):
        if now.get(k) != user.get(k):
            d.append((k, now.get(k, "(none)"), user.get(k, "(none)")))
    return d


def diff(label):
    _, user = load(label)
    d = differences(read_conf(), user)
    for x in d:
        out("  %s=%s (was %s)" % x)
    out("same as %s" % label if not d else "%d differ" % len(d))
    return 0 if not d else 1


class Refused(RuntimeError):
    """The daemon turned the POST down (a calibration client holds the
    signal): nothing changed."""


renderer_up = [True]


def post_config(body):
    """POST body, follow the renderer restart (as pi_hdmi_run.py)."""
    req = urllib.request.Request(API + "/api/config", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    r = json.loads(urllib.request.urlopen(req, timeout=40).read().decode())
    if r.get("status") != "ok":
        raise (Refused if r.get("refused") else RuntimeError)("POST %s: %s" % (json.dumps(body, sort_keys=True), r))
    if r.get("restart"):
        renderer_up[0] = False
        rid = r.get("restart_id", "")
        t = time.monotonic()
        while time.monotonic() - t < 60:
            s = json.loads(urllib.request.urlopen(API + "/api/restart/status?id=" + rid, timeout=10).read().decode())
            if s.get("state") == "ready":
                renderer_up[0] = True
                break
            if s.get("state") == "error":
                raise RuntimeError("renderer restart after %s: %s" % (json.dumps(body, sort_keys=True), s.get("message", "")))
            time.sleep(0.5)
        else:
            raise RuntimeError("renderer not ready 60 s after %s" % json.dumps(body, sort_keys=True))
    time.sleep(float(os.environ.get("PGEN_SETTLE", "2")))
    out("  set %s" % json.dumps(body, sort_keys=True))


def api_up(limit):
    t = time.monotonic()
    while True:
        try:
            urllib.request.urlopen(API + "/api/ping", timeout=5).read()
            return True
        except Exception:
            if time.monotonic() - t > limit:
                return False
            time.sleep(2)


def put_file(path, data, owner):
    tmp = "%s.pgstate.%d" % (path, os.getpid())
    try:
        with open(tmp, "wb") as f:
            f.write(data)
        os.chown(tmp, owner[0], owner[1])
        os.rename(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def take_lock():
    """The signal-test lock for the restore (pi_deploy.sh and the signal
    tests stop while it is there); "" or why it could not be taken."""
    try:
        os.mkdir(TEST_LOCK)
    except FileExistsError:
        p = read_text(TEST_LOCK + "/pid")
        if pid_alive(p):
            return "a signal test holds %s (pid %s)" % (TEST_LOCK, p)
        return "%s is there but its run (pid %s) is not; if none runs: rm -rf %s" % (TEST_LOCK, p or "unknown", TEST_LOCK)
    except OSError as e:
        return "cannot create %s: %s" % (TEST_LOCK, e)
    with open(TEST_LOCK + "/pid", "w") as f:
        f.write("%d\n" % os.getpid())
    return ""


def drop_lock():
    for path, f in ((TEST_LOCK + "/pid", os.unlink), (TEST_LOCK, os.rmdir)):
        try:
            f(path)
        except OSError:
            pass


def restore(label):
    d, user = load(label)
    busy = others_busy()
    if busy:
        out("STOP: %s; nothing changed" % busy)
        return 1
    busy = take_lock()
    if busy:
        out("STOP: %s; nothing changed" % busy)
        return 1
    try:
        return give_back(d, user, label)
    finally:
        drop_lock()


def give_back(d, user, label):
    unread = []

    def conf_now():
        try:
            return read_conf()
        except OSError as e:
            unread.append(str(e))
            return None
    # 1. The signal ("" deletes a key the user did not have). Leaving DV
    #    derives format and depth from pre_dv_*, so 4:2:2 or 12 bit need a
    #    second POST, and one refused POST a third. Into DV the DV keys go
    #    with it (they are read at the renderer start).
    target = {"signal_mode": mode(user)}
    target.update((k, user.get(k, "")) for k in KEYS)
    if target["signal_mode"] == "dv":
        target.update((k, user[k]) for k in DV_KEYS if user.get(k, "") != "")
    ok_signal, last_err = False, None
    for i in range(3):
        if i and last_err is not None:
            api_up(60)
        try:
            post_config(target)
            last_err = None
        except Exception as e:
            last_err = e
        now = conf_now()
        if now is not None and mode(now) == target["signal_mode"] and all(
                now.get(k, "") == v for k, v in target.items() if k != "signal_mode"):
            ok_signal = True
            if isinstance(last_err, Refused):
                out("NOTE: %s; the conf holds the settings already" % last_err)
            break
        if last_err is not None:
            out("WARNING: signal not given back: %s" % last_err)
    why = []
    # 2. The mode and the HDR metadata, where they differ (after the signal:
    #    its signal_mode sets primaries).
    now = conf_now()
    meta = dict((k, user[k]) for k in META_KEYS if user.get(k, "") != "" and (now or {}).get(k) != user[k])
    if ok_signal and meta:
        try:
            post_config(meta)
        except Exception as e:
            why.append("%s: %s" % (", ".join(sorted(meta)), e))
    # 3. pre_dv_* and sdr_colorimetry: no signal keys, their POST goes
    #    through while a calibration client holds the signal. Still in DV
    #    after a failed restore: pre_dv_* become the user's settings (as
    #    pi_hdmi_run.py and the WebUI on entering DV), so leaving DV in the
    #    WebUI lands on them.
    side = dict((k, user.get(k, "")) for k in SIDE_KEYS)
    now = None if ok_signal else conf_now()
    if not ok_signal and (now is None or mode(now) == "dv"):
        side.update(pre_dv_rgb_quant_range=user.get("rgb_quant_range") or "2",
                    pre_dv_max_bpc=user.get("max_bpc") or "8", pre_dv_color_format=user.get("color_format") or "0")
    try:
        post_config(side)
    except Exception as e:
        why.append("%s: %s" % (", ".join(SIDE_KEYS), e))
    # 4. The DV keys outside DV: inert there, given back on their own.
    dv = dict((k, user[k]) for k in DV_KEYS if user.get(k, "") != "")
    now = conf_now() if dv else None
    if now is not None and mode(now) != "dv":
        try:
            post_config(dv)
        except Exception as e:
            why.append("%s: %s" % (", ".join(sorted(dv)), e))
    # 5. The pattern (a renderer restart empties the running directory).
    ops = os.path.join(d, "operations.txt")
    if os.path.isfile(ops):
        try:
            st = os.stat(os.path.dirname(OPS))
            with open(ops, "rb") as f:
                data = f.read()
            put_file(OPS, data, (st.st_uid, st.st_gid))
            put_file(RET, b"", (st.st_uid, st.st_gid))
        except Exception as e:
            why.append("pattern not put back: %s" % e)
    if ok_signal and last_err is not None and not isinstance(last_err, Refused):
        why.append("the renderer did not come up after the restore (%s)" % last_err)
    elif ok_signal and not renderer_up[0]:
        why.append("the renderer did not come up after its last restart")
    if not ok_signal:
        why.append("signal not back")
    now = conf_now()
    if unread:
        why.append("conf not readable: " + unread[-1])
    rest = differences(now, user) if now is not None else []
    # The DV keys the user did not have stay as the test left them (as in
    # pi_hdmi_run.py): written on entering DV, read only in DV.
    left = [x for x in rest if x[0] in DV_KEYS and user.get(x[0], "") == ""]
    signal_keys = set(KEYS + SIDE_KEYS + DV_KEYS + META_KEYS + ("mode", "eotf"))
    bad = [x for x in rest if x[0] in signal_keys and x not in left]
    other = [x for x in rest if x[0] not in signal_keys]
    if bad:
        why.append("differs: " + " ".join("%s=%s (was %s)" % x for x in bad))
    if why:
        out("settings back: NO, " + "; ".join(why))
        return 1
    for x in left:
        out("note: %s=%s left (the user had none; read only in DV)" % x[:2])
    if other:
        out("settings back: signal yes; other keys differ (not written, decide about them):")
        for x in other:
            out("  %s=%s (was %s)" % x)
        return 3
    out("settings back: yes (conf = %s)" % label)
    return 0


def show():
    c = read_conf()
    out("mode=%s %s" % (mode(c), " ".join("%s=%s" % (k, c.get(k, "-")) for k in KEYS + ("mode_idx",))))
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "show":
        return show()
    if len(argv) != 3 or argv[1] not in ("save", "diff", "restore"):
        out("usage: pi_state.py save|diff|restore LABEL | show")
        return 2
    return {"save": save, "diff": diff, "restore": restore}[argv[1]](argv[2])


if __name__ == "__main__":
    # The Mac side may go away mid-restore: the restore runs to the end.
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    try:
        sys.exit(main(sys.argv))
    except SystemExit:
        raise
    except Exception as e:
        out("ERROR: %s: %s" % (type(e).__name__, e))
        sys.exit(1)
