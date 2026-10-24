#!/bin/sh
# Keep PGenerator WebUI (port 80) alive if the daemon exits unexpectedly.
# Installed as a cron every-minute helper on the device.

# cron runs jobs with a minimal PATH that omits /sbin and /usr/sbin. Both this
# script's tools and the init script it calls need them (setcap lives in
# /sbin; without it the restarted daemon cannot bind port 80 and the watchdog
# would restart it every minute forever).
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
# The test harness puts stub curl/ss in front; cron never sets this.
[ -n "${PG_WATCHDOG_STUB_PATH:-}" ] && PATH="$PG_WATCHDOG_STUB_PATH:$PATH"
export PATH

PID_FILE=${PG_WATCHDOG_PID_FILE:-/var/run/PGenerator/PGeneratord.pl.pid}
LOG=${PG_WATCHDOG_LOG:-/tmp/pgenerator-watchdog.log}
# PG_WATCHDOG_TMPDIR, PG_WATCHDOG_INIT, PG_WATCHDOG_PID_FILE and
# PG_WATCHDOG_STUB_PATH exist so the
# test harness can run the script in isolation; the device always uses the
# defaults.
WORK_DIR=${PG_WATCHDOG_TMPDIR:-/tmp}
INIT_SCRIPT=${PG_WATCHDOG_INIT:-/etc/init.d/PGenerator}
LOCK_FILE="$WORK_DIR/pgenerator-watchdog.lock"
PROBE_STAMP="$WORK_DIR/pgenerator-watchdog-root-ok"
FAIL_COUNT_FILE="$WORK_DIR/pgenerator-watchdog-failures"
TICK_COUNT_FILE="$WORK_DIR/pgenerator-watchdog-backoff"
INSTANCE_PID_FILE="$WORK_DIR/pgenerator-watchdog.pid"
# pgenerator-update writes this while it stops the daemon to install.
PAUSE_FILE="$WORK_DIR/pgenerator-watchdog.pause"
PAUSE_MAX_SECONDS=1800
STALL_COUNT_FILE="$WORK_DIR/pgenerator-watchdog-stalls"
# Root page stuck while /api/ping answers (see root_stall_due).
ROOT_FAIL_COUNT_FILE="$WORK_DIR/pgenerator-watchdog-root-stalls"
ROOT_RESTART_COUNT_FILE="$WORK_DIR/pgenerator-watchdog-root-restarts"
TIMEOUT_CMD=$(command -v timeout 2>/dev/null)
MAX_LOG=50
WEBUI_MIN_BYTES=65536

log() {
  ts=$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "?")
  if ! echo "$ts $*" >>"$LOG" 2>/dev/null; then
    # Unwritable log (full or read-only filesystem): keep the message.
    logger -t pgenerator-watchdog "$*" 2>/dev/null || true
  fi
  # keep log short
  if [ -f "$LOG" ]; then
    lines=$(wc -l <"$LOG" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$MAX_LOG" ] 2>/dev/null; then
      tail -n 30 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
    fi
  fi
}

# Bound the log by SIZE, not just by line count. The init script's own output
# is appended verbatim on every restart (the daemon's whole startup spew, which
# includes long single lines), and the line-count trim above only runs when
# this script itself logs. During the restart loop caused by the missing setcap
# this file reached 23 MB -- on a device whose disk is already nearly full that
# is an outage of its own.
MAX_LOG_BYTES=262144
trim_log() {
  [ -f "$LOG" ] || return 0
  log_bytes=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  case "$log_bytes" in (''|*[!0-9]*) log_bytes=0;; esac
  if [ "$log_bytes" -gt "$MAX_LOG_BYTES" ]; then
    tail -n 200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
  fi
}
trim_log

