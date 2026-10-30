#!/bin/sh
# Installs a bundle onto the Pi (run as root, from the bundle directory or
# anywhere). pgen-pi deploy builds the bundle; by hand it is:
#   <dir>/MANIFEST      one line per file: TARGET OLD_MD5 NEW_MD5
#                       (TARGET the real path, no symlink; OLD_MD5 "-" when
#                       the file is not on the Pi yet)
#   <dir>/LABEL         one word, names the backup (pre-LABEL-<time>)
#   <dir>/files/TARGET  the new files
#   <dir>/pi_calman_busy.sh
#   sh <dir>/pi_deploy.sh --check   only compare the Pi with the manifest
#                                   (exit 0: all old or all new)
#   sh <dir>/pi_deploy.sh           check, back up, install, restart
#   sh <backup>/restore.sh          put that backup back and restart
#                                   (= <backup>/pi_deploy.sh --restore <backup>)
# Generalised from the reviewed 2.13.34 deploy.sh (build/pi-deploy/,
# TASKS.md reviews 7, 8, 11, 12); the steps and their order are the same.
# Stops when a file on the Pi is neither the old one nor already the new
# one (look at it first), when the Pi holds a mix of both (an earlier run
# did not finish; FORCE=1 installs anyway in both cases), when another run
# (deploy or restore) is going, when Calman is busy (pi_calman_busy.sh
# next to this script; FORCE_BUSY=1 skips that), and while a signal test
# runs (pi_hdmi_run.py and the like hold /tmp/pgen-signal-test.lock, the
# WebUI self-test writes /tmp/pgen-selftest.json: a restart under either
# would cost the user's settings). Run again once installed,
# it only reports. The backup goes to /root/pgen-backups/, with copies of
# this script, the manifest and the busy check and a restore.sh that calls
# them.
# The WebUI watchdog is paused from the start (a watchdog run already under
# way is waited for); a run that stops before it changes anything leaves
# the pause as it found it.
# Interrupted after the daemon stopped and before every file is in, it puts
# the backup back and starts the daemon again; interrupted after that, it
# starts the new daemon if it has not yet and says so. A restore, once it
# stops the daemon, runs to the end.
# A session that goes away (ssh without a terminal: the next echo would
# raise SIGPIPE) does not end it half-way: SIGPIPE is ignored, the run
# finishes, and the daemon is started with SIGPIPE as normal.
trap '' PIPE
D=$(cd "$(dirname "$0")" && pwd) || exit 1
# PGEN_BACKUPS, PGEN_TMP, PGEN_INIT: other places for the backups, the
# locks and the init script (t/pi_deploy.t); unset on the Pi.
BACKUPS=${PGEN_BACKUPS:-/root/pgen-backups}
T=${PGEN_TMP:-/tmp}
INIT=${PGEN_INIT:-/etc/init.d/PGenerator}
MODE=install
case "${1:-}" in
 "") ;;
 --check) MODE=check ;;
 --restore)
  MODE=restore; BK=${2:-}
  [ -n "$BK" ] && [ -d "$BK" ] || { echo "usage: sh $0 --restore <backup dir>"; exit 2; }
  # Only a backup this script made (any other directory with the same
  # layout, the bundle among them, would be installed without a backup).
  case "$BK" in
   *..*|*/) echo "STOP: $BK: give the backup directory as pi_deploy.sh printed it"; exit 2 ;;
   "$BACKUPS"/pre-*) ;;
   *) echo "STOP: $BK is not a backup of this script ($BACKUPS/pre-*)"; exit 2 ;;
  esac
  # BACKED_UP is empty when none of the files was there before.
  [ -s "$BK/MANIFEST" ] && [ -f "$BK/BACKED_UP" ] || { echo "STOP: $BK has no MANIFEST/BACKED_UP; not a pi_deploy.sh backup"; exit 2; }
  D=$BK ;;
 *) echo "usage: sh $0 [--check | --restore <backup dir>]"; exit 2 ;;
