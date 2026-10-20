#!/usr/bin/python3
# -*- coding: utf-8 -*-
#
# pgen_cec_remote.py - PGenerator+ TV remote listener (HDMI-CEC).
#
# Forwards the TV remote's keys to the daemon (POST /api/remote/key), which
# steps a running playlist and drives the on-screen pattern menu. Started by
# webui.pm at daemon start (when "listen to the TV remote at all times" is on),
# when a playlist starts and when the menu is opened from the WebUI. It runs
# as the daemon user and exits by itself once nothing needs it: no playlist,
# no open menu and the setting off (or two hours without a key press then),
# or on SIGTERM.
#
# It listens on /dev/cecN as a non-exclusive initiator and follower, so the
# one-shot helpers (pgcec, pgenerator-cec) keep working while it runs. The TV
# sends <User Control Pressed> to the active source. When the WebUI asks for
# it (the announce file), the listener announces the Pi as active source on
# its own input and answers <Menu Request> with "menu active", which LG and
# other sinks want before they forward keys; a listener that only waits for
# keys stays silent on the bus.
#
#   Arrows, Select (OK), Exit, Back, Root/Setup/Contents menu,
#   Channel up/down and Forward/Backward (next/prev), 0-9
#
# Usage: pgen_cec_remote.py <playlist_state> <remote_state> [<menu_state>
#        [<menu_settings> [/dev/cecN]]]
#
import array, errno, fcntl, glob, json, os, signal, struct, sys, time, urllib.request

def _IOC(d, t, nr, sz): return (d << 30) | (sz << 16) | (t << 8) | nr
def _IOR(t, nr, sz):  return _IOC(2, t, nr, sz)
def _IOW(t, nr, sz):  return _IOC(1, t, nr, sz)
def _IOWR(t, nr, sz): return _IOC(3, t, nr, sz)

M = 0x61
CEC_MSG_SZ = 56          # struct cec_msg (kernel 5.10, ARM 32-bit)
CEC_LOG_ADDRS_SZ = 92
CEC_ADAP_G_PHYS_ADDR = _IOR(M, 1, 2)
CEC_ADAP_G_LOG_ADDRS = _IOR(M, 3, CEC_LOG_ADDRS_SZ)
CEC_ADAP_S_LOG_ADDRS = _IOWR(M, 4, CEC_LOG_ADDRS_SZ)
CEC_TRANSMIT = _IOWR(M, 5, CEC_MSG_SZ)
CEC_RECEIVE = _IOWR(M, 6, CEC_MSG_SZ)
CEC_S_MODE = _IOW(M, 9, 4)
CEC_MODE_INITIATOR = 0x01
CEC_MODE_FOLLOWER = 0x10

OP_USER_CONTROL_PRESSED = 0x44
OP_USER_CONTROL_RELEASED = 0x45
OP_ACTIVE_SOURCE = 0x82
OP_MENU_REQUEST = 0x8D
OP_MENU_STATUS = 0x8E
OP_GIVE_POWER = 0x8F
OP_REPORT_POWER = 0x90

KEYS = {
    0x00: "ok", 0x01: "up", 0x02: "down", 0x03: "left", 0x04: "right",
    0x09: "menu", 0x0A: "menu", 0x0B: "menu",
    0x30: "next", 0x31: "prev", 0x4B: "next", 0x4C: "prev",
    0x0D: "exit", 0x91: "back",
}
for n in range(0, 10):
    KEYS[0x20 + n] = str(n)
NAMES = {"ok": "OK", "up": "Up", "down": "Down", "left": "Left", "right": "Right", "menu": "Menu",
         "next": "Next", "prev": "Previous", "exit": "Exit", "back": "Back"}

IDLE_LIMIT = 2 * 3600
# A menu left on screen closes after ten minutes (OLED panels).
MENU_IDLE = 600
ANNOUNCE_FILE = "/tmp/pgen-cec-announce"
# A held key repeats <User Control Pressed> every 200-500 ms, with or
# without a <User Control Released> in between (LG sends both). Navigation
# keys step on every repeat, like a TV menu; the other keys act once per
# press, and the same key again within REPEAT_GAP counts as held.
REPEATING = ("up", "down", "left", "right", "next", "prev")
REPEAT_GAP = 0.6
LOCK_FILE = "/tmp/pgen-cec-remote.lock"

state_file = sys.argv[1] if len(sys.argv) > 1 else "/var/lib/PGenerator/running/playlist-state.json"
remote_file = sys.argv[2] if len(sys.argv) > 2 else "/tmp/pgen-cec-remote.json"
menu_file = sys.argv[3] if len(sys.argv) > 3 else "/var/lib/PGenerator/running/tvmenu-state.json"
settings_file = sys.argv[4] if len(sys.argv) > 4 else "/var/lib/PGenerator/tvmenu/settings.json"
device = sys.argv[5] if len(sys.argv) > 5 else (sorted(glob.glob("/dev/cec*")) or ["/dev/cec0"])[0]
status = {"pid": os.getpid(), "listening": False, "device": device, "last_key": "", "last_key_at": 0, "message": ""}


