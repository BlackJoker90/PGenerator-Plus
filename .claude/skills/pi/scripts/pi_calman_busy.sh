#!/bin/sh
# Is a Calman (or other client) session using the PGenerator+ Pi right now?
# Run ON THE PI: copy it to /root/pi_calman_busy.sh, then ssh "sh /root/pi_calman_busy.sh".
# Prints BUSY or FREE plus the reasons (with the log line behind each) and
# exits 1 for BUSY, 0 for FREE. Any doubt counts as BUSY.
#
# Why several checks: Calman's G1 source talks RPC on port 2101 (the classic
# source on 2100, its closes logged as "type=classic"), and after a daemon
# restart its socket is gone although Calman still shows the device as
# connected until its next command. A socket snapshot alone therefore misses
# live sessions.
#
# Only client traffic counts as activity. Not every log line that says
# "Calman" is a client: "Calman G1: basic_alignment ..." is the alignment
# plate the daemon draws at every start, "Calman GCI: suppressed save ..."
# comes from WebUI/API config posts. Our own probes (127.0.0.1, this Mac)
# do not count either.
LOG=${LOG:-/tmp/pgenerator_debug.log}
PATCHLOG=${PATCHLOG:-/var/log/PGenerator/calman-patches.log}
INFO_URL=${INFO_URL:-http://127.0.0.1/api/info}
RECENT=${RECENT:-900}        # seconds of client activity that count as "in use"
PATCHTAIL=${PATCHTAIL:-2000} # patch log lines read (a patch every ~2.5 s)
ME=${ME:-$(echo "$SSH_CLIENT" | cut -d' ' -f1)}   # the Mac running this check
now=${NOW:-$(date +%s)}
since=$((now-RECENT))
busy=0
reason() { busy=1; echo "$1"; }

# A peer is ours when it is the Pi itself or the Mac running this check.
OWN="127.0.0.1 ::1 $ME"

# 1. Established sockets on the pattern ports, each with its port's protocol,
#    its idle time (ss -i lastrcv) and whether keepalive probes the peer
#    (ss -o timer:keepalive; the daemon sets it since the session tracking).
#    A socket with no data for longer than $RECENT s and no keepalive is a
#    leftover of a peer that vanished without closing (VM paused, ColourSpace
#    killed): reported as STALE, not as in use. A socket with keepalive has a
#    live peer even when idle (Calman sends nothing between patterns).
proto_of() { case "$1" in 85) echo "classic (ColourSpace/HCFR/DeviceControl)";; 2100) echo "Calman UPGCI";; 2101) echo "Calman G1 RPC";; *) echo "port $1";; esac; }
socks=$(ss -tnoi state established 2>/dev/null | awk -v own="$OWN" '
 BEGIN { n=split(own,o," "); for(i=1;i<=n;i++) mine[o[i]]=1 }
 /^[ \t]/ { if(cur!="") { idle=-1; if(match($0,/lastrcv:[0-9]+/)) idle=int(substr($0,RSTART+8,RLENGTH-8)/1000); print cur, idle; cur="" } next }
 { cur=""; l=$3; p=$4; lp=l; sub(/.*:/,"",lp)
   if(lp!="85" && lp!="2100" && lp!="2101") next
   ip=p; sub(/^\[?(::ffff:)?/,"",ip); sub(/\]?:[0-9]+$/,"",ip)
   if(ip in mine) next
   ka=($0 ~ /timer:\(keepalive/) ? "keepalive" : "no-keepalive"
   cur=lp" "p" "ka }')
stale_ips=""
live_ips=""
if [ -n "$socks" ]; then
 while read lp peer ka idle; do
  [ -z "$lp" ] && continue
  ip=$(echo "$peer" | sed -e 's/^\[\{0,1\}\(::ffff:\)\{0,1\}//' -e 's/\]\{0,1\}:[0-9]*$//')
  what="$(proto_of "$lp") port $lp peer $peer, no data for ${idle} s, $ka"
  if [ "$ka" = "no-keepalive" ] && [ "${idle:--1}" -gt "$RECENT" ]; then
   echo "STALE socket (not in use): $what"
   stale_ips="$stale_ips $ip"
  else
   reason "socket: $what"
   live_ips="$live_ips $ip"
  fi
 done <<EOF_SOCKS
$socks
EOF_SOCKS
fi

# 2. The daemon's own view. Since the session tracking /api/info lists one
#    entry per session ("sessions"), each with port and protocol: that list
#    decides. An older daemon only has the client ip/software: it counts
#    unless every socket from that ip is STALE.
info=$(curl -s -m 5 "$INFO_URL" 2>/dev/null)
if [ -z "$info" ]; then
 # With the daemon down (none of its ports listens, and ss could say so)
 # there is no socket and no session list; a session cut by the stop or a
 # crash still shows in the log checks below.
 lst=$(ss -ltn 2>/dev/null)
 if echo "$lst" | grep -q "Local Address" && ! echo "$lst" | grep -Eq "[:.](80|85|2100|2101)[[:space:]]"; then
  echo "info: daemon down (nothing listens on 80, 85, 2100, 2101); the log decides"
 else
  reason "info: $INFO_URL unreachable, cannot rule out a session"
 fi
else
 cal=$(echo "$info" | grep -o '"calibration":{.*"now":[0-9]*}' || echo "$info" | grep -o '"calibration":{[^}]*}')
 cal_ip=$(echo "$cal" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p' | head -1)
 if echo "$cal" | grep -q '"sessions":'; then
  sess=$(echo "$cal" | grep -o '{"software":[^}]*}' | grep -v -E "\"ip\":\"($(echo $OWN | sed 's/ /|/g'))\"")
  [ -n "$sess" ] && reason "sessions: $(echo $sess)"
 else
  case " $OWN " in
   *" $cal_ip "*) ;;
   *) if echo "$cal" | grep -q '"connected":true'; then
       case " $live_ips " in
        *" $cal_ip "*) reason "client: $cal" ;;
        *) case " $stale_ips " in
            *" $cal_ip "*) echo "STALE client (not in use): $cal, only stale sockets from $cal_ip" ;;
            *) reason "client: $cal" ;;
           esac ;;
       esac
      fi ;;
  esac
 fi