esac
PAUSE=$T/pgenerator-watchdog.pause
LOCK=$T/pgen-deploy.lock
TEST_LOCK=$T/pgen-signal-test.lock
SELFTEST_STATE=$T/pgen-selftest.json
WATCHDOG_PID=$T/pgenerator-watchdog.pid
[ -s "$D/MANIFEST" ] || { echo "STOP: $D/MANIFEST is missing or empty"; exit 2; }
LABEL=$(cat "$D/LABEL" 2>/dev/null)
case "$LABEL" in (''|*[!A-Za-z0-9._-]*) echo "STOP: $D/LABEL must be one word of A-Z a-z 0-9 . _ -"; exit 2;; esac
# target  old md5 ("-": not on the Pi)  new md5
LIST=$(cat "$D/MANIFEST")
# (no {32}: old mawk has no intervals)
# No glob characters either: each() splits the list with set --.
bad_line=$(echo "$LIST" | awk 'function h(x) { return length(x)==32 && x ~ /^[0-9a-f]+$/ } NF && !(NF==3 && $1 ~ /^\// && $1 !~ /\.\./ && $1 !~ /[*?[]/ && ($2=="-" || h($2)) && h($3))' | head -1)
[ -z "$bad_line" ] || { echo "STOP: bad MANIFEST line: $bad_line"; exit 2; }
md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
each() { fn=$1; set -f; set -- $LIST; set +f; while [ $# -ge 3 ]; do "$fn" "$1" "$2" "$3" || return 1; shift 3; done; }

BAD=0
OLD=0
NEW=0
pi_state() {
 if [ -L "$1" ]; then echo "  OTHER     $1 (a symlink; the manifest names real paths)"; BAD=1; return 0; fi
 m=$(md5 "$1")
 # Same old and new md5: the file does not change; it counts neither way
 # (next to old files it would look like a half-done run).
 if [ "$2" = "$3" ] && [ "$m" = "$3" ]; then echo "  unchanged $1"
 elif [ "$2" = "-" ] && [ ! -e "$1" ]; then echo "  old       $1 (not there yet)"; OLD=1
 elif [ "$m" = "$3" ]; then echo "  new       $1"; NEW=1
 elif [ "$m" = "$2" ]; then echo "  old       $1"; OLD=1
 else echo "  OTHER     $1 (${m:-missing})"; BAD=1; fi
}
# listening P...: true when every port P listens (TCP).
listening() {
 L=$( (netstat -ltn 2>/dev/null || ss -ltn 2>/dev/null) )
 for p in "$@"; do echo "$L" | grep -q "[:.]$p[[:space:]]" || return 1; done
}
ports_up() { listening 80 85 2100 2101; }
# The WebUI self-test's state says running and its pid lives (without a
# pid yet: written in the last 5 s, as webui.pm judges it).
selftest_running() {
 st=$(cat $SELFTEST_STATE 2>/dev/null) || return 1
 echo "$st" | grep -Eq '"state"[[:space:]]*:[[:space:]]*"running"' || return 1
 sp=$(echo "$st" | sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
 if [ -n "$sp" ]; then [ -d /proc/$sp ]; return; fi
 m=$(stat -L -c %Y $SELFTEST_STATE 2>/dev/null) || return 1
 [ $(($(date +%s)-m)) -lt 5 ]
}
# The self-test knows none of the locks: looked at after the lock and once
# more right before the stop (one started in between would run on under it).
selftest_free() {
 selftest_running || return 0
 echo "STOP: the WebUI signal self-test is running (pid ${sp:-not written yet}, $SELFTEST_STATE); let it finish. If none runs: rm $SELFTEST_STATE"
 return 1
}
# pi_calman_busy.sh exits 0 for FREE, 1 for BUSY; its reasons (stale
# sockets too) come before that word, so the exit status decides. With the
# daemon down it still reads the log (a session cut by a stop or crash).
calman_free() {
 [ "${FORCE_BUSY:-0}" = "1" ] && return 0
 busy=$(sh "$D/pi_calman_busy.sh" 2>&1) && return 0
 echo "STOP: Calman may be in use (or the check failed; FORCE_BUSY=1 skips it):"; echo "$busy"; return 1
}
# Keeps the WebUI watchdog off for a day (it would start a mixed tree): a
# stamp ahead of now, beyond its 30-minute cap for a current one.
pause_for_a_day() {
 echo $(($(date +%s)+86400)) > $PAUSE && [ -s $PAUSE ]
}
pause_now() {
 date +%s > $PAUSE && [ -s $PAUSE ]
}
bundle_ok() {
 [ -s "$D/files$1" ] && [ "$(md5 "$D/files$1")" = "$3" ] && return 0
 echo "STOP: bundle file $D/files$1 is empty or not the expected one"; return 1
}
# In a backup, BACKED_UP lists the targets that were there (and are in the
# backup); the others did not exist and are removed on a restore.
backed_up() { grep -qxF "$1" "$BK/BACKED_UP"; }
backup_there() {
 backed_up "$1" || return 0
 [ -s "$BK$1" ] && return 0
 echo "STOP: $BK$1 is missing or empty; nothing changed"; return 1
}
# A watchdog run reads the pause file once, then retries for 10 s and may
# restart the daemon without looking again: one that started before the
# pause was written must end before anything is stopped. Its pid file stays
# after it ends, so the process behind the pid decides.
wait_watchdog() {
 i=0
 while [ $i -lt 90 ]; do
  p=$(cat $WATCHDOG_PID 2>/dev/null)
  case "$p" in (''|*[!0-9]*) return 0;; esac
  grep -q pgenerator-webui-watchdog /proc/$p/cmdline 2>/dev/null || return 0
  [ $i -eq 0 ] && echo "Waiting for a WebUI watchdog run (pid $p) to end ..."
  sleep 1; i=$((i+1))
 done
 return 1
}

# Lock and pause. finish() runs on every exit: it gives the pause back as
# found while this run owns it (until the daemon is stopped; from there on
# roll_back and start_and_wait set it) and drops the lock.
LOCKED=0
PAUSE_OWNED=0
PREV_PAUSE=""
finish() {
 if [ $PAUSE_OWNED -eq 1 ]; then
  if [ -n "$PREV_PAUSE" ]; then echo "$PREV_PAUSE" > $PAUSE; else rm -f $PAUSE; fi
  PAUSE_OWNED=0
 fi
 if [ $LOCKED -eq 1 ]; then rm -f $LOCK/pid; rmdir $LOCK 2>/dev/null; LOCKED=0; fi
}
ahead=0
if [ $MODE != check ]; then
 # A signal while the lock is taken is held back until its pid is in (in
 # between it would leave the lock without one).
 GOT_SIG=0
 trap 'GOT_SIG=1' INT TERM HUP QUIT
 # mkdir itself runs with them ignored: killed by one after it made the
 # directory, it would leave it behind.
 if ! (trap '' INT TERM HUP QUIT; exec mkdir $LOCK) 2>/dev/null; then
  [ $GOT_SIG -eq 1 ] && { echo "Interrupted before anything changed."; exit 1; }
  p=$(cat $LOCK/pid 2>/dev/null)
  if [ ! -d $LOCK ]; then
   echo "STOP: cannot create $LOCK (is /tmp full or read-only?)"
  elif [ -n "$p" ] && [ -d /proc/$p ]; then
   echo "STOP: another deploy or restore is running (pid $p)"
  else
   echo "STOP: $LOCK is there but its run (pid ${p:-unknown}) is not; it was killed, or one is just starting. If none runs: rm -rf $LOCK"
  fi
  exit 1
 fi
 LOCKED=1
 trap finish EXIT
 trap 'exit 1' INT TERM HUP QUIT
 [ $GOT_SIG -eq 1 ] && { echo "Interrupted before anything changed."; exit 1; }
 if ! { echo $$ > $LOCK/pid && [ -s $LOCK/pid ]; } 2>/dev/null; then
  echo "STOP: cannot write $LOCK/pid (is /tmp full?)"; exit 1
 fi
 if [ -d $TEST_LOCK ]; then
  tp=$(cat $TEST_LOCK/pid 2>/dev/null)
  echo "STOP: a signal test holds $TEST_LOCK (pid ${tp:-unknown}); let it finish. If none runs: rm -rf $TEST_LOCK"
  exit 1
 fi
 selftest_free || exit 1
 PREV_PAUSE=$(cat $PAUSE 2>/dev/null)
 now=$(date +%s)
 case "$PREV_PAUSE" in (''|*[!0-9]*) ;; (*) [ "$PREV_PAUSE" -gt "$now" ] && ahead=1;; esac
 PAUSE_OWNED=1
 # A stamp ahead of now (a day pause of an earlier run) is kept as it is.
 if [ $ahead -eq 0 ] && ! pause_now; then
  echo "STOP: cannot pause the WebUI watchdog ($PAUSE); nothing changed"; exit 1
 fi
 wait_watchdog || { echo "STOP: a WebUI watchdog run is still going after 90 s; nothing changed"; exit 1; }
fi
pause_note() {
 [ $ahead -eq 1 ] && echo "Note: an earlier run paused the WebUI watchdog for another $((PREV_PAUSE-$(date +%s))) s ($PAUSE); rm it once the daemon should be watched again."
 return 0
}

echo "Files on the Pi ($LABEL):"
each pi_state

RB=0
restore_one() {
 rm -f "$1".new.[0-9]*
 if ! backed_up "$1"; then
  rm -f "$1"
  [ -e "$1" ] && { echo "  NOT REMOVED $1 (it was not there before)"; RB=1; }
  return 0
 fi
 cp -p "$BK$1" "$1.restore" 2>/dev/null && mv -f "$1.restore" "$1"
 rm -f "$1.restore"
 [ "$(md5 "$1")" = "$(md5 "$BK$1")" ] || { echo "  NOT RESTORED $1 (the backup is $BK$1)"; RB=1; }
 return 0
}
# The daemon gets PIPE, TERM, HUP, INT and QUIT as on a normal start, not
# the ignores of this script or of a background start (a shell starts a
# background job with INT and QUIT ignored, and trap cannot reset that).
STARTED=0
start_daemon() {
 STARTED=1
 ( trap - PIPE TERM HUP; exec perl -e '$SIG{INT}=$SIG{QUIT}="DEFAULT"; exec { $ARGV[0] } @ARGV; exit 127' setsid "$INIT" start </dev/null >$T/pgen-restart.log 2>&1 ) &
}
# Starts the daemon and keeps the watchdog paused until all four ports
# listen (at most 40 s): it must not restart a daemon that is still coming up.
start_and_wait() {
 start_daemon
 i=0
 while [ $i -lt 40 ]; do
  if ports_up; then rm -f $PAUSE; return 0; fi
  sleep 1; i=$((i+1))
 done
 rm -f $PAUSE
 return 1
}
# Back to the backup and running again (exit status 0 once all four ports
# listen); with files that did not come back the daemon stays stopped (a
# mixed tree breaks at runtime).
roll_back() {
 "$INIT" stop
 each restore_one
 sync
 if [ $RB -eq 0 ]; then
  echo "Backup is back in place; starting the daemon."
  if start_and_wait; then echo "Daemon up (all four ports listen)."; return 0; fi
  echo "WARNING: not all ports listen after 40 s; see $T/pgen-restart.log"; return 1
 fi
 if pause_for_a_day; then
  echo "WARNING: not every file is back (see above); the daemon stays stopped and the WebUI watchdog paused for a day. Fix them, then: sh $BK/restore.sh"
 else
  echo "WARNING: not every file is back (see above) and the WebUI watchdog could not be paused: it will start the daemon on these files. Fix them, then: sh $BK/restore.sh"
 fi
 return 1
}

if [ $MODE = restore ]; then
 each backup_there || exit 1
 calman_free || exit 1
 selftest_free || exit 1
 if ! pause_now; then echo "STOP: cannot pause the WebUI watchdog ($PAUSE); nothing changed"; exit 1; fi
 trap '' INT TERM HUP QUIT
 PAUSE_OWNED=0
 echo "Putting $BK back."
 roll_back
 exit $?
fi

each bundle_ok || exit 1
if [ $MODE = check ]; then
 [ $BAD -eq 0 ] && { [ $OLD -eq 0 ] || [ $NEW -eq 0 ]; } && exit 0
 exit 1
fi
# Run again after a deploy: nothing to install, and a backup now would
# hold the new files (its restore.sh would not go back to the old ones).
if [ $BAD -eq 0 ] && [ $OLD -eq 0 ]; then
 if ports_up; then
  echo "Already installed: every file is the new one. Nothing done."; pause_note; exit 0
 fi
 echo "Already installed, but the daemon does not listen on all four ports: see $T/pgen-restart.log, then restart the daemon"
 pause_note
 exit 1
fi
if [ $BAD -ne 0 ] && [ "${FORCE:-0}" != "1" ]; then
 echo "STOP: a file on the Pi is neither the old nor the new one. Look at it, then FORCE=1 if it may be replaced."
 exit 1
fi
# Some files new, some old: an earlier run did not finish. A backup now
# would hold that mix, and a rollback would start it.
if [ $OLD -ne 0 ] && [ $NEW -ne 0 ] && [ "${FORCE:-0}" != "1" ]; then
 echo "STOP: the Pi has a mix of old and new files (an earlier run did not finish)."
 echo "Put the old ones back first with the restore.sh of the backup made before the first run (ls -d $BACKUPS/pre-$LABEL-*)."
 echo "FORCE=1 installs over the mix: its backup then holds the mix, and a failed install would start that again."
 exit 1
fi
calman_free || exit 1

BK=$BACKUPS/pre-$LABEL-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BK" && : > "$BK/BACKED_UP" || { echo "STOP: cannot create $BK"; exit 1; }
backup_one() {
 [ -e "$1" ] || return 0
 mkdir -p "$BK$(dirname "$1")" && cp -p "$1" "$BK$1" && [ "$(md5 "$BK$1")" = "$(md5 "$1")" ] \
  && echo "$1" >> "$BK/BACKED_UP" && return 0
 echo "STOP: backup of $1 failed"; return 1
}
each backup_one || exit 1
# restore.sh runs the copies in the backup, so it works without this bundle.
SELF="$D/$(basename "$0")"
if ! { cp -p "$SELF" "$BK/pi_deploy.sh" && [ "$(md5 "$BK/pi_deploy.sh")" = "$(md5 "$SELF")" ] \
   && cp -p "$D/pi_calman_busy.sh" "$BK/pi_calman_busy.sh" && [ "$(md5 "$BK/pi_calman_busy.sh")" = "$(md5 "$D/pi_calman_busy.sh")" ] \
   && cp -p "$D/MANIFEST" "$BK/MANIFEST" && [ "$(md5 "$BK/MANIFEST")" = "$(md5 "$D/MANIFEST")" ] \
   && cp -p "$D/LABEL" "$BK/LABEL" \
   && printf '#!/bin/sh\n# Puts the files of %s back and restarts the daemon.\nexec sh %s/pi_deploy.sh --restore %s\n' "$BK" "$BK" "$BK" > "$BK/restore.sh" \
   && [ -s "$BK/restore.sh" ]; }; then
 echo "STOP: could not write pi_deploy.sh, pi_calman_busy.sh, MANIFEST and restore.sh into $BK"; exit 1
fi
echo "Backup: $BK (restore: sh $BK/restore.sh)"

install_one() {
 if [ -e "$1" ]; then
  mode=$(stat -L -c %a "$1" 2>/dev/null || echo 644)
  owner=$(stat -L -c %u:%g "$1" 2>/dev/null || echo 0:0)
 else
  mode=$(stat -c %a "$D/files$1" 2>/dev/null || echo 644)
  owner=0:0
  mkdir -p "$(dirname "$1")" || { echo "  FAILED    $1 (mkdir)"; return 1; }
 fi
 tmp="$1.new.$$"
 if cp "$D/files$1" "$tmp" && [ -s "$tmp" ] && chmod "$mode" "$tmp" && chown "$owner" "$tmp" && mv -f "$tmp" "$1" && [ "$(md5 "$1")" = "$3" ]; then
  echo "  installed $1"; return 0
 fi
 rm -f "$tmp"; echo "  FAILED    $1"; return 1
}
selftest_free || { echo "Nothing changed; $BK holds the files as they are."; exit 1; }
# Fresh stamp right before the stop; from here on roll_back and
# start_and_wait set the pause, not finish(). The trap comes first: while
# finish() still owns the pause, an interrupt only gives it back.
if ! pause_now; then
 echo "STOP: cannot pause the WebUI watchdog ($PAUSE); nothing installed"; exit 1
fi
trap 'trap "" INT TERM HUP QUIT; [ $PAUSE_OWNED -eq 1 ] && { echo "Interrupted before the daemon was stopped: nothing changed."; exit 1; }; echo "Interrupted: putting the backup back."; roll_back; exit 1' INT TERM HUP QUIT
PAUSE_OWNED=0
"$INIT" stop
sleep 1
if ! each install_one; then
 echo "Install failed: putting the backup back."
 trap "" INT TERM HUP QUIT
 roll_back
 exit 1
fi
sync
# Installed: an interrupt from here on starts the daemon if it is not yet
# started and must not leave the watchdog paused.
trap 'trap "" INT TERM HUP QUIT; [ $STARTED -eq 1 ] || start_daemon; rm -f $PAUSE; echo "Interrupted after the install: the new files are in place and the daemon start was requested, not confirmed. Run sh $SELF again: it reports."; exit 1' INT TERM HUP QUIT
echo "$LIST" | grep -q '\.ko ' && echo "Note: a kernel module is among the files; it loads on the next reboot."
echo "Daemon starting; waiting for ports 80, 85, 2100, 2101 ..."
if start_and_wait; then echo "Daemon up (all four ports listen)."; exit 0; fi
echo "WARNING: not all ports listen after 40 s; see $T/pgen-restart.log and /tmp/pgenerator_debug.log"
exit 1