def write_status(**kw):
    status.update(kw)
    tmp = remote_file + ".tmp"
    try:
        with open(tmp, "w") as fh:
            json.dump(status, fh)
        os.rename(tmp, remote_file)
    except OSError:
        pass


def read_json(path):
    try:
        with open(path) as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def playlist_active():
    return bool(read_json(state_file).get("active"))


def menu_state():
    return read_json(menu_file)


def listen_always():
    return read_json(settings_file).get("listen", True) is not False


def api_key(key):
    body = json.dumps({"key": key}).encode()
    req = urllib.request.Request("http://127.0.0.1/api/remote/key", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=70) as resp:
            return json.loads(resp.read().decode() or "{}")
    except Exception as exc:  # the next key press tries again
        return {"status": "error", "message": str(exc)}


def ioctl(fd, req, buf):
    try:
        fcntl.ioctl(fd, req, buf)
        return True
    except OSError:
        return False


def logical_address(fd):
    buf = array.array('B', [0] * CEC_LOG_ADDRS_SZ)
    if not ioctl(fd, CEC_ADAP_G_LOG_ADDRS, buf):
        return 0xFF
    mask = buf[4] | (buf[5] << 8)
    if mask and buf[7]:
        return buf[0]
    return 0xFF


def claim_playback(fd):
    """Claim a Playback logical address (4, 8 or 11) when none is held."""
    buf = array.array('B', [0] * CEC_LOG_ADDRS_SZ)
    buf[0:4] = array.array('B', [0xFF] * 4)
    buf[6] = 5      # CEC 1.4
    buf[7] = 1
    buf[8:12] = array.array('B', [0xFF, 0xFF, 0xFF, 0xFF])  # CEC_VENDOR_ID_NONE
    for i, ch in enumerate(b"PGenerator"):
        buf[16 + i] = ch
    buf[31] = 4     # primary device type: playback
    buf[35] = 3     # log_addr_type: playback
    buf[39] = 0x10  # all device types: playback
    if not ioctl(fd, CEC_ADAP_S_LOG_ADDRS, buf):
        return 0xFF
    for _ in range(25):
        time.sleep(0.1)
        la = logical_address(fd)
        if la != 0xFF:
            return la
    return 0xFF


def phys_addr(fd):
    buf = array.array('B', [0xFF, 0xFF])
    if not ioctl(fd, CEC_ADAP_G_PHYS_ADDR, buf):
        return 0xFFFF
    return struct.unpack('<H', buf.tobytes())[0]


def transmit(fd, src, dst, opcode, params=()):
    msg = array.array('B', [0] * CEC_MSG_SZ)
    struct.pack_into('<I', msg, 16, 2 + len(params))
    struct.pack_into('<I', msg, 20, 0)
    msg[32] = ((src & 0x0F) << 4) | (dst & 0x0F)
    msg[33] = opcode
    for i, b in enumerate(params):
        msg[34 + i] = b
    return ioctl(fd, CEC_TRANSMIT, msg)


def receive(fd, timeout_ms):
    msg = array.array('B', [0] * CEC_MSG_SZ)
    struct.pack_into('<I', msg, 20, timeout_ms)
    try:
        fcntl.ioctl(fd, CEC_RECEIVE, msg)
    except OSError as exc:
        if exc.errno in (errno.ETIMEDOUT, errno.EAGAIN, errno.EINTR):
            return None
        raise
    length = struct.unpack_from('<I', msg, 16)[0]
    return list(msg[32:32 + min(length, 16)])


def answer(fd, la, msg):
    """Replies to the TV's menu and power queries; True if msg was one."""
    src, opcode = msg[0] >> 4, msg[1]
    if opcode == OP_MENU_REQUEST:
        transmit(fd, la, src, OP_MENU_STATUS, [0x00])
    elif opcode == OP_GIVE_POWER:
        transmit(fd, la, src, OP_REPORT_POWER, [0x00])
    else:
        return False
    return True


running = True


def stop(*_):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)


def take_lock():
    """One listener at a time. A listener from a playlist that just ended
    exits within a second, so wait a little for it."""
    try:
        lock = os.open(LOCK_FILE, os.O_RDWR | os.O_CREAT, 0o666)
    except OSError:
        return None  # e.g. left behind by another user; fail closed
    for _ in range(30):
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return lock
        except OSError:
            time.sleep(0.1)
    os.close(lock)
    return None


