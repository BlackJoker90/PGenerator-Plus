#!/bin/sh
# Is a Calman (or other client) session using the PGenerator+ Pi right now?
# Run ON THE PI: copy it to /root/pi_calman_busy.sh, then ssh "sh /root/pi_calman_busy.sh".
# Prints BUSY or FREE plus the reasons and
# exits 1 for BUSY, 0 for FREE. Any doubt counts as BUSY.
#
# Why three checks: Calman's G1 source talks RPC on port 2101 (the classic
# source on 2100), and after a daemon restart its socket is gone although
# Calman still shows the device as connected until its next command. A
# socket snapshot alone therefore misses live sessions.
LOG=/tmp/pgenerator_debug.log
RECENT=${RECENT:-900}        # seconds of client activity that count as "in use"
ME=$(echo "$SSH_CLIENT" | cut -d' ' -f1)   # the Mac running this check
now=$(date +%s)
busy=0

# 1. Established sockets of the daemon on any port except the WebUI (80),
#    from any peer but this Mac.
socks=$(ss -tnp state established 2>/dev/null | grep 'PGene' | awk '{print $3, $4}' |
        grep -v ':80 ' | grep -v "^[^ ]* $ME:" )
if [ -n "$socks" ]; then
 busy=1
 echo "socket: $socks"
fi

if [ -s "$LOG" ]; then
 clean=$(tr -d '\002\003' < "$LOG" | grep -a 'ProxyDaemon\]' | tail -20000)
 # 2. Last INIT (session start) newer than the last close from a foreign
 #    peer: the session was never closed, a restart may have cut the socket.
 last_init=$(echo "$clean" | grep -a 'ascii=\[INIT:' | tail -1 | cut -d' ' -f1)
 last_close=$(echo "$clean" | grep -a 'Pattern socket close: type=\(rpc\|calman\)' | grep -v "peer=$ME " | tail -1 | cut -d' ' -f1)
 if [ -n "$last_init" ] && [ "${last_close:-0}" -lt "$last_init" ]; then
  busy=1
  echo "session: INIT at $last_init ($((now-last_init)) s ago) with no close since"
 fi
 # 3. Any Calman/RPC traffic in the last $RECENT seconds.
 last_cmd=$(echo "$clean" | grep -a 'Calman' | tail -1 | cut -d' ' -f1)
 if [ -n "$last_cmd" ] && [ $((now-last_cmd)) -lt "$RECENT" ]; then
  busy=1
  echo "activity: last Calman log line $((now-last_cmd)) s ago"
 fi
else
 busy=1
 echo "log: $LOG missing or empty, cannot rule out a session"
fi

if [ "$busy" = 1 ]; then echo BUSY; exit 1; fi
echo FREE
exit 0