# /api/ping can remain healthy while a missing UI fragment breaks only `/`.
# What the page contains never enters the restart decision: a restart does
# not bring back a missing fragment. The recovery page is a valid HTTP
# response, but the sentinel makes that degraded state visible in the
# watchdog log. Only a probe that gets no page at all -- connect failure,
# timeout, or the accept thread's 503 "busy" once the lane's queue is full --
# counts as a stalled root (root_probe=stalled, see root_stall_due).
# The body is discarded — pulling the multi-megabyte page to disk every
# minute would wear the SD card; status and size come from curl itself, and
# the body is fetched for the sentinel only when the page is already small.
# Each ithread owns its own fragment/page cache, so one successful response
# cannot permanently vouch for every worker. A healthy PID stamp suppresses
# the expensive 2.6 MB probe for 15 minutes, then allows a low-frequency
# sample of another worker. Degraded results are never stamped, so an
# unhealthy root is re-probed every tick.
#
# Sets root_probe: "answered" (the lane served the request), "stalled" (it
# did not) or "skipped" (healthy stamp, nothing probed).
root_probe=skipped
probe_webui_root() {
  root_probe=skipped
  daemon_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [ -n "$daemon_pid" ] && [ "$(cat "$PROBE_STAMP" 2>/dev/null)" = "$daemon_pid" ] \
     && [ -n "$(find "$PROBE_STAMP" -mmin -15 2>/dev/null)" ]; then
    return 0
  fi
  status_file=$(mktemp "$WORK_DIR/pgenerator-watchdog-probe.XXXXXX" 2>/dev/null) || status_file="$WORK_DIR/pgenerator-watchdog-probe.$$"
  if ! err=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code} %{size_download}' http://127.0.0.1/ 2>&1 >"$status_file"); then
    log "ERROR: WebUI root probe failed to connect: ${err:-no detail}"
    rm -f "$status_file"
    root_probe=stalled
    return 0
  fi
  read -r status bytes <"$status_file" 2>/dev/null
  rm -f "$status_file"
  if [ "${status:-}" = "503" ]; then
    # Shed by the accept thread: the lane's queue is full, nothing is served.
    log "ERROR: WebUI root probe returned HTTP 503 (request lane busy)"
    root_probe=stalled
    return 0
  fi
  root_probe=answered
  rm -f "$ROOT_FAIL_COUNT_FILE" "$ROOT_RESTART_COUNT_FILE"
  if [ "${status:-}" != "200" ]; then
    log "ERROR: WebUI root probe returned HTTP ${status:-unknown}"
  elif [ "${bytes:-0}" -ge "$WEBUI_MIN_BYTES" ] 2>/dev/null; then
    # Full page served: nothing can change until the daemon restarts.
    [ -n "$daemon_pid" ] && echo "$daemon_pid" >"$PROBE_STAMP" 2>/dev/null
  else
    # A small — or unparseable — 200 could be the recovery page; fetch it
    # once to classify.
    body_file=$(mktemp "$WORK_DIR/pgenerator-watchdog-page.XXXXXX" 2>/dev/null) || body_file="$WORK_DIR/pgenerator-watchdog-page.$$"
    if ! curl -s --max-time 5 -o "$body_file" http://127.0.0.1/ 2>/dev/null; then
      log "ERROR: WebUI root probe classification fetch failed after a ${bytes:-0}-byte response"
    elif grep -Fq '<!--PG_RECOVERY_PAGE-->' "$body_file" 2>/dev/null; then
      log "ERROR: WebUI root probe found the fragment recovery page"
    else
      log "ERROR: WebUI root probe returned only ${bytes:-0} bytes"
    fi
    rm -f "$body_file"
  fi
  return 0
}