RETRY = "retry"
RETRY_WAIT = 20


def needed():
    view = menu_state().get("view") or ""
    return listen_always() or bool(view) or playlist_active()


def main():
    lock = take_lock()
    if lock is None:
        return 0  # another listener serves the running playlist
    write_status(pid=os.getpid())
    # A TV that is off (or still booting) gives no CEC address; the hot plug
    # of a TV switched on later drops it again. Keep trying while something
    # needs the remote.
    while running:
        rc = serve()
        if rc != RETRY or not needed():
            return 0 if rc == RETRY else rc
        write_status(listening=False)
        for _ in range(RETRY_WAIT):
            if not running:
                break
            time.sleep(1)
    return 0


def serve():
    write_status(message="Opening the HDMI-CEC adapter.")
    try:
        fd = os.open(device, os.O_RDWR)
    except OSError as exc:
        write_status(message="HDMI-CEC is not available: %s." % exc.strerror)
        return 1
    mode = array.array('B', [0] * 4)
    struct.pack_into('<I', mode, 0, CEC_MODE_INITIATOR | CEC_MODE_FOLLOWER)
    if not ioctl(fd, CEC_S_MODE, mode):
        write_status(message="Another program holds HDMI-CEC; the remote cannot step the playlist.")
        os.close(fd)
        return RETRY
    la = logical_address(fd)
    if la == 0xFF:
        la = claim_playback(fd)
    if la == 0xFF:
        write_status(message="The TV did not give PGenerator+ a CEC address. Is the TV on, with HDMI-CEC (SimpLink, Anynet+, Bravia Sync) enabled?")
        os.close(fd)
        return RETRY
    write_status(listening=True, message="Listening for the TV remote.", logical_address=la)

    last_key, last_at, last_press, released = None, 0.0, time.time(), True
    checked = time.time()
    result = 0
    while running:
        if time.time() - checked > 30:
            checked = time.time()
            if logical_address(fd) == 0xFF:
                write_status(message="The TV dropped the CEC address; asking again.")
                result = RETRY
                break
        if os.path.exists(ANNOUNCE_FILE):
            try:
                os.unlink(ANNOUNCE_FILE)
            except OSError:
                pass
            phys = phys_addr(fd)
            if phys != 0xFFFF:
                # Same input the Pi is already on: makes the TV route remote keys here.
                transmit(fd, la, 0x0F, OP_ACTIVE_SOURCE, [(phys >> 8) & 0xFF, phys & 0xFF])
            transmit(fd, la, 0x00, OP_MENU_STATUS, [0x00])
        menu = menu_state()
        view = menu.get("view") or ""
        always = listen_always()
        if not always and not view and not playlist_active():
            break
        now = time.time()
        if not always and now - last_press > IDLE_LIMIT:
            write_status(message="Stopped listening after two hours without a key press.")
            break
        if view == "menu" and now - max(last_press, float(menu.get("changed") or 0)) > MENU_IDLE:
            api_key("timeout")
            last_press = now
        try:
            msg = receive(fd, 1000)
        except OSError as exc:
            write_status(listening=False, message="HDMI-CEC read failed: %s." % exc.strerror)
            result = RETRY
            break
        if not msg or len(msg) < 2:
            continue
        if answer(fd, la, msg):
            continue
        opcode = msg[1]
        if opcode == OP_USER_CONTROL_RELEASED:
            released = True
        elif opcode == OP_USER_CONTROL_PRESSED and len(msg) >= 3:
            key = msg[2]
            now = time.time()
            name = KEYS.get(key)
            if name not in REPEATING and key == last_key and (not released or now - last_at < REPEAT_GAP):
                last_at = now
                continue
            last_key, last_at, last_press, released = key, now, now, False
            if not name:
                continue
            write_status(last_key=NAMES.get(name, name), last_key_at=int(now))
            api_key(name)
            # The daemon answers once the new picture is up. Keys that came in
            # meanwhile are dropped, so a held key stops on release instead of
            # working off a queue; releases and TV requests still count.
            while True:
                msg = receive(fd, 1)
                if not msg or len(msg) < 2:
                    break
                if answer(fd, la, msg):
                    continue
                if msg[1] == OP_USER_CONTROL_RELEASED:
                    released = True
                elif msg[1] == OP_USER_CONTROL_PRESSED and len(msg) >= 3:
                    released = False
                    if msg[2] == last_key:
                        last_at = time.time()
    os.close(fd)
    # Keep a reason written above (idle limit, read error); clear the rest.
    if status.get("message") == "Listening for the TV remote.":
        write_status(listening=False, message="")
    else:
        write_status(listening=False)
    return result


if __name__ == "__main__":
    sys.exit(main())