fi

if [ -s "$LOG" ]; then
 clean=$(tr -d '\002\003' < "$LOG" | grep -a 'ProxyDaemon\]' | tail -20000)
 # 3. Last INIT (session start) newer than the last close: the session was
 #    never closed, a restart may have cut the socket. Closes from this Mac
 #    do not end someone else's session.
 last_init=$(echo "$clean" | grep -a 'ascii=\[INIT:' | tail -1)
 last_init_t=$(echo "$last_init" | cut -d' ' -f1)
 last_close=$(echo "$clean" | grep -a 'Pattern socket close: type=\(rpc\|calman\|classic\)' | grep -v "peer=$ME " | tail -1 | cut -d' ' -f1)
 if [ -n "$last_init_t" ] && [ "${last_close:-0}" -lt "$last_init_t" ]; then
  reason "session: INIT $((now-last_init_t)) s ago with no close since: $last_init"
 fi
 # 4. Client traffic in the last $RECENT seconds that is not ours:
 #    - a session socket of a foreign peer closed (G1 RPC connects per
 #      request, so these come all the time while Calman works);
 #    - client commands (Calman RAW) not ended by a close of our own.
 traffic=$(echo "$clean" | awk -v since="$since" -v own="$OWN" '
  BEGIN { n=split(own,o," "); for(i=1;i<=n;i++) mine[o[i]]=1 }
  $1+0 < since+0 { next }
  /Pattern socket close: type=(rpc|calman|classic) / {
   p=""; if(match($0,/peer=[^ ]*/)) p=substr($0,RSTART+5,RLENGTH-5)
   sub(/^::ffff:/,"",p)
   if(p in mine) { open=""; next }
   last_foreign=$0; open=""; next
  }
  /Calman RAW:/ { open=$0 }
  END {
   if(last_foreign != "") print "foreign close: " last_foreign
   if(open != "") print "commands with no close of ours: " open
  }')
 [ -n "$traffic" ] && reason "activity: $traffic"
else
 reason "log: $LOG missing or empty, cannot rule out a session"
fi

# 5. Patches sent by a foreign peer in the last $RECENT seconds (the patch
#    log names the peer; replays after a restart have none).
if [ -s "$PATCHLOG" ]; then
 patch=$(tail -"$PATCHTAIL" "$PATCHLOG" | awk -F'\t' -v since="$since" -v own="$OWN" '
  BEGIN { n=split(own,o," "); for(i=1;i<=n;i++) mine[o[i]]=1 }
  $1+0 < since+0 { next }
  { p=""; for(i=2;i<=NF;i++) if($i ~ /^peer=/) p=substr($i,6)
    sub(/^::ffff:/,"",p)
    if(p != "" && !(p in mine)) last=$0 }
  END { if(last != "") print last }')
 [ -n "$patch" ] && reason "patch: $(echo "$patch" | cut -c1-160)"
fi

if [ "$busy" = 1 ]; then echo BUSY; exit 1; fi
echo FREE
exit 0