# /api/ping is served by the fast lane, `/` by the serialized general lane.
# One stuck general-lane request (2026-10: a worker parked in waitpid by a
# fork deadlock) kept `/` timing out for 30 minutes while ping answered, and
# the watchdog only logged. Restart once the root has stalled on
# ROOT_STALL_TICKS consecutive probes (ticks are minutes; an unhealthy root
# is probed on every tick). Five minutes is far beyond any legitimate
# general-lane request -- the helpers its handlers run are capped at 25 s,
# the long jobs (ICC builds, TV and meter talks, OTA installs) run on other
# lanes or in the background -- yet well short of the incident. It takes
# five probes in a row without a page (5 s each, a minute apart), so a busy
# moment on the lane does not add up to a restart.
# Restarts that do not bring the root back mean the cause is not a stuck
# request; after ROOT_STALL_BACKOFF_AFTER of them the next one needs
# ROOT_STALL_BACKOFF_TICKS stalled ticks. Any served page resets both.
ROOT_STALL_TICKS=5
ROOT_STALL_BACKOFF_AFTER=2
ROOT_STALL_BACKOFF_TICKS=30
root_stall_due() {
  [ "$root_probe" = "stalled" ] || return 1
  root_fails=$(cat "$ROOT_FAIL_COUNT_FILE" 2>/dev/null)
  case "$root_fails" in (''|*[!0-9]*) root_fails=0;; esac
  root_fails=$((root_fails + 1))
  echo "$root_fails" >"$ROOT_FAIL_COUNT_FILE" 2>/dev/null
  root_restarts=$(cat "$ROOT_RESTART_COUNT_FILE" 2>/dev/null)
  case "$root_restarts" in (''|*[!0-9]*) root_restarts=0;; esac
  root_need=$ROOT_STALL_TICKS
  [ "$root_restarts" -ge "$ROOT_STALL_BACKOFF_AFTER" ] && root_need=$ROOT_STALL_BACKOFF_TICKS
  [ "$root_fails" -ge "$root_need" ]
}

# Bounded liveness probe.
#
# This replaces `wget -q -O /dev/null -T 2`, which could not detect the very
# failure this watchdog exists to recover. GNU wget's -T is a PER-OPERATION
# timeout and wget RETRIES (--tries defaults to 20 with backoff waits), so
# against a daemon that accepts the connection and then never answers -- a
# wedged or SIGSTOPped daemon -- it keeps retrying for many minutes. Cron then
# stacked up another stuck instance every minute and the restart code below
# was never reached: proven on 2026-09-03 by freezing the daemon, after which
# the WebUI stayed down indefinitely with three wget processes piled up.
#
# curl's --max-time is a hard ceiling on the entire request and curl does not
# retry by default; `timeout` is a second ceiling in case the probe itself
# misbehaves. A connection-refused (daemon exited) still fails instantly.
webui_ping() {
  _url="http://127.0.0.1/api/ping"
  [ "${1:-80}" = "80" ] || _url="http://127.0.0.1:$1/api/ping"
  if [ -n "$TIMEOUT_CMD" ]; then
    "$TIMEOUT_CMD" 8 curl -s --connect-timeout 2 --max-time 4 -o /dev/null "$_url" 2>/dev/null
  else
    curl -s --connect-timeout 2 --max-time 4 -o /dev/null "$_url" 2>/dev/null
  fi
}

# One instance at a time. Cron fires every minute regardless of whether the
# previous tick finished, so a slow or stuck run must not accumulate. A
# predecessor still alive after 5 minutes is itself the fault: kill it (and
# its probe child) rather than let it block recovery forever.
if [ -f "$INSTANCE_PID_FILE" ]; then
  prev_pid=$(cat "$INSTANCE_PID_FILE" 2>/dev/null)
  case "$prev_pid" in (''|*[!0-9]*) prev_pid="";; esac
  if [ -n "$prev_pid" ] && [ "$prev_pid" != "$$" ] && [ -d "/proc/$prev_pid" ]; then
    if [ -n "$(find "$INSTANCE_PID_FILE" -mmin +5 2>/dev/null)" ]; then
      log "previous watchdog instance $prev_pid stuck over 5 minutes — killing it"
      pkill -9 -P "$prev_pid" 2>/dev/null
      kill -9 "$prev_pid" 2>/dev/null
    else
      exit 0
    fi
  fi
fi
echo $$ >"$INSTANCE_PID_FILE" 2>/dev/null

# Already listening?
# restart_reason: "ping" (the daemon does not answer at all) or "root" (it
# answers /api/ping, but `/` has stalled for ROOT_STALL_TICKS ticks).
restart_reason=ping
if webui_ping 80; then
  # Clear any failure history: the WebUI is healthy now, so a stale count
  # from an earlier incident must not push a future recovery into backoff.
  rm -f "$FAIL_COUNT_FILE" "$TICK_COUNT_FILE" "$STALL_COUNT_FILE"
  probe_webui_root
  root_stall_due || exit 0
  # A stalled root goes through the same guards as a dead daemon below
  # (update pause, boot/startup grace, calibration session, lock).
  restart_reason=root
fi

# An OTA update stops the daemon on purpose; never restart into it.
if [ -f "$PAUSE_FILE" ]; then
  paused_at=$(head -c 16 "$PAUSE_FILE" 2>/dev/null)
  now=$(date +%s)
  case "$paused_at" in (''|*[!0-9]*) paused_at=0;; esac
  if [ $((now - paused_at)) -lt "$PAUSE_MAX_SECONDS" ]; then
    exit 0
  fi
  log "ignoring stale update pause from $paused_at"
  rm -f "$PAUSE_FILE"
fi

# One missed ping is not an outage: a heavy request (ICC build, meter read,
# slow SD card) can stall the HTTP loop for a few seconds. Ask twice more.
# (A stalled root has already been confirmed on several ticks.)
retry=0
[ "$restart_reason" = "root" ] && retry=2
while [ "$retry" -lt 2 ]; do
  sleep 5
  if webui_ping 80; then
    rm -f "$FAIL_COUNT_FILE" "$TICK_COUNT_FILE" "$STALL_COUNT_FILE"
    exit 0
  fi
  retry=$((retry + 1))
done

# Ping is down: the restart path below is the diagnostic that matters, so do
# not add a redundant root-probe connect error on every tick of a restart.

# Startup grace: the daemon starts the renderer before its HTTP server, so a
# tick that lands in the first seconds after boot (or after any restart) saw
# "WebUI down" and restarted a daemon that was still starting -- one more
# HDMI resync on the TV for nothing. Leave a live daemon younger than
# STARTUP_GRACE seconds alone. Age comes from /proc (monotonic): the wall
# clock jumps by minutes when NTP syncs during boot.
STARTUP_GRACE=${PG_WATCHDOG_STARTUP_GRACE:-120}
# The same applies to the boot itself: cron already runs while rcPGenerator
# is still bringing up hostapd/wpa_supplicant/dhcpd before it starts the
# daemon, and a restart from here then raced that start.
BOOT_GRACE=${PG_WATCHDOG_BOOT_GRACE:-180}
boot_up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
case "$boot_up" in (''|*[!0-9]*) ;; (*)
  [ "$boot_up" -lt "$BOOT_GRACE" ] && exit 0
;; esac
daemon_pid=$(cat "$PID_FILE" 2>/dev/null | head -c 16)
case "$daemon_pid" in (''|*[!0-9]*) daemon_pid="";; esac
if [ -n "$daemon_pid" ] && [ -r "/proc/$daemon_pid/stat" ]; then
  start_ticks=$(sed 's/.*) //' "/proc/$daemon_pid/stat" 2>/dev/null | awk '{print $20}')
  hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
  case "$start_ticks$hz$up" in (''|*[!0-9]*) ;; (*)
    age=$((up - start_ticks / hz))
    if [ "$age" -lt "$STARTUP_GRACE" ]; then
      exit 0
    fi
  ;; esac
fi

# Avoid thrash if init is mid-restart
# The daemon process is alive but not answering while a calibration program
# (Calman UPGCI 2100, HCFR/RPC 2101, Resolve/ColourSpace 20002) is connected:
# restarting would drop the session. Give it three ticks (minutes) first.
# With only `/` stalled the daemon is serving that session (calibration
# programs do not use the WebUI lanes), so never drop it for the page: wait
# until the client disconnects.
calibration_client_connected() {
  ss -tn state established 2>/dev/null | awk '{print $3" "$4}' | grep -Eq ':(2100|2101) |:20002$'
}
if [ "$restart_reason" = "root" ] && calibration_client_connected; then
  log "WebUI root page stalled for $root_fails minutes but a calibration client is connected — not restarting"
  exit 0
fi
if [ -n "$daemon_pid" ] && [ -d "/proc/$daemon_pid" ] && calibration_client_connected; then
  stalls=$(cat "$STALL_COUNT_FILE" 2>/dev/null)
  case "$stalls" in (''|*[!0-9]*) stalls=0;; esac
  stalls=$((stalls + 1))
  if [ "$stalls" -lt 3 ]; then
    echo "$stalls" >"$STALL_COUNT_FILE" 2>/dev/null
    log "WebUI not answering but a calibration client is connected — waiting ($stalls/3)"
    exit 0
  fi
  log "WebUI still not answering after 3 minutes with a calibration client connected"
fi
rm -f "$STALL_COUNT_FILE"

if [ -f "$LOCK_FILE" ]; then
  # stale lock older than 120s?
  if [ -n "$(find "$LOCK_FILE" -mmin +2 2>/dev/null)" ]; then
    rm -f "$LOCK_FILE"
  else
    exit 0
  fi
fi

# When a restart does not bring the WebUI back, the cause is usually
# environmental (port 80 held by something else, a missing capability, a full
# filesystem) and retrying every single minute just kills the daemon forever
# without ever recovering -- observed for real when cron's PATH hid setcap.
# After BACKOFF_AFTER consecutive failed recoveries, restart only once every
# BACKOFF_EVERY ticks. Any success resets the counter.
BACKOFF_AFTER=5
BACKOFF_EVERY=10
fail_count=$(cat "$FAIL_COUNT_FILE" 2>/dev/null)
case "$fail_count" in (''|*[!0-9]*) fail_count=0;; esac
if [ "$fail_count" -ge "$BACKOFF_AFTER" ]; then
  tick_count=$(cat "$TICK_COUNT_FILE" 2>/dev/null)
  case "$tick_count" in (''|*[!0-9]*) tick_count=0;; esac
  tick_count=$((tick_count + 1))
  if [ "$tick_count" -lt "$BACKOFF_EVERY" ]; then
    echo "$tick_count" >"$TICK_COUNT_FILE" 2>/dev/null
    exit 0
  fi
  echo 0 >"$TICK_COUNT_FILE" 2>/dev/null
  log "WebUI still down after $fail_count restarts — retrying (backed off to every $BACKOFF_EVERY minutes)"
fi

touch "$LOCK_FILE"

# The new daemon starts with fresh lanes: its root stalls count from zero.
rm -f "$ROOT_FAIL_COUNT_FILE"
if [ "$restart_reason" = "root" ]; then
  echo $((root_restarts + 1)) >"$ROOT_RESTART_COUNT_FILE" 2>/dev/null
  log "WebUI root page stalled for $root_fails minutes while /api/ping answers — restarting PGenerator"
else
  log "WebUI down — restarting PGenerator"
fi
"$INIT_SCRIPT" restart >>"$LOG" 2>&1
trim_log
# Poll rather than check once: a fresh daemon needs a few seconds to compile
# and bind, and a single probe 4s in reported "still down" for a restart that
# actually succeeded one second later -- a false failure that counted toward
# the backoff above and put a misleading line in the log.
recovered=""
i=0
while [ "$i" -lt 10 ]; do
  sleep 2
  if webui_ping 80; then recovered=1; break; fi
  i=$((i + 1))
done
if [ -n "$recovered" ]; then
  log "WebUI recovered"
  rm -f "$FAIL_COUNT_FILE" "$TICK_COUNT_FILE"
  probe_webui_root
else
  fail_count=$((fail_count + 1))
  echo "$fail_count" >"$FAIL_COUNT_FILE" 2>/dev/null
  # A daemon that came up on the fallback port is a specific, fixable fault:
  # name it instead of logging a generic failure every minute.
  if webui_ping 8080; then
    log "ERROR: WebUI answered on port 8080 — it could not bind port 80 (perl is missing cap_net_bind_service; check setcap in $INIT_SCRIPT)"
  else
    log "WebUI still down after restart (consecutive failures: $fail_count)"
  fi
fi
rm -f "$LOCK_FILE"
exit 0
