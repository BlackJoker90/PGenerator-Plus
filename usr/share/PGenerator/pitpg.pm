#
# PiTPG protocol 2 on port 85: ColourSpace's "PiTPG" hardware entry
# connects to PGenerator+ as it does to a PiTPG. PGPiTPG.pm checks and
# answers the requests; this file is the backend that does what they ask
# with what the classic port 85 commands use (pgenerator_cmd for the
# settings, the signal gate and renderer restart for applying them,
# create_pattern_file for patches), so a PiTPG client gets the same output
# a classic ColourSpace connection gets.
#
use PGPiTPG;
use PGTestEdid ();
use PGEdidCaps ();
use PGEdidDolby ();
use PGMath ();

our %pitpg_conn=();
our %pitpg_checked=();
# The renderer's report of the first flip showing a new pattern (pid, load
# count, DRM sequence, time in us, frame period in us).
our $pitpg_presented_file="$var_dir/running/presented";
# pitpgd's receive buffer: a message and its length.
our $pitpg_buffer_max=0x100004;
# How long a patch reply waits for the flip that shows it.
our $pitpg_present_timeout=2.0;

sub pitpg_open (@) {
 my ($connection,$rest)=@_;
 $pitpg_conn{$connection}={buf=>""};
 $pitpg_clients=scalar(keys %pitpg_conn);
 # A client that stops reading must not hold the daemon: sends give up
 # after 5 s (pitpgd's SO_SNDTIMEO) and the connection closes.
 eval { $connection->setsockopt(SOL_SOCKET,SO_SNDTIMEO,pack('l!l!',5,0)) };
 &log("PiTPG: protocol 2 client peer=".($client_ip{$connection} || ""));
 &pitpg_receive($connection,$rest) if(defined($rest) && $rest ne "");
}

# Bytes from a PiTPG client: every whole message is answered in order.
sub pitpg_receive (@) {
 my ($connection,$bytes)=@_;
 my $st=$pitpg_conn{$connection};
 return if(!$st);
 if($bytes eq "") {
  &close_connection($connection,"client eof");
  return;
 }
 $st->{buf}.=$bytes;
 if(length($st->{buf}) > $pitpg_buffer_max) {
  &close_connection($connection,"PiTPG message too long");
  return;
 }
 my ($msgs,$err)=PGPiTPG::take_messages(\$st->{buf});
 foreach my $m (@$msgs) {
  $signal_gate_owner="$connection";
  $signal_refused_pending=0;
  &calibration_session_touch($connection);
  &pitpg_putback_retry();
  my ($reply,$close)=PGPiTPG::handle(&pitpg_backend($connection),$m);
  # A refusal is in the reply; nothing is left for the next one.
  $signal_refused_pending=0;
  return if(!&pitpg_send($connection,PGPiTPG::frame($reply)));
  if($close) {
   &close_connection($connection,"PiTPG bye");
   return;
  }
 }
 &close_connection($connection,"PiTPG: $err") if($err ne "");
}

# The whole reply or the connection closes. 1 when sent.
sub pitpg_send (@) {
 my ($connection,$data)=@_;
 my $off=0;
 while($off < length($data)) {
  my $n=eval { $connection->send(substr($data,$off)) };
  if(!defined($n) || $n <= 0) {
   my $why=$@ || $! || "nothing sent";
   $why=~s/\s+$//;
   &close_connection($connection,"send error: $why");
   return 0;
  }
  $off+=$n;
 }
 return 1;
}

# The client is gone (close_connection): the patch scale it chose ends with it.
sub pitpg_closed (@) {
 my ($connection,$st)=@_;
 # A refusal from here belongs to no socket (the client is gone), and no reply
 # carries it: the next Calman reply must not take it for its own.
 local $signal_gate_owner="";
 local $signal_refused_pending=0;
 &log("PiTPG: client closed peer=".($client_ip{$connection} || ""));
 # As pitpgd: when no PiTPG client is left, the client's patch depth and
 # scale end. pitpgd leaves the output as it is until the next apply; here
 # the output follows the conf again at once, so the cable shows what the
 # WebUI does.
 $pitpg_clients=scalar(grep { $_ ne "$connection" } keys %pitpg_conn);
 my $put_back=&pitpg_putback_retry();
 if(!$pitpg_clients) {
  my $n=&pitpg_clear_patch_state() || 0;
  # The DV keys the session changed go back (in any signal mode).
  my @back=&pitpg_session_back(\%pitpg_session_before);
  if(!@back || &pitpg_conf_write(@back)) {
   $n+=@back/2;
   %pitpg_session_before=();
   &pitpg_client_values_store();
  }
  # The client's settings end with it: a new session reads the conf.
  %pitpg_settings=();
  # Settings still not put back must not become the output through what follows.
  if(!$put_back) {
   &log("PiTPG: refused settings still not put back; the output stays as it is");
   return;
  }
  # Dolby Vision goes back to the form other sessions get (no client
  # counted now: normalize_dv_transport_conf clears the PiTPG-only keys and
  # pins the container), at once.
  my @keys=qw(dv_profile primaries dv_signal_range dv_ll_rgb dv_pq_source color_format max_bpc rgb_quant_range);
  my %before=map { ($_ => $pgenerator_conf{$_} // "") } @keys;
  &normalize_dv_transport_conf();
  &pitpg_signal_cache_drop();
  $n+=scalar(grep { ($pgenerator_conf{$_} // "") ne $before{$_} } @keys);
  &pitpg_apply_output("PiTPG client closed") if($n);
 }
}

###############################################
#              Simple requests                #
###############################################
sub pitpg_hello (@) {
 my $model=&read_from_file("/proc/device-tree/model");
 $model=~s/\x00.*//s;
 $model=~s/^\s+|\s+$//g;
 my $host=&read_from_file($hostname_file);
 $host=~s/^\s+|\s+$//g;
 return {model=>$model,hostname=>$host,server=>"$version_plus $version"};
}

# Why nothing can be shown, in the order pitpgd checks: the link was
# interrupted during a run, no display, refused settings. () when it can.
# pitpgd's link alert: an HDMI link event during a run is returned to the
# patches that follow until 2 s after it was first reported.
our %pitpg_link_alert_seen=();
our $pitpg_link_alert_ms=2000;
sub pitpg_refusal (@) {
 my @ev=&hdmi_link_events();
 if(@ev && ($ev[-1]{during} // "") ne "") {
  my $e=$ev[-1];
  my $now=Time::HiRes::time();
  my $first=$pitpg_link_alert_seen{$e->{id}} //= $now;
  if(($now-$first)*1000 < $pitpg_link_alert_ms) {
   my @t=localtime($e->{time} || 0);
   my $what=$e->{text} ne "" ? $e->{text} : $e->{event};
   return ("link_interrupted",sprintf("The HDMI link to the display was interrupted at %02d:%02d:%02d (%s). The display may have reset; run the measurements again from the start.",$t[2],$t[1],$t[0],$what));
  }
 }
 if(!&hdmi_sink_connected()) {
  return ("no_display","No display is connected to the HDMI port of the Pi (or it is off), so nothing can be shown.");
 }
 my $why=&signal_patches_refused();
 return ("settings_not_applied","The current settings could not be applied, so nothing is shown. $why") if($why ne "");
 return ();
}

# Texts of hdmi_info, edid_info, log, kernel_log and infoframes, in
# pitpgd's formats (v1-layer.md 1.7, 1.8, 4).
sub pitpg_text (@) {
 my $op=shift;
 return ("",&pitpg_hdmi_info()) if($op eq "hdmi_info");
 return ("",&pitpg_edid_info()) if($op eq "edid_info");
 if($op eq "log") {
  # pitpgd keeps the last 300 lines.
  my $tail=&pitpg_file_tail($log_file,262144);
  my @l=split(/\n/,$tail);
  # A tail cut from a longer file starts inside a line.
  shift(@l) if(@l && (-s $log_file || 0) > length($tail));
  @l=@l[-300..-1] if(@l > 300);
  return ("",join("",map { "$_\n" } @l));
 }
 if($op eq "kernel_log") {
  # The kernel ring buffer as klogctl reads it (<N> priority prefixes),
  # its last 49152 bytes as pitpgd returns.
  my $t=`timeout 3 $dmesg -r 2>/dev/null`;
  $t=`timeout 3 $dmesg 2>/dev/null` if(!defined($t) || $t eq "" || $?);
  return ("failed","The kernel log could not be read.") if(!defined($t) || $t eq "" || $?);
  $t=substr($t,-49152) if(length($t) > 49152);
  return ("",$t);
 }
 return ("",&pitpg_infoframes()) if($op eq "infoframes");
 return ("unsupported","No text for $op.");
}

# The output's format and range from the conf that sets them (in Dolby
# Vision normalize_dv_transport_conf keeps it true): get_state's word, the
# hdmi_info word, the range.
sub pitpg_output_format (@) {
 my $cf=int($pgenerator_conf{"color_format"} || 0);
 my %format=(1=>["ycc444","YCbCr444"],2=>["ycc422","YCbCr422"],3=>["ycc420","YCbCr420"]);
 my ($state,$info)=@{$format{$cf} || ["rgb","RGB"]};
 return ($state,$info,($cf == 0 && &effective_rgb_quant_range() == 2) ? "full" : "limited");
}

# "MODETEST (<mode index>) <fmt> <range> <aspect>, WxH @ hz Hz,
# progressive|interlaced, up to N-bit" and pitpgd's clauses: mode, aspect
# and scan from the connector state get_hdmi_info reads back (it says
# "60.00HzHz" on KMS).
sub pitpg_hdmi_info (@) {
 return "No display connected" if(!&hdmi_sink_connected());
 my $r=&get_hdmi_info() // "";
 if($r!~/MODETEST \((\d+)\) (\S+) (\S+) (\S+)\], (\d+x\d+) \@ ([\d.]+)(?:Hz)+, (\w+)/) {
  &log("PiTPG: hdmi_info could not read the mode from: $r");
  return "No display connected";
 }
 my ($idx,undef,undef,$aspect,$size,$hz,$scan)=($1,$2,$3,$4,$5,$6,$7);
 # Format and range as get_state: the connector's "active color format" can
 # stay 0 with YCbCr on the wire (Pi: AVI 52, dmesg "color format 1").
 my (undef,$fmt,$range)=&pitpg_output_format();
 my $bpc=&pitpg_wire_bpc();
 my $t=sprintf("MODETEST (%d) %s %s %s, %s @ %.2fHz, %s, up to %d-bit",$idx,$fmt,$range,$aspect,$size,$hz,$scan,$bpc);
 $t.=" ($bpc-bit link: 8/10-bit patch values sent exactly)" if($bpc > 10);
 my (undef,$raw)=&pitpg_edid();
 my ($dvmax)=&pitpg_display_luminance($raw);
 if(&pitpg_dv_ll()) {
  # pitpgd hdmi_info: "(BT.2020 container)" only with VSIF PB5 bit 4. The
  # kernel's packer sends PB5 0; the patched vc4.ko sets the bit when the
  # VSVDB declares Low-Latency-HDMI (dv_ll_bt2020, dv_vsif_conf_for_vsvdb).
  my $bt2020=(($pgenerator_conf{"dv_ll_bt2020"} // "") eq "1" && &webui_vc4_dv_vsif_forms()) ? 1 : 0;
  $t.=", Dolby Vision Low-Latency (".($bt2020 ? "BT.2020 container" : "display's own colour container").")";
 } elsif(&pitpg_dv_tv_led()) {
  my $map=$pgenerator_conf{"dv_map_mode"} // "";
  $t.=sprintf(", Dolby Vision TV-led (12-bit YCbCr 4:2:2 %s range in RGB tunnel, %s container%s)",
              &pitpg_dv_full() ? "full" : "limited",&pitpg_dv_container_2020() ? "BT.2020" : "P3-D65",
              $map eq "2" ? ", Calibrate: relative" : ($map eq "1" ? ", Verify: absolute" : ""));
 }
 $t.=sprintf(", display declares a %.0f cd/m2 peak",$dvmax) if(&legacy_external_dv_active() && $dvmax > 0);
 $t.=", TEST EDID in use (not the display's own)" if(PGTestEdid::test_edid_active());
 return $t;
}

# pitpgd GET_EDID_INFO: connector, hex dump (16 bytes a line, a blank line
# after each block), a rule, the decoded EDID, at most 11000 characters,
# returned base64-encoded (as pitpgd's protocol 2 reply carries it).
sub pitpg_edid_info (@) {
 my ($port,$raw)=&pitpg_edid();
 my $t=($port ne "" ? $port : "HDMI-A-1")."\n";
 if($raw eq "") {
  $t.="No info available";
 } else {
  for(my $i=0;$i<length($raw);$i+=16) {
   $t.=join(" ",map { sprintf("%02x",$_) } unpack("C*",substr($raw,$i,16)))."\n";
   $t.="\n" if(($i+16) % 128 == 0);
  }
  my $tmp="$info_dir/PITPG_EDID.bin";
  &write_file("$tmp.TMP",$tmp,$raw);
  $t.="\n----------------\n\n".&parse_edid($tmp);
  unlink($tmp);
 }
 $t=substr($t,0,11000)."\n(truncated)" if(length($t) > 11000);
 return encode_base64($t,"");
}

# pitpgd's infoframes text: a line per frame, "%-8s" and its bytes in
# hex, the AVI one decoded. From DRM debugfs when it is readable (as
# pitpgd), else from the vc4 driver's "AVI IF / DRM IF / SPD IF" kernel
# lines (the same bytes: header, checksum, payload).
sub pitpg_infoframes (@) {
 my ($port)=&signal_connected_port();
 return "No display connected\n" if($port eq "");
 my %frame;
 foreach my $dir (sort glob("/sys/kernel/debug/dri/*/$port/infoframes")) {
  foreach my $n (qw(avi hdr_drm hdmi spd audio)) {
   my $f="$dir/$n";
   $f.="/payload" if(-d $f);
   next if(!-r $f || !open(my $fh,"<",$f));
   binmode($fh);
   my $b="";
   read($fh,$b,64);
   close($fh);
   $frame{$n}=$b;
  }
  last if(%frame);
 }
 my $source="DRM debugfs";
 if(!%frame) {
  $source="kernel log";
  my (undef,$avi,$drm,$spd)=&webui_last_infoframes();
  my %hex=(avi=>$avi,hdr_drm=>$drm,spd=>$spd);
  foreach my $n (keys %hex) {
   next if(!defined($hex{$n}) || $hex{$n} eq "");
   $frame{$n}=pack("C*",map { hex($_) } grep { $_ ne "" } split(/:/,$hex{$n}));
  }
 }
 my $t="";
 foreach my $n (qw(avi hdr_drm hdmi spd audio)) {
  if(!exists($frame{$n})) {
   $t.=sprintf("%-8s (not read)\n",$n) if($source eq "kernel log");
   $t.=sprintf("%-8s (not sent)\n",$n) if($source ne "kernel log");
   next;
  }
  my @b=unpack("C*",$frame{$n});
  if(!@b) { $t.=sprintf("%-8s (not sent)\n",$n); next; }
  $t.=sprintf("%-8s",$n).join("",map { sprintf(" %02x",$_) } @b);
  if($n eq "avi" && @b >= 6) {
   my @fmt=("RGB","YCbCr 4:2:2","YCbCr 4:4:4","YCbCr 4:2:0");
   my @q=("Default","Limited","Full","Reserved");
   my @yq=("Limited","Full","Reserved","Reserved");
   $t.=sprintf("  [%s, Q %s, YQ %s, VIC %d]",$fmt[($b[4] >> 5) & 3],@b > 6 ? $q[($b[6] >> 2) & 3] : $q[0],
               @b > 8 ? $yq[($b[8] >> 6) & 3] : "Limited",@b > 7 ? $b[7] & 0x7f : 0);
  }
  $t.="\n";
 }
 $t.="(from the $source)\n";
 return $t;
}

sub pitpg_file_tail (@) {
 my ($file,$max)=@_;
 open(my $fh,"<",$file) or return "";
 my $size=-s $fh || 0;
 seek($fh,$size-$max,0) if($size > $max);
 local $/;
 my $t=<$fh>;
 close($fh);
 return defined($t) ? $t : "";
}

###############################################
#              Renderer frames                #
###############################################
# (pid, load count, seq, time_us, period_us) of the last report, () if none.
sub pitpg_presented (@) {
 open(my $fh,"<",$pitpg_presented_file) or return ();
 my $line=<$fh>;
 close($fh);
 return () if(!defined($line) || $line!~/^(\d+) (\d+) (\d+) (\d+) (\d+)\s*$/);
 return ($1,$2,$3,$4,$5);
}

# Waits until the renderer reports the flip of the pattern written at
# $written_us (CLOCK_MONOTONIC, the clock of DRM's flip events): from the
# renderer of @before a later load, from a new renderer process a flip
# after the write (its first report can be a pattern parsed before it).
# At most $pitpg_present_timeout seconds. Returns {seq,time_us,period_us}
# of the newest report and whether it is the pattern's.
sub pitpg_wait_presented (@) {
 my ($written_us,@before)=@_;
 my $until=Time::HiRes::time()+$pitpg_present_timeout;
 my $shown=sub {
  my @n=@_;
  return 0 if(!@n);
  return $n[1] > $before[1] ? 1 : 0 if(@before && $n[0] == $before[0]);
  return $n[3] >= $written_us ? 1 : 0;
 };
 my @now;
 while(1) {
  @now=&pitpg_presented();
  last if($shown->(@now));
  if(Time::HiRes::time() >= $until) {
   &log("PiTPG: no flip reported for the new pattern within ${pitpg_present_timeout}s");
   last;
  }
  select(undef,undef,undef,0.005);
 }
 return ({seq=>@now ? $now[2] : 0,time_us=>@now ? $now[3] : 0,period_us=>@now ? $now[4] : 0},$shown->(@now));
}

sub pitpg_monotonic_us (@) {
 return PGPiTPG::monotonic_us();
}

###############################################
#                 Backend                     #
###############################################
# pitpgd's settings table (v1-layer.md 1.1): min and max of each integer
# setting. The names are PGenerator's conf keys, so each value goes to the
# conf through pgenerator_cmd as a classic CMD:SET_PGENERATOR_CONF_<KEY>
# does (min_luma in 0.0001 cd/m2 there and here); mode is a string and
# becomes mode_idx.
our %pitpg_setting_range=(eotf=>[0,3],colorimetry=>[0,15],max_luma=>[0,65535],min_luma=>[0,65535],
 max_cll=>[0,65535],max_fall=>[0,65535],color_format=>[0,3],rgb_quant_range=>[0,3],primaries=>[0,5],
 max_bpc=>[8,12],dv_status=>[0,1],dv_interface=>[0,1],dv_metadata=>[0,255],is_ll_dovi=>[0,1],
 is_std_dovi=>[0,1],is_sdr=>[0,1],is_hdr=>[0,1],dv_color_space=>[0,255],dv_profile=>[0,255],
 dv_map_mode=>[0,255],dv_minpq=>[0,4095],dv_maxpq=>[0,4095],dv_diagonal=>[0,65535]);
# What a PiTPG client set ("" = unset); state.settings shows it, the conf
# for keys no client set.
our %pitpg_settings=();
# A mode the display does not offer: the next apply is refused with it.
our $pitpg_mode_error="";
# The client's patch depth (0 none, 8, 10) and patch scale (-1 none, 0 full,
# 1 legal, 2 extended, 3 user). As in pitpgd the link follows them: an 8-bit
# patch goes out on an 8-bit link, a 10-bit one needs a 10-bit link, and
# the RGB range label follows the scale. They end with the next settings
# apply and when the last PiTPG client closes. While they are in effect the
# client's own max_bpc / rgb_quant_range are kept here and put back then.
our $pitpg_bit_depth=0;
our $pitpg_patch_range=-1;
our %pitpg_client_value=();
# The same values on disk while they are in effect: the conf holds the
# patch's depth or label, so a daemon that stops in between (crash, power)
# puts the client's own values back at its next start
# (pitpg_client_values_recover). A subdirectory: clean_files keeps it.
our $pitpg_client_values_file="$var_dir/pitpg/client-values";
# Dolby Vision keys a session changes, as they were before it (the
# operator's transport, a classic client's PQ and container, no PQ source):
# put back when the last client closes, so a session that follows (Calman,
# HCFR, the WebUI) gets the form it got before. Kept in the same file.
our @pitpg_session_keys=qw(dv_transport dv_profile dv_minpq dv_maxpq dv_pq_source);
our %pitpg_session_key=map { ($_ => 1) } @pitpg_session_keys;
our %pitpg_session_before=();
# Settings written at apply, together (pitpg_dv_kind_write).
# max_bpc and dv_interface too: their single write normalized the DV conf
# while it still held DV, over the request's own is_hdr/eotf/max_bpc.
our $pitpg_kind_keys="(?:dv_status|is_ll_dovi|is_std_dovi|color_format|rgb_quant_range|max_bpc|dv_interface)";
# The last patch (window, colours, depth): test patterns are drawn in it.
our %pitpg_last_patch=();

sub pitpg_backend (@) {
 my $connection=shift;
 return {
  hello=>sub { &pitpg_granger_prepare(); return &pitpg_hello(); },
  log=>sub {
   my $text=shift;
   &log($text);
   if($text=~/client: (.+)$/ && $1 ne "(unnamed)") {
    # The name reaches the status bar and /api/info: the same characters
    # as a classic client's name (legacy_external_set_client_name).
    (my $name=$1)=~s/[^A-Za-z0-9 ._+()\/-]//g;
    $name=~s/^\s+|\s+$//g;
    $pitpg_conn{$connection}{client}=substr($name,0,64) if($name ne "");
   }
   &pitpg_session($connection);
  },
  state=>sub { return &pitpg_state(); },
  snapshot=>sub { return &pitpg_snapshot(); },
  restore=>sub { &pitpg_restore(shift); },
  set_setting=>sub { &pitpg_session($connection); return &pitpg_set_setting(@_); },
  set_setting_direct=>sub {
   my ($k,$v)=@_;
   $pitpg_settings{$k}=$v;
   # As a value the client sends: it replaces one kept while the link
   # followed the patch scale.
   &pitpg_client_value_drop($k);
   # The range a colour format implies goes with it (pitpg_dv_kind_write).
   &pitpg_conf_set($k,$v) if($k!~/^$pitpg_kind_keys$/);
  },
  apply=>sub { return &pitpg_apply(); },
  apply_live=>sub { &pitpg_apply_live(shift); },
  refusal=>sub { return &pitpg_refusal(); },
  patch=>sub { &pitpg_session($connection); return &pitpg_patch(shift); },
  test_pattern=>sub { &pitpg_session($connection); return &pitpg_test_pattern(shift); },
  text=>sub { return &pitpg_text(shift); },
 };
}

# A session (status bar, WebUI signal lock) opens with the client's hello
# or first command, not with the bare connect (as the classic port 85).
sub pitpg_session (@) {
 my $connection=shift;
 my $name=$pitpg_conn{$connection}{client} // "";
 &calibration_session_open($connection,$name=~/ColourSpace/i ? "ColourSpace" : ($name ne "" ? "ColourSpace ($name)" : "ColourSpace"));
}

sub pitpg_conf_set (@) {
 my ($k,$v)=@_;
 &pgenerator_cmd("SET_PGENERATOR_CONF_".uc($k).":$v");
}

# The value a setting has for a client: what it set, else the conf.
# dv_profile, dv_minpq and dv_maxpq only as a client set them: unset, the
# renderer takes the container from the primaries and the PQ from the
# mastering luminance (pitpg_apply clears values other programs left).
our %pitpg_client_only=map { ($_ => 1) } qw(dv_profile dv_minpq dv_maxpq);
sub pitpg_setting_value (@) {
 my $k=shift;
 return $pitpg_settings{$k} if(exists $pitpg_settings{$k});
 return $pitpg_client_value{$k} if(exists $pitpg_client_value{$k});
 return "" if($pitpg_client_only{$k});
 my $v=$pgenerator_conf{$k};
 $v=&pg_min_luma_cmd_nits_to_wire($v) if($k eq "min_luma" && defined($v) && $v ne "");
 return defined($v) ? "$v" : "";
}

sub pitpg_conf_dv_on (@) {
 return (int($pgenerator_conf{"dv_status"} || 0) == 1 || int($pgenerator_conf{"is_ll_dovi"} || 0) == 1 ||
         int($pgenerator_conf{"is_std_dovi"} || 0) == 1) ? 1 : 0;
}

# The pairs that give the session's keys back: those that differ now.
# dv_transport goes back while DV runs only when the display's Dolby block
# is known to have the kind it names: low latency on a display without
# TV-led (or one not read, as a boot without the display) would switch to
# a tunnel the display may not take. At worst the operator's choice is
# lost: kept past the session it could later write over a transport the
# operator set since.
sub pitpg_session_back (@) {
 my $before=shift;
 my @back;
 foreach my $k (sort keys %$before) {
  next if(($pgenerator_conf{$k} // "") eq $before->{$k});
  if($k eq "dv_transport" && &pitpg_conf_dv_on()) {
   my (undef,$dv)=&signal_display_caps();
   my $kind=(lc($before->{$k}) eq "lldv") ? "low_latency" : "standard";
   next if(!$dv || $dv->{error} || !$dv->{$kind});
  }
  push(@back,$k,$before->{$k});
 }
 return @back;
}

# A key's value before the session, once (see @pitpg_session_keys).
sub pitpg_session_keep (@) {
 my $changed=0;
 foreach my $k (@_) {
  next if(!$pitpg_session_key{$k} || exists $pitpg_session_before{$k});
  $pitpg_session_before{$k}=defined($pgenerator_conf{$k}) ? "$pgenerator_conf{$k}" : "";
  $changed=1;
 }
 &pitpg_client_values_store() if($changed);
}

# A conf write the renderer reads: confirmed by the helper, or the file
# reads back as written. Memory follows the file either way (as
# normalize_conf_write: the helper's timeout can end it after the rename).
# Returns 1 or 0.
sub pitpg_conf_write (@) {
 my $ok=&normalize_conf_write("PiTPG",@_) ? 1 : 0;
 # The classic protocol answers GETs from these files (pgenerator_cmd).
 unlink(map { "$info_dir/GET_PGENERATOR_CONF_".uc($_[$_]).".info" } grep { !($_ % 2) } 0..$#_);
 unlink("$info_dir/GET_PGENERATOR_CONF_ALL.info");
 return $ok;
}

sub pitpg_client_value_drop (@) {
 my $k=shift;
 return if(!exists $pitpg_client_value{$k});
 delete $pitpg_client_value{$k};
 &pitpg_client_values_store();
}

sub pitpg_client_value_keep (@) {
 my ($k,$v)=@_;
 return if(exists $pitpg_client_value{$k});
 $pitpg_client_value{$k}=$v;
 &pitpg_client_values_store();
}

sub pitpg_client_values_store (@) {
 my $f=$pitpg_client_values_file;
 if(!%pitpg_client_value && !%pitpg_session_before) {
  unlink($f) if(-e $f);
  return 1;
 }
 (my $d=$f)=~s{/[^/]+$}{};
 mkdir($d) if(!-d $d);
 my $data=join("",map { "$_=$pitpg_client_value{$_}\n" } sort keys %pitpg_client_value).
          join("",map { "session.$_=$pitpg_session_before{$_}\n" } sort keys %pitpg_session_before);
 my $ok=open(my $fh,">","$f.tmp") ? 1 : 0;
 $ok=0 if($ok && !print $fh $data);
 $ok=0 if($ok && !close($fh));
 $ok=0 if($ok && !rename("$f.tmp",$f));
 &log("PiTPG: could not keep the client's settings in $f: $!") if(!$ok);
 return $ok;
}

# Daemon start: values a PiTPG client's patch depth or scale replaced
# when the daemon stopped go back to the conf.
sub pitpg_client_values_recover (@) {
 my $f=$pitpg_client_values_file;
 open(my $fh,"<",$f) or return 0;
 my (@pairs,%session);
 while(my $l=<$fh>) {
  push(@pairs,$1,$2) if($l=~/^(max_bpc|rgb_quant_range|dv_signal_range)=(\d*)\s*$/);
  $session{$1}=$2 if($l=~/^session\.(dv_transport|dv_profile|dv_minpq|dv_maxpq|dv_pq_source)=([\w.]*)\s*$/);
 }
 close($fh);
 push(@pairs,&pitpg_session_back(\%session));
 if(@pairs) {
  my $ok=&set_pgenerator_conf_runtime_multi(@pairs) // "";
  if($ok!~/^\Q$ok_response\E/) {
   &log("PiTPG: client settings from the last session could not be put back: $ok");
   return 0;
  }
  &log("PiTPG: client settings from the last session put back: ".join(" ",@pairs));
 }
 unlink($f);
 return 1;
}

sub pitpg_set_setting (@) {
 my ($k,$v)=@_;
 if($k eq "mode") {
  $pitpg_mode_error="";
  $pitpg_settings{mode}=$v;
  if($v eq "") {
   &pitpg_conf_set("mode_idx","");
   &invalidate_hdmi_info_cache();
   return "";
  }
  my $m=&pitpg_mode_parse($v);
  return "Mode ".substr($v,0,40)." is not in the form 3840x2160\@60.00." if(!$m);
  my $idx=&pitpg_mode_match($m);
  if($idx < 0) {
   # As pitpgd: taken now, refused when the output is applied.
   $pitpg_mode_error="The display does not offer $v (the chosen resolution and refresh rate); choose one of its modes.";
   return "";
  }
  &pitpg_conf_set("mode_idx",$idx);
  &invalidate_hdmi_info_cache();
  return "";
 }
 my $r=$pitpg_setting_range{$k};
 return "Setting $k is not known." if(!$r);
 if($v ne "") {
  return "Setting $k=".substr($v,0,40)." is not accepted ($k is $r->[0] to $r->[1])." if($v!~/^-?\d+$/ || $v < $r->[0] || $v > $r->[1]);
 }
 $pitpg_settings{$k}=$v;
 # The client's own value replaces one kept while the link followed it.
 &pitpg_client_value_drop($k);
 # The DV kind, colour format, range, depth and interface go to the conf at apply, in one write
 # with the transport (pitpg_dv_kind_write): written one at a time, each
 # normalized the DV conf with the request's other keys still old, so
 # their order in the request decided the format.
 return "" if($k=~/^$pitpg_kind_keys$/);
 &pitpg_session_keep($k);
 # pitpgd labels rgb_quant_range 3 as full (output_decide: 1 limited,
 # 0 default, else full); PGenerator+ has 0, 1 and 2.
 &pitpg_conf_set($k,($k eq "rgb_quant_range" && $v eq "3") ? "2" : $v);
 return "";
}

our @pitpg_snapshot_keys=(@signal_conf_keys,@signal_metadata_keys,qw(dv_minpq dv_maxpq dv_diagonal));
# The client's Dolby Vision flags: as it sent them in this session (one
# not sent is 0), or the conf's when it sent neither (a client that finds
# DV on). pitpgd apply_now takes the kind from the two flags alone.
sub pitpg_dv_flags (@) {
 my $sent=(exists($pitpg_settings{is_ll_dovi}) || exists($pitpg_settings{is_std_dovi})) ? 1 : 0;
 my $flag=sub {
  my $k=shift;
  return ((($pitpg_settings{$k} // "") eq "1") ? 1 : 0) if($sent);
  return int($pgenerator_conf{$k} || 0) == 1 ? 1 : 0;
 };
 return ($flag->("is_ll_dovi"),$flag->("is_std_dovi"),$sent);
}

# pitpgd output_decide for both flags (its mode 3): refused with its text.
sub pitpg_dv_both_refusal (@) {
 my (undef,$dv,undef,$raw)=&signal_display_caps();
 my $caps;
 if(($raw // "") eq "") { $caps="no EDID was read from the display"; }
 elsif(!$dv || $dv->{error}) { $caps="the display does not support Dolby Vision (no Dolby Vision block in its EDID)"; }
 elsif(!$dv->{low_latency}) { $caps="the display supports Dolby Vision TV-led only"; }
 elsif(!$dv->{standard}) { $caps="the display supports Dolby Vision Low-Latency only"; }
 else { $caps="the display supports both Dolby Vision TV-led and Low-Latency"; }
 return "Dolby Vision was requested without choosing TV-led or Low-Latency; $caps. Choose the Dolby Vision type in ColourSpace.";
}

# The DV kind, the colour format and range the client set, the transport
# (is_ll_dovi: low latency, is_std_dovi: TV-led) and, for low latency, RGB
# (dv_ll_rgb 1, as pitpgd sends low latency in the client's format) in one
# write, then one normalize. Returns "" or why the conf could not be
# written.
sub pitpg_dv_kind_write (@) {
 my ($ll,$std,$sent)=&pitpg_dv_flags();
 my %want;
 # The HDR keys too: entering DV normalized them over (is_hdr 1, eotf 2,
 # colorimetry 9); leaving it gives back the client's.
 foreach my $k (qw(dv_status color_format rgb_quant_range max_bpc dv_interface is_sdr is_hdr eotf colorimetry)) {
  next if(!exists $pitpg_settings{$k});
  # In DV (and colorimetry in HDR) the normalize writes its own: the
  # client's would be written and written over on every apply.
  next if($k=~/^(?:is_sdr|is_hdr|eotf|colorimetry)$/ && ($ll || $std));
  next if($k eq "colorimetry" && &pitpg_setting_value("is_hdr") eq "1");
  my $v=$pitpg_settings{$k};
  # pitpgd labels rgb_quant_range 3 as full; PGenerator+ has 0, 1 and 2.
  $want{$k}=($k eq "rgb_quant_range" && $v eq "3") ? "2" : $v;
 }
 if($sent) {
  $want{is_ll_dovi}="$ll";
  $want{is_std_dovi}="$std";
  # pitpgd apply_now: both flags 0 is kind 0, no Dolby Vision, whatever
  # dv_status says.
  $want{dv_status}="0" if(!$ll && !$std);
 }
 if($ll != $std) {
  $want{dv_transport}=$ll ? "lldv" : "standard";
  # TV-led: none (a later low-latency switch from the WebUI is 4:2:2).
  $want{dv_ll_rgb}=($ll && &pitpg_setting_value("color_format") eq "0") ? "1" : "";
 }
 my @pairs=map { ($_,$want{$_}) } grep { ($pgenerator_conf{$_} // "") ne $want{$_} } sort keys %want;
 my $what=($ll != $std) ? "Dolby Vision ".($ll ? "low latency".(($want{dv_ll_rgb} // "") eq "1" ? " in RGB" : "") : "TV-led") : "The colour settings";
 if(@pairs) {
  &pitpg_session_keep("dv_transport") if(exists $want{dv_transport});
  return "$what could not be set: the setting could not be written." if(!&pitpg_conf_write(@pairs));
  &log("PiTPG: $what") if($ll != $std);
 }
 &normalize_signal_mode_conf();
 &pitpg_signal_cache_drop();
 return "";
}

# A normalize may change any signal key: the classic protocol's GET cache
# (pgenerator_cmd answers from these files) goes.
sub pitpg_signal_cache_drop (@) {
 unlink(map { "$info_dir/GET_PGENERATOR_CONF_".uc($_).".info" } @signal_conf_keys,"ALL");
}

sub pitpg_snapshot (@) {
 my %conf=map { ($_ => defined($pgenerator_conf{$_}) ? "$pgenerator_conf{$_}" : "") } @pitpg_snapshot_keys;
 return {conf=>\%conf,settings=>{%pitpg_settings},client=>{%pitpg_client_value},mode_error=>$pitpg_mode_error,
         bit_depth=>$pitpg_bit_depth,patch_range=>$pitpg_patch_range};
}

sub pitpg_restore (@) {
 my $s=shift;
 return if(ref($s) ne "HASH");
 my @pairs;
 foreach my $k (@pitpg_snapshot_keys) {
  my $want=$s->{conf}{$k} // "";
  my $cur=defined($pgenerator_conf{$k}) ? "$pgenerator_conf{$k}" : "";
  push(@pairs,$k,$want) if($want ne $cur);
 }
 # Not written: memory follows the file (normalize_conf_write), a refusal in
 # place says so (the WebUI's "could not be restored"), and the keys wait for
 # pitpg_putback_retry. A key that already waits keeps the value it goes back to.
 if(@pairs && !&pitpg_conf_write(@pairs)) {
  &log("PiTPG: settings could not be put back");
  while(my ($k,$want)=splice(@pairs,0,2)) {
   $pitpg_putback_waiting{$k}={want=>exists $pitpg_putback_waiting{$k} ? $pitpg_putback_waiting{$k}{want} : $want,
                               left=>$pgenerator_conf{$k} // ""};
  }
  &pitpg_refused_restored(0);
 }
 %pitpg_settings=%{$s->{settings}};
 %pitpg_client_value=%{$s->{client}};
 &pitpg_client_values_store();
 $pitpg_mode_error=$s->{mode_error};
 $pitpg_bit_depth=$s->{bit_depth};
 $pitpg_patch_range=$s->{patch_range};
}

# What pitpg_restore could not write goes back before anything builds on it: at
# the next message of any client, and when a client closes. A key that no longer holds what the
# failed write left was set since, by someone who meant it: it stays. 1 when
# nothing is left.
our %pitpg_putback_waiting=();
sub pitpg_putback_retry (@) {
 return 1 if(!%pitpg_putback_waiting);
 my $now=&renderer_conf_read() || \%pgenerator_conf;
 foreach my $k (keys %pitpg_putback_waiting) {
  delete $pitpg_putback_waiting{$k} if(($now->{$k} // "") ne $pitpg_putback_waiting{$k}{left});
 }
 return 0 if(%pitpg_putback_waiting && !&pitpg_conf_write(map { ($_,$pitpg_putback_waiting{$_}{want}) } sort keys %pitpg_putback_waiting));
 %pitpg_putback_waiting=();
 &log("PiTPG: settings put back");
 &pitpg_refused_restored(1);
 return 1;
}

sub pitpg_refused_restored (@) {
 my $restored=shift;
 my $refused=&signal_refused_read();
 &signal_refused_set(%$refused,restored=>$restored) if($refused);
}

# The client's depth and scale end; its own max_bpc / rgb_quant_range go
# back to the conf. No apply here: the caller applies. Returns how many
# conf keys changed.
# A write the helper does not confirm leaves the client values (memory and
# file) in place for the next try or the daemon start, and returns undef.
sub pitpg_clear_patch_state (@) {
 my @pairs;
 foreach my $k (sort keys %pitpg_client_value) {
  push(@pairs,$k,$pitpg_client_value{$k}) if(($pgenerator_conf{$k} // "") ne $pitpg_client_value{$k});
 }
 if(@pairs) {
  if(!&pitpg_conf_write(@pairs)) {
   &log("PiTPG: client bit depth and range could not be put back");
   return undef;
  }
 }
 %pitpg_client_value=();
 &pitpg_client_values_store();
 &log("PiTPG: client bit depth and range cleared") if($pitpg_bit_depth || $pitpg_patch_range >= 0);
 $pitpg_bit_depth=0;
 $pitpg_patch_range=-1;
 return scalar(@pairs)/2;
}

# Settings sent and applied through the gate (as RESTARTPGENERATOR). After any
# refusal patches are refused until settings that work come (pitpgd app_blocked:
# "could not be applied, so no patterns are shown"): the output stays as it was,
# and a client must not measure one it did not choose. Settings that were applied
# end it, also where no gate ran or its check failed. The gate and a refused mode
# set the state themselves ($signal_refused_pending, this apply only); every other
# refusal is set here, over an earlier one (pitpgd keeps the latest reason). The
# protocol puts the conf back.
sub pitpg_apply (@) {
 $signal_refused_pending=0;
 my $why=&pitpg_apply_settings();
 if($why eq "") {
  &signal_refused_clear("ColourSpace chose settings that work");
  %pitpg_putback_waiting=();
  return "";
 }
 return $why if($signal_refused_pending);
 $signal_refused_pending=1;
 &signal_refused_set(source=>"ColourSpace",reason=>$why,code=>"settings",requested=>"",kept=>"",alternatives=>"",
                     restored=>%pitpg_putback_waiting ? 0 : 1,owner=>defined($signal_gate_owner) ? $signal_gate_owner : "");
 &log("Signal: ColourSpace: settings refused: $why");
 &webui_notice("Settings refused","ColourSpace: $why") if(defined &webui_notice);
 return $why;
}

sub pitpg_apply_settings (@) {
 my $not_written="The settings could not be applied: the Dolby Vision settings could not be written.";
 # The client's depth and scale end first; a put-back the helper did not
 # confirm stops the apply (the output would keep them).
 return "The settings could not be applied: the output settings from before the client's patch depth and scale could not be put back."
  if(!defined(&pitpg_clear_patch_state()));
 my ($ll_now,$std_now,$sent)=&pitpg_dv_flags();
 return &pitpg_dv_both_refusal() if($sent && $ll_now && $std_now);
 # pitpgd output_decide: low latency goes out as RGB or YCbCr 4:2:2, never
 # 4:4:4 (its texts).
 if($ll_now && &pitpg_setting_value("color_format") eq "1") {
  my (undef,$dv)=&signal_display_caps();
  my $rgb=($dv && !$dv->{error} && ($dv->{interface} || "")=~/Low-Latency-HDMI/ && ($dv->{ycc444} || "none") ne "none") ? 1 : 0;
  return $rgb ? "Dolby Vision Low-Latency is sent as RGB or YCbCr 4:2:2, not YCbCr 4:4:4. Set Colour Format in Hardware Options to RGB or YCbCr 4:2:2."
              : "Dolby Vision Low-Latency is sent as YCbCr 4:2:2 on this display, not YCbCr 4:4:4. Set Colour Format in Hardware Options to YCbCr 4:2:2, or choose another TPG Mode.";
 }
 my $ll_rgb_why=&pitpg_ll_rgb_limited_refused($ll_now,&pitpg_setting_value("color_format") eq "0",
                                              &pitpg_setting_value("rgb_quant_range"));
 return $ll_rgb_why if($ll_rgb_why ne "");
 if($pitpg_mode_error ne "") {
  # As a refusal of the signal gate: patches are refused until settings
  # that work come (the protocol puts the conf back).
  $signal_refused_pending=1;
  &signal_refused_set(source=>"ColourSpace",reason=>$pitpg_mode_error,code=>"mode",requested=>$pitpg_settings{mode} // "",kept=>"",alternatives=>"",
                      restored=>%pitpg_putback_waiting ? 0 : 1,owner=>defined($signal_gate_owner) ? $signal_gate_owner : "");
  &log("Signal: ColourSpace asked for mode ".($pitpg_settings{mode} // "").": refused: $pitpg_mode_error");
  &webui_notice("Settings refused","ColourSpace asked for ".($pitpg_settings{mode} // "").". $pitpg_mode_error") if(defined &webui_notice);
  return $pitpg_mode_error;
 }
 my $kind_why=&pitpg_dv_kind_write();
 return $kind_why if($kind_why ne "");
 # As pitpgd's config: a DV container or PQ no client set is unset, so the
 # renderer derives it (main.cpp). Values another program wrote go.
 # dv_pq_source "luma": without dv_minpq/dv_maxpq the PQ comes from the
 # mastering luminance (pitpgd apply_now), only in a PiTPG session.
 # Only for a Dolby Vision output, the one place the renderer reads them: outside
 # it the write would restart the renderer, at this apply and at the close. The
 # conf says so now: dv_status alone becomes Dolby Vision in the normalize above.
 my @unset;
 if(&pitpg_conf_dv_on()) {
  @unset=map { ($_,"") } grep { !exists($pitpg_settings{$_}) && ($pgenerator_conf{$_} // "") ne "" } sort keys %pitpg_client_only;
  push(@unset,"dv_pq_source","luma") if(($pgenerator_conf{"dv_pq_source"} // "") ne "luma");
 }
 &pitpg_session_keep(map { $unset[$_] } grep { !($_ % 2) } 0..$#unset);
 if(@unset && !&pitpg_conf_write(@unset)) {
  &log("PiTPG: could not write ".join(",",map { $unset[$_] } grep { !($_ % 2) } 0..$#unset));
  return $not_written;
 }
 &log("PiTPG: ".join(",",map { $unset[$_] } grep { !($_ % 2) } 0..$#unset)." written for the session") if(@unset);
 return &pitpg_apply_output("PiTPG settings");
}

sub pitpg_apply_output (@) {
 my $who=shift;
 if(!$is_kms || &signal_gate_conf(&signal_source_label("ColourSpace"))) {
  &pattern_generator_restart_unless_current($who);
  # The renderer started or was found on the conf, with what waited in it.
  %pitpg_live_waiting=();
  return "";
 }
 return "Refused: ".&signal_patches_refused();
}

# HDR metadata: in place while HDR10/HLG is on (not Low-Latency DV), as
# pitpgd; otherwise it waits for the next apply. While patches are refused it
# waits too (pitpgd app_hdr_meta_changed returns while blocked): the gate would
# pass on the output that was kept and end the refusal. Its keys are noted: here
# a refusal can end without an apply, when its owner closes (pitpgd's does not).
our %pitpg_live_waiting=();
sub pitpg_apply_live (@) {
 my $keys=shift;
 return if(int($pgenerator_conf{"is_hdr"} || 0) != 1 || int($pgenerator_conf{"is_ll_dovi"} || 0) == 1);
 if(&signal_patches_refused() ne "") {
  $pitpg_live_waiting{$_}=1 foreach(@$keys);
  return;
 }
 if(!$is_kms || &signal_gate_conf(&signal_source_label("ColourSpace"))) {
  my %changed=map { ($_ => 1) } grep { $PGPiTPG::LIVE_KEY{$_} } @$keys;
  &pattern_generator_restart_unless_current("PiTPG HDR metadata") if(!&renderer_reconfigure_in_place(\%changed));
  &log("PiTPG: HDR metadata updated");
 }
}

# A socket closed (daemon.pm close_connection), which can end a refusal without
# an apply: the metadata that waited goes out, unless the renderer already has
# it (another program's apply). Still refused: pitpg_apply_live notes it again.
# A refusal from here belongs to no socket, and no reply carries it.
sub pitpg_live_catch_up (@) {
 return if(!%pitpg_live_waiting);
 # Nothing goes out on settings still not put back: the keys stay noted.
 return if(!&pitpg_putback_retry());
 my @keys=sort keys %pitpg_live_waiting;
 %pitpg_live_waiting=();
 return if(&renderer_started_conf_current());
 local $signal_gate_owner="";
 local $signal_refused_pending=0;
 &pitpg_apply_live(\@keys);
}

###############################################
#                  Modes                      #
###############################################
# pitpgd's mode_parse: "WxH@Hz" or "WxHi@Hz", W and H 64..16384, Hz 1..1000.
sub pitpg_mode_parse (@) {
 my $s=shift;
 return undef if(!defined($s) || $s!~/^(\d+)x(\d+)(i?)\@(\d+(?:\.\d+)?)$/);
 my ($w,$h,$i,$hz)=($1+0,$2+0,$3 eq "i" ? 1 : 0,$4+0);
 return undef if($w < 64 || $w > 16384 || $h < 64 || $h > 16384 || $hz < 1 || $hz > 1000);
 return {w=>$w,h=>$h,interlaced=>$i,hz=>$hz};
}

# Modes of the first connected connector in modetest -c output: index,
# size, interlace, hz = clock kHz * 1000 / (htotal * vtotal) as pitpgd
# computes it, and the modetest type (preferred, userdef, driver).
sub pitpg_modes_parse (@) {
 my $out=shift;
 my @modes=();
 my $in=0;
 foreach my $l (split(/\n/,defined($out) ? $out : "")) {
  if($l=~/^\d+\s+\d+\s+(connected|disconnected|unknown)\s/) {
   last if($in);
   $in=($1 eq "connected") ? 1 : 0;
   next;
  }
  next if(!$in);
  next if($l!~/^\s*#(\d+)\s+(\d+)x(\d+)(i?)\s+([\d.]+)\s+\d+\s+\d+\s+\d+\s+(\d+)\s+\d+\s+\d+\s+\d+\s+(\d+)\s+(\d+)\s+flags:[^;]*;\s*type:\s*(.*)$/);
  my ($idx,$w,$h,$i,$refresh,$htot,$vtot,$clock,$type)=($1,$2,$3,$4,$5,$6,$7,$8,$9);
  my $hz=($htot && $vtot) ? $clock*1000/($htot*$vtot) : $refresh+0;
  push(@modes,{idx=>$idx+0,w=>$w+0,h=>$h+0,interlaced=>$i eq "i" ? 1 : 0,hz=>$hz,clock_khz=>$clock+0,
               preferred=>($type=~/preferred/) ? 1 : 0,userdef=>($type=~/userdef/) ? 1 : 0});
 }
 return @modes;
}

sub pitpg_modes (@) {
 my $out=`timeout 3 $modetest -c 2>/dev/null`;
 return &pitpg_modes_parse($out);
}

sub pitpg_mode_describe (@) {
 my $m=shift;
 return sprintf("%dx%d%s\@%.2f",$m->{w},$m->{h},$m->{interlaced} ? "i" : "",$m->{hz});
}

# Exact size and interlace, |hz difference| < 0.005 (pitpgd apply_now).
# pitpgd takes the first match or a later preferred one; here the EDID's
# copy of a timing also wins over the userdef boot mode (which goes out
# with VIC 0 and a full-range AVI infoframe, see calman_find_mode_idx).
# -1 when none.
sub pitpg_mode_match (@) {
 my ($want,@modes)=@_;
 @modes=&pitpg_modes() if(!@modes);
 my ($found,$score)=(-1,-1);
 foreach my $m (@modes) {
  next if($m->{w} != $want->{w} || $m->{h} != $want->{h} || $m->{interlaced} != $want->{interlaced});
  next if(abs($m->{hz}-$want->{hz}) >= 0.005);
  my $sc=($m->{userdef} ? 0 : 2)+($m->{preferred} ? 1 : 0);
  ($found,$score)=($m->{idx},$sc) if($sc > $score);
 }
 return $found;
}

# The mode the renderer drives: mode_idx when set, else the preferred one.
sub pitpg_current_mode (@) {
 my @modes=@_;
 my $idx=$pgenerator_conf{"mode_idx"} // "";
 foreach my $m (@modes) { return $m if($idx ne "" && $m->{idx} == $idx); }
 foreach my $m (@modes) { return $m if($m->{preferred}); }
 return @modes ? $modes[0] : undef;
}

###############################################
#              Output and state               #
###############################################
sub pitpg_dv_tv_led (@) {
 return (int($pgenerator_conf{"dv_status"} || 0) == 1 && int($pgenerator_conf{"is_std_dovi"} || 0) == 1) ? 1 : 0;
}
sub pitpg_dv_ll (@) {
 return (int($pgenerator_conf{"dv_status"} || 0) == 1 && int($pgenerator_conf{"is_ll_dovi"} || 0) == 1) ? 1 : 0;
}
# Low-latency DV in RGB Limited: the codes are wire codes (DV does not
# expand them), so only a vc4 without the compression CSC (RQ3V1) sends them
# as they are. pitpgd refuses RGB Limited without its driver (its text at
# 0x488878); returns "" or the reason.
our $pitpg_ll_rgb_limited_text="RGB Limited range in Dolby Vision Low-Latency needs the patched vc4 HDMI driver, which is not loaded on this Pi. Use Full (ColourSpace sends Legal/Extended values itself).";
sub pitpg_ll_rgb_limited_refused (@) {
 my ($ll,$rgb,$range)=@_;
 return "" if(!$ll || !$rgb || $range ne "1");
 return &webui_rgb_limited_passthrough() ? "" : $pitpg_ll_rgb_limited_text;
}
# Standard DV signal range and container as the renderer reads them
# (main.cpp): dv_signal_range 2 is full; dv_profile when set (1 BT.2020),
# else the primaries (1 BT.2020), as pitpgd apply_now.
sub pitpg_dv_full (@) {
 return (($pgenerator_conf{"dv_signal_range"} // "") eq "2") ? 1 : 0;
}
sub pitpg_dv_container_2020 (@) {
 my $p=$pgenerator_conf{"dv_profile"} // "";
 return ($p ne "") ? (int($p) == 1 ? 1 : 0) : (int($pgenerator_conf{"primaries"} || 0) == 1 ? 1 : 0);
}
# Bits per component on the link as drm_override.so and the renderer
# (main.cpp applySignalConf) set it: max_bpc, at least 10 for 4:2:2, and
# 12 only in Dolby Vision. 8 or 10 for the framebuffer. Not for Dolby Vision
# TV-led, whose link is 8 whatever max_bpc holds (pitpg_wire_bpc; the
# callers ask pitpg_dv_tv_led first).
sub pitpg_link_bits (@) {
 my $bpc=int($pgenerator_conf{"max_bpc"} || 8);
 $bpc=10 if(int($pgenerator_conf{"color_format"} || 0) == 2 && $bpc < 10);
 return ($bpc >= 10) ? 10 : 8;
}

# Bits per component on the cable: the renderer's wire_bpc (12 only with
# dv_status 1), 8 for Dolby Vision TV-led's RGB tunnel.
sub pitpg_wire_bpc (@) {
 return 8 if(&pitpg_dv_tv_led());
 my $bpc=int($pgenerator_conf{"max_bpc"} || 8);
 $bpc=10 if(int($pgenerator_conf{"color_format"} || 0) == 2 && $bpc < 10);
 $bpc=10 if($bpc == 12 && int($pgenerator_conf{"dv_status"} || 0) != 1);
 return $bpc;
}

sub pitpg_signal (@) {
 return "dv_tv_led" if(&pitpg_dv_tv_led());
 return "dv_low_latency" if(&pitpg_dv_ll());
 return (int($pgenerator_conf{"eotf"} // 0) == 3 ? "hlg" : "hdr10") if(int($pgenerator_conf{"is_hdr"} || 0) == 1);
 return "sdr";
}

sub pitpg_edid (@) {
 my ($port,$file)=&signal_connected_port();
 return ("","") if($port eq "");
 my $raw=&read_from_file($file);
 return ($port,defined($raw) ? $raw : "");
}

# Display monitor name descriptor (tag 0xFC) of the base block.
sub pitpg_edid_name (@) {
 my $raw=shift;
 return "" if(length($raw) < 128);
 for(my $o=54;$o<=108;$o+=18) {
  my $d=substr($raw,$o,18);
  next if(substr($d,0,3) ne "\x00\x00\x00" || ord(substr($d,3,1)) != 0xfc);
  my $n=substr($d,5,13);
  $n=~s/\x0a.*//s;
  $n=~s/[^\x20-\x7e]//g;
  $n=~s/\s+$//;
  return substr($n,0,15);
 }
 return "";
}

# Peaks the display declares: (dv max, dv min, hdr max, hdr min) in cd/m2.
sub pitpg_display_luminance (@) {
 my $raw=shift;
 my ($dvmax,$dvmin,$hmax,$hmin)=(0,0,0,0);
 if(length($raw) >= 256) {
  my $dv=PGEdidDolby::dolby_vsvdb_from_edid($raw);
  ($dvmax,$dvmin)=($dv->{max_nits} || 0,$dv->{min_nits} || 0) if($dv);
 }
 my $caps=PGEdidCaps::edid_caps_from_raw($raw);
 ($hmax,$hmin)=($caps->{hdr_max_nits} || 0,$caps->{hdr_min_nits} || 0) if($caps);
 return ($dvmax,$dvmin,$hmax,$hmin);
}

sub pitpg_state (@) {
 my %settings;
 foreach my $k (@PGPiTPG::SETTING_KEYS) {
  my $v;
  if($k eq "mode") {
   $v=$pitpg_settings{mode};
  } else {
   $v=&pitpg_setting_value($k);
  }
  next if(!defined($v) || $v eq "");
  $settings{$k}=($k ne "mode" && $v=~/^-?\d+$/) ? PGPiTPG::num($v) : $v;
 }
 my @modes=&hdmi_sink_connected() ? &pitpg_modes() : ();
 my $cur=@modes ? &pitpg_current_mode(@modes) : undef;
 $settings{mode}=&pitpg_mode_describe($cur) if(!exists $settings{mode} && $cur);
 my $output;
 if($cur) {
  my ($format,undef,$range)=&pitpg_output_format();
  my $blocked=&signal_patches_refused();
  $output={mode=>&pitpg_mode_describe($cur),w=>PGPiTPG::num($cur->{w}),h=>PGPiTPG::num($cur->{h}),
           hz=>PGPiTPG::raw(sprintf("%.3f",$cur->{hz})),interlaced=>$cur->{interlaced} ? \1 : \0,
           format=>$format,
           bits=>PGPiTPG::num(&pitpg_wire_bpc()),
           range=>$range,
           signal=>&pitpg_signal(),depth_note=>"",blocked=>$blocked ne "" ? $blocked : undef};
 }
 my ($port,$raw)=&pitpg_edid();
 my ($dvmax,$dvmin,$hmax,$hmin)=&pitpg_display_luminance($raw);
 my %lum;
 $lum{dv}={max=>PGPiTPG::raw(sprintf("%.1f",$dvmax)),min=>PGPiTPG::raw(sprintf("%.4f",$dvmin))} if($dvmax > 0);
 $lum{hdr}={max=>PGPiTPG::raw(sprintf("%.1f",$hmax)),min=>PGPiTPG::raw(sprintf("%.4f",$hmin))} if($hmax > 0);
 my @test_edid=PGTestEdid::test_edid_active();
 my $display={connected=>($port ne "") ? \1 : \0,name=>&pitpg_edid_name($raw),test_edid=>@test_edid ? \1 : \0,
              edid=>$raw ne "" ? encode_base64($raw,"") : "",luminance=>\%lum};
 my @sorted=map { $_->[1] } sort { $b->[1]{w} <=> $a->[1]{w} || $a->[0] <=> $b->[0] } map { [$_,$modes[$_]] } 0..$#modes;
 my @mlist=map { {mode=>&pitpg_mode_describe($_),w=>PGPiTPG::num($_->{w}),h=>PGPiTPG::num($_->{h}),
                  hz=>PGPiTPG::raw(sprintf("%.3f",$_->{hz})),interlaced=>$_->{interlaced} ? \1 : \0,
                  clock_khz=>PGPiTPG::num($_->{clock_khz}),preferred=>$_->{preferred} ? \1 : \0} } @sorted;
 my @ev=&hdmi_link_events();
 my $last="";
 if(@ev) {
  my @t=localtime($ev[-1]{time} || 0);
  $last=sprintf("%02d:%02d:%02d %s (%s)",$t[2],$t[1],$t[0],$ev[-1]{text} ne "" ? $ev[-1]{text} : $ev[-1]{event},
                $ev[-1]{during} ne "" ? "during a run" : "not during a run");
 }
 return {settings=>\%settings,output=>$output,display=>$display,modes=>\@mlist,link=>{last_event=>$last}};
}

###############################################
#                  Patches                    #
###############################################
# The client's patch scale. Codes are never rescaled (pitpgd patch_pack):
# the scale picks the RGB range label; YCbCr is always limited, so a full
# scale is refused there. Returns ("") or (code,message).
sub pitpg_set_patch_range (@) {
 my $r=shift;
 my $ycc=(($pgenerator_conf{"color_format"} || "0") ne "0") ? 1 : 0;
 if(&pitpg_dv_tv_led()) {
  # As pitpgd dv_show: Full is a full-range Dolby signal (payload byte 20
  # 0, full matrices, codes 0..4095), Legal and User a limited one;
  # Extended is refused (pitpgd's text).
  return ("range","Dolby Vision TV-led has no room for Extended range values (the Pi converts patch values to Dolby's own signal). Set Patch Scale in ColourSpace Settings to Full (a full-range Dolby signal, finest steps) or Legal (a limited-range Dolby signal).") if($r == 2);
  my $want=($r == 0) ? "2" : "1";
  my $have=$pgenerator_conf{"dv_signal_range"} // "";
  if(($have eq "2" ? "2" : "1") ne $want) {
   # The renderer reads the range from the conf file: a write the helper
   # did not confirm is not taken as applied (the memory goes back too).
   # Kept first: a stop between write and keep must still give it back.
   my $kept=exists($pitpg_client_value{dv_signal_range});
   &pitpg_client_value_keep("dv_signal_range",$have);
   if(!&pitpg_conf_write("dv_signal_range",$want)) {
    # Memory reads as the file (pitpg_conf_write); a keep made here goes
    # when the file still holds the value before it.
    &pitpg_client_value_drop("dv_signal_range") if(!$kept && ($pgenerator_conf{"dv_signal_range"} // "") eq $have);
    &log("PiTPG: dolby vision: TV-led range could not be written");
    return ("settings_not_applied","The patch scale could not be applied: the Dolby Vision signal range could not be written.");
   }
   my $why=&pitpg_apply_output("PiTPG patch scale");
   return ("settings_not_applied","The patch scale could not be applied. $why") if($why ne "");
   &log("PiTPG: dolby vision: TV-led ".($want eq "2" ? "full" : "limited")."-range form");
  }
 } elsif($ycc) {
  return ("range","ColourSpace is set to Full range, but YCbCr is always sent as limited range. Set Patch Scale in ColourSpace Settings to Legal.") if($r == 0);
 } else {
  my $client=exists($pitpg_client_value{rgb_quant_range}) ? $pitpg_client_value{rgb_quant_range} : ($pgenerator_conf{"rgb_quant_range"} // "");
  my $label=($r == 0) ? "2" : (($r == 1 || $r == 2) ? "1" : $client);
  my $why=&pitpg_ll_rgb_limited_refused(&pitpg_dv_ll(),($pgenerator_conf{"dv_ll_rgb"} // "") eq "1",$label);
  return ("range",$why) if($why ne "");
  if(($pgenerator_conf{"rgb_quant_range"} // "") ne $label) {
   &pitpg_client_value_keep("rgb_quant_range",$client);
   &set_pgenerator_conf_runtime("rgb_quant_range",$label);
   my $why=&pitpg_apply_output("PiTPG patch scale");
   return ("settings_not_applied","The patch scale could not be applied. $why") if($why ne "");
   &log("PiTPG: RGB range label now follows ColourSpace: ".($label eq "2" ? "Full" : ($label eq "1" ? "Limited" : "Default")));
  }
 }
 $pitpg_patch_range=$r;
 return ("");
}

# The client's patch depth: the link follows it outside Dolby Vision.
sub pitpg_set_bit_depth (@) {
 my $bits=shift;
 $pitpg_bit_depth=$bits;
 return ("") if(&legacy_external_dv_active());
 return ("") if(&pitpg_link_bits() == $bits);
 # 4:2:2 has at least 10 bits: an 8-bit patch goes out as v << 2.
 return ("") if($bits == 8 && int($pgenerator_conf{"color_format"} || 0) == 2);
 my $client=exists($pitpg_client_value{max_bpc}) ? $pitpg_client_value{max_bpc} : ($pgenerator_conf{"max_bpc"} // "");
 &pitpg_client_value_keep("max_bpc",$client);
 &set_pgenerator_conf_runtime("max_bpc",$bits);
 my $why=&pitpg_apply_output("PiTPG bit depth");
 if($why ne "") {
  $pitpg_bit_depth=0;
  return ("bit_depth","10-bit patch, but the output cannot be 10-bit here. $why Set ColourSpace to 8-bit.") if($bits == 10);
  return ("settings_not_applied","The 8-bit output could not be applied. $why");
 }
 &log("PiTPG: client bit depth: $bits");
 return ("");
}

sub pitpg_screen (@) {
 &get_hdmi_info();
 my ($w,$h)=(int($w_s || 0),int($h_s || 0));
 return ($w > 0 && $h > 0) ? ($w,$h) : (1920,1080);
}

# The framebuffer depth codes are drawn at outside standard Dolby Vision.
sub pitpg_fb_bits (@) {
 return &pitpg_link_bits() >= 10 ? 10 : 8;
}

# pitpgd patch_pack: a code of $bits on a framebuffer of $fb bits. No
# range scaling: 8 -> 10 is v << 2, 10 -> 8 is (v + 2) >> 2 (255 from 1022).
sub pitpg_pack (@) {
 my ($v,$bits,$fb)=@_;
 return $v if($bits == $fb);
 return $v << 2 if($bits == 8 && $fb == 10);
 return $v >= 1022 ? 255 : ($v+2) >> 2;
}

# A frame: {bg=>[r,g,b], draws=>[[x,y,w,h,r,g,b] or {image,x,y,w,h}], ms}.
# Codes are wire codes at $fb bits (pitpgd never rescales them by range),
# so every draw is SOURCE_RANGE=LIMITED: the renderer then passes them on
# as they are (RGB Limited passthrough, RGB Full, YCbCr studio-range
# input). In standard Dolby Vision they go to the tunnel at their own
# depth (SOURCE_MAX 255 or 1023, BITS=8 for the 8-bit tunnel surface): the
# renderer normalises them by that depth and the signal range, as pitpgd
# dv_ycc12 (a 12-bit shift moved full-range codes and rounding ties).
sub pitpg_pattern_string (@) {
 my ($fb,$frames)=@_;
 my $dv=(&legacy_external_dv_source_max() == 4095) ? 1 : 0;
 my $scale=sub { return @_; };
 my $ps="MOVIE_NAME=TestPattern\n".($dv ? "BITS=8\nSOURCE_MAX=".((1 << $fb) - 1)."\n" : "BITS=$fb\n");
 my $n=0;
 foreach my $f (@$frames) {
  my $bg=join(",",$scale->(@{$f->{bg}}));
  my $first=1;
  foreach my $d (@{$f->{draws}}) {
   my $b=$first ? $bg : "-1,-1,-1";
   if(ref($d) eq "HASH") {
    $ps.="DRAW=IMAGE\nDIM=$d->{w},$d->{h}\nRGB=0,0,0\nBG=$b\nPOSITION=$d->{x},$d->{y}\nIMAGE=$d->{image}\nEND=1\n";
   } else {
    my ($x,$y,$w,$h,@c)=@$d;
    $ps.="DRAW=RECTANGLE\nDIM=$w,$h\nRESOLUTION=0\nRGB=".join(",",$scale->(@c))."\nBG=$b\nPOSITION=$x,$y\nTEXT=\nEND=1\n";
   }
   $first=0;
  }
  $ps.="FRAME_NAME=PiTPG_".($n++)."\nFRAME=".($f->{ms} || $frame_default)."\n";
 }
 return $ps;
}

# How the renderer reads the codes (SOURCE_RANGE). Standard DV keeps the
# source normalisation apart from the signal range, as pitpgd: dv_ycc12's
# limited flag is set for patch scale Legal only (proto_handle@0x408990),
# so Full, User and no scale normalise c / (2^b - 1), also in a limited
# signal. Other DV: unset; else wire codes (LIMITED).
sub pitpg_source_range (@) {
 return ($pitpg_patch_range == 1) ? "LIMITED" : "FULL" if(&pitpg_dv_tv_led());
 return &legacy_external_dv_active() ? "" : "LIMITED";
}

# Draws the frames and waits for the flip that shows them: that flip's
# {seq,time_us,period_us}, undef when none came (pitpgd: "could not be
# shown").
sub pitpg_show (@) {
 my ($fb,$frames)=@_;
 my $ps=&pitpg_pattern_string($fb,$frames);
 my @before=&pitpg_presented();
 my $written=&pitpg_monotonic_us();
 &clean_pattern_files();
 return undef if(!&create_tmp_file($ps,&pitpg_source_range()));
 &load_new_pattern_file("PiTPG");
 my ($frame,$shown)=&pitpg_wait_presented($written,@before);
 return $shown ? $frame : undef;
}

sub pitpg_patch (@) {
 my $p=shift;
 if($p->{range} >= 0 && $p->{range} != $pitpg_patch_range) {
  my @e=&pitpg_set_patch_range($p->{range});
  return @e if($e[0] ne "");
 }
 if($p->{bits} != $pitpg_bit_depth) {
  my @e=&pitpg_set_bit_depth($p->{bits});
  return @e if($e[0] ne "");
 }
 if($p->{bits} == 10 && !&pitpg_dv_tv_led() && &pitpg_link_bits() < 10) {
  return ("bit_depth","10-bit patch, but the output is 8-bit (max_bpc ".($pgenerator_conf{"max_bpc"} || 8)."). Set ColourSpace to 8-bit.");
 }
 my ($W,$H)=&pitpg_screen();
 my ($x,$y,$w,$h)=$p->{rect} ? @{$p->{rect}} : (0,0,$W,$H);
 # -1 centres (as pitpgd).
 $x=int(($W-$w)/2) if($x == -1);
 $y=int(($H-$h)/2) if($y == -1);
 %pitpg_last_patch=(x=>$x,y=>$y,w=>$w,h=>$h,rgb=>[@{$p->{rgb}}],bg=>[@{$p->{bg}}],bits=>$p->{bits});
 # Standard DV: the patch's own codes at its own depth.
 my $fb=&pitpg_dv_tv_led() ? $p->{bits} : &pitpg_fb_bits();
 my $frame=&pitpg_show($fb,[&pitpg_patch_frame($W,$H,$fb)]);
 return ("failed","The patch could not be shown: the renderer reported no new frame.") if(!$frame);
 &log("PiTPG: patch ".join(",",@{$p->{rgb}})." bg ".join(",",@{$p->{bg}})." $p->{bits}-bit at $x,$y ${w}x$h");
 return ("",$frame,&pitpg_peak_note($p));
}

# The last patch (black, 8-bit, full screen when none) as a frame at $fb
# bits: background, then the rect clipped to the screen.
sub pitpg_patch_frame (@) {
 my ($W,$H,$fb)=@_;
 my %lp=%pitpg_last_patch ? %pitpg_last_patch : (x=>0,y=>0,w=>$W,h=>$H,rgb=>[0,0,0],bg=>[0,0,0],bits=>8);
 my @bg=map { &pitpg_pack($_,$lp{bits},$fb) } @{$lp{bg}};
 my @fg=map { &pitpg_pack($_,$lp{bits},$fb) } @{$lp{rgb}};
 my @r=&pitpg_clip($lp{x},$lp{y},$lp{w},$lp{h},$W,$H);
 my @draws=@r ? ([@r,@fg]) : ([0,0,$W,$H,@bg]);
 return {bg=>\@bg,draws=>\@draws,ms=>$frame_default};
}

sub pitpg_clip (@) {
 my ($x,$y,$w,$h,$W,$H)=@_;
 my ($x0,$y0)=($x < 0 ? 0 : $x,$y < 0 ? 0 : $y);
 my ($x1,$y1)=($x+$w > $W ? $W : $x+$w,$y+$h > $H ? $H : $y+$h);
 return () if($x1 <= $x0 || $y1 <= $y0);
 return ($x0,$y0,$x1-$x0,$y1-$y0);
}

# pitpgd's peak note: only with HDR10 (PQ) or Dolby Vision. The brightest
# channel PQ-decoded (legal or full code range, as the scale and the
# link), against the display's declared peak (Dolby Vision block for DV,
# else the HDR block; the other one when that is missing).
sub pitpg_peak_note (@) {
 my $p=shift;
 my $dv=&legacy_external_dv_active();
 return "" if(!$dv && !(int($pgenerator_conf{"is_hdr"} || 0) == 1 && int($pgenerator_conf{"eotf"} // 0) == 2));
 my (undef,$raw)=&pitpg_edid();
 return "" if($raw eq "");
 my ($dvmax,undef,$hmax)=&pitpg_display_luminance($raw);
 my ($peak,$block)=$dv ? ($dvmax,"Dolby Vision block") : ($hmax,"HDR block");
 ($peak,$block)=$dv ? ($hmax,"HDR block") : ($dvmax,"Dolby Vision block") if($peak <= 0);
 return "" if($peak <= 0);
 my $legal;
 if(&pitpg_dv_tv_led()) {
  # The codes are read as the tunnel reads them (pitpg_source_range):
  # studio codes for scale Legal only; pitpgd proto2_handle: legal for
  # scale 1/2, else the link, which is RGB Full in TV-led.
  $legal=($pitpg_patch_range == 1) ? 1 : 0;
 } elsif($pitpg_patch_range < 0 || $pitpg_patch_range == 3) {
  $legal=(($pgenerator_conf{"color_format"} || "0") ne "0" || &effective_rgb_quant_range() == 1) ? 1 : 0;
 } else {
  $legal=($pitpg_patch_range == 1 || $pitpg_patch_range == 2) ? 1 : 0;
 }
 my $b=$p->{bits};
 my ($lo,$span)=$legal ? (16*2**($b-8),219*2**($b-8)) : (0,2**$b-1);
 my $max=0;
 foreach my $v (@{$p->{rgb}}) {
  my $e=($v-$lo)/$span;
  next if($e <= 0);
  $e=1 if($e > 1);
  my $nits=PGMath::pq_decode_nits($e);
  $max=$nits if($nits > $max);
 }
 return "" if($max <= $peak*1.005);
 return sprintf("Above the display's declared peak: patch %.0f cd/m2, display %.0f cd/m2 (its EDID's %s); the display will clip or tone-map this patch.",$max,$peak,$block);
}

###############################################
#               Test patterns                 #
###############################################
# The 12 PiTPG test patterns (v1-layer.md 3.3, decomp/testpat_level.c),
# drawn inside the last patch's window. Each level L (0..255, fractional
# for the ramps and GRANGER) becomes pitpgd's code.isra.0:
# lround(2^fb/2^bits * ((max-min) * (L/255) + min)), clamped to the
# framebuffer depth.
our @pitpg_contrast_levels=([191,199,207,215,223,231,239,247],[223,227,231,235,239,243,247,251],
                            [239,241,243,245,247,249,251,253],[247,248,249,250,251,252,253,254]);
our @pitpg_brightness_levels=([1,2,3,4,5,6,7,8],[2,4,6,8,10,12,14,15],
                              [4,8,12,16,20,24,28,32],[8,16,24,32,40,48,56,64]);
our %pitpg_test_pattern_known=map { ($_ => 1) } qw(CONTRAST BRIGHTNESS ANSI_1 ANSI_2 CORNER_BOX_1 CORNER_BOX_2
 PROBE_ALIGNMENT GRANGER RAMP_BW_HORIZ RAMP_BW_VERT FALD);

sub pitpg_level_code (@) {
 my ($l,$min,$max,$bits,$fb)=@_;
 my $c=((2**$fb)/(2**$bits))*(($max-$min)*($l/255)+$min);
 $c=int($c+0.5);
 my $top=2**$fb-1;
 return $c < 0 ? 0 : ($c > $top ? $top : $c);
}

sub pitpg_test_pattern (@) {
 my $p=shift;
 my ($W,$H)=&pitpg_screen();
 my $fb=&pitpg_fb_bits();
 my $name=uc($p->{name});
 if($p->{off} || $name eq "PATCH") {
  &log("PiTPG: test pattern off - patches again");
  my $pfb=&pitpg_dv_tv_led() ? ($pitpg_last_patch{bits} || 8) : $fb;
  my $frame=&pitpg_show($pfb,[&pitpg_patch_frame($W,$H,$pfb)]);
  return $frame ? ("",$frame) : ("failed","The patch could not be shown: the renderer reported no new frame.");
 }
 return ("failed","Unknown test pattern '$p->{name}'.") if(!$pitpg_test_pattern_known{$name});
 my $bits=$p->{bits} // 8;
 my $min=$p->{min} // 0;
 my $max=$p->{max} // 255;
 return ("failed","Test pattern levels must be min < max < ".(2**$bits).".") if($min >= $max || $max >= 2**$bits);
 return ("failed","GRANGER is not available while Dolby Vision is on here.") if($name eq "GRANGER" && &legacy_external_dv_active());
 # The window: the last patch clipped to the screen; none or empty is the
 # full screen.
 my @win=%pitpg_last_patch ? &pitpg_clip(@pitpg_last_patch{qw(x y w h)},$W,$H) : ();
 @win=(0,0,$W,$H) if(!@win);
 my ($wx,$wy,$ww,$wh)=@win;
 # pitpgd testpat_window: the DV tunnel window starts at an even x.
 if(&pitpg_dv_tv_led() && $wx % 2) { $wx--; $ww++ if($wx+$ww < $W); }
 my $code=sub { return &pitpg_level_code(shift,$min,$max,$bits,$fb); };
 my ($bgl,@rects)=&pitpg_test_rects($name,$ww,$wh,$code);
 if($name eq "GRANGER") {
  my $file=&pitpg_granger_file($ww,$wh,$min,$max,$bits,$fb);
  return ("failed","The test pattern could not be shown.") if($file eq "");
  @rects=({image=>$file,x=>0,y=>0,w=>$ww,h=>$wh});
 }
 my @bgc=($code->($bgl)) x 3;
 my $base=&pitpg_patch_frame($W,$H,$fb);
 my $full=($ww == $W && $wh == $H) ? 1 : 0;
 my @frame_bg=$full ? @bgc : @{$base->{bg}};
 my $window=[$wx,$wy,$ww,$wh,@bgc];
 # In the window only (testpat_level sets the window's pixels): a shape
 # larger than a small window is cut at its edges.
 my @pattern;
 foreach my $r (@rects) {
  if(ref($r) eq "HASH") { push(@pattern,{%$r,x=>$r->{x}+$wx,y=>$r->{y}+$wy}); next; }
  my @c=&pitpg_clip($wx+$r->[0],$wy+$r->[1],$r->[2],$r->[3],$wx+$ww,$wy+$wh);
  next if(!@c);
  my ($x0,$y0)=($c[0] < $wx ? $wx : $c[0],$c[1] < $wy ? $wy : $c[1]);
  my ($x1,$y1)=($c[0]+$c[2],$c[1]+$c[3]);
  next if($x1 <= $x0 || $y1 <= $y0);
  push(@pattern,[$x0,$y0,$x1-$x0,$y1-$y0,@$r[4..6]]);
 }
 my @frames=({bg=>\@frame_bg,draws=>[$window,@pattern],ms=>$frame_default});
 if($name eq "CONTRAST" || $name eq "BRIGHTNESS") {
  # Blink: 500 ms the cells, 500 ms the plain background.
  $frames[0]{ms}=500;
  push(@frames,{bg=>\@frame_bg,draws=>[$window],ms=>500});
 }
 &log("PiTPG: test pattern $name (levels $min-$max at $bits-bit)");
 my $frame=&pitpg_show($fb,\@frames);
 return $frame ? ("",$frame) : ("failed","The test pattern could not be shown: the renderer reported no new frame.");
}

# (background L, [x,y,w,h,r,g,b]...) in window coordinates, codes from
# $code; testpat_level.c's bounds (inclusive ends become widths).
sub pitpg_test_rects (@) {
 my ($name,$W,$H,$code)=@_;
 my @r;
 my $grey=sub { my ($x,$y,$w,$h,$l)=@_; return [$x,$y,$w,$h,($code->($l)) x 3]; };
 if($name eq "CONTRAST" || $name eq "BRIGHTNESS") {
  my $tab=$name eq "CONTRAST" ? \@pitpg_contrast_levels : \@pitpg_brightness_levels;
  my ($cw,$rh)=($W/8.0,$H*0.25);
  my ($g,$gh)=($cw*0.25,$rh*0.25);
  for my $j (0..3) {
   my $ry0=int($gh/2+$j*$rh);
   my $ry1=int($ry0+$rh-$gh);
   for my $i (0..7) {
    my $cx0=int($g/2+$i*$cw);
    my $cx1=int($cx0+$cw-$g);
    push(@r,$grey->($cx0,$ry0,$cx1-$cx0+1,$ry1-$ry0+1,$tab->[$j][$i]));
   }
  }
  return ($name eq "CONTRAST" ? 255 : 0,@r);
 }
 if($name eq "ANSI_1" || $name eq "ANSI_2") {
  my ($cw,$ch)=(int($W/4),int($H/4));
  for my $j (0..3) {
   for my $i (0..3) {
    push(@r,$grey->($i*$cw,$j*$ch,$cw,$ch,255)) if(($i+$j+($name eq "ANSI_2" ? 1 : 0)) % 2);
   }
  }
  return (0,@r);
 }
 if($name eq "CORNER_BOX_1") {
  my ($bw,$bh)=($W/5.0,$H/5.0);
  my ($x0,$y0)=(int($W*0.5-$bw*0.5),int($H*0.5-$bh*0.5));
  my ($x1,$y1)=(int($x0+$bw-1),int($y0+$bh-1));
  return (0,$grey->($x0,$y0,$x1-$x0+1,$y1-$y0+1,255));
 }
 if($name eq "CORNER_BOX_2") {
  my ($bw,$bh)=(int($W/10),int($H/10));
  return (0,map { $grey->(@$_,$bw,$bh,255) } ([0,0],[$W-$bw,0],[0,$H-$bh],[$W-$bw,$H-$bh]));
 }
 if($name eq "PROBE_ALIGNMENT") {
  my ($s,$t)=(int($W/3),int($W/30));
  my ($x0,$y0)=(int(($W-$s)/2),int(($H-$s)/2));
  return (0,$grey->($x0,$y0,$s,$s,48),$grey->($x0+$t,int($H/2),$s-2*$t,1,219),$grey->(int($W/2),$y0+$t,1,$s-2*$t,219));
 }
 if($name eq "RAMP_BW_HORIZ" || $name eq "RAMP_BW_VERT") {
  # L = x*255/W (y*255/H), not rounded before the code: neighbouring
  # columns (rows) with the same code become one strip.
  my $horiz=($name eq "RAMP_BW_HORIZ") ? 1 : 0;
  my $len=$horiz ? $W : $H;
  my ($start,$prev)=(0,undef);
  for my $i (0..$len) {
   my $c=$i < $len ? $code->($i*255.0/$len) : -1;
   if(defined($prev) && $c != $prev) {
    push(@r,$horiz ? [$start,0,$i-$start,$H,($prev) x 3] : [0,$start,$W,$i-$start,($prev) x 3]);
    $start=$i;
   }
   $prev=$c;
  }
  return (0,@r);
 }
 if($name eq "FALD") {
  my ($cw,$ch)=(int($W/16),int($H/9));
  push(@r,$grey->($_*$cw,0,1,$H,198)) for(1..15);
  push(@r,$grey->(0,$_*$ch,$W,1,198)) for(1..8);
  return (235,@r);
 }
 return (0);
}

# GRANGER (testpat_level.c id 8), per pixel: an HSL rainbow with S = 1,
# hue u = 1-(x+0.5)/W (R at u+1/3, G at u, B at u-1/3; the B offset is
# assumed in v1-layer.md), lightness v = 1-(y+0.5)/H. Written once per
# size, levels and depth as a PNG (16-bit samples round(code*65535/1023)
# for 10-bit, as the G1 10-bit plates) in the G1 cache.
sub pitpg_granger_path (@) {
 my ($W,$H,$min,$max,$bits,$fb)=@_;
 return &calman_g1_cache_dir()."/pitpg_granger_${W}x${H}_${min}_${max}_${bits}_${fb}.png";
}

# Another process is building this file: <file>.building names a living
# pid other than ours. A marker outlives a killed worker (the init script's
# pkill -9 -f matches the fork too) and its pid can come back after a
# reboot, so an old one no longer counts.
sub pitpg_granger_building (@) {
 my $file=shift;
 my $pid=&read_from_file("$file.building") // "";
 return 0 if($pid!~/^(\d+)/ || $1 == $$ || !kill(0,$1));
 my $mtime=(stat("$file.building"))[9];
 # abs: until NTP has run the clock can be behind the marker.
 return (defined($mtime) && abs(time()-$mtime) < 600) ? 1 : 0;
}

# The worker's own marker stays until its build is done: it is what keeps a
# second hello and a GRANGER request from building the same file.
sub pitpg_granger_own_marker (@) {
 my $file=shift;
 my $pid=&read_from_file("$file.building") // "";
 return ($pid=~/^(\d+)/ && $1 == $$) ? 1 : 0;
}

# Builds the file unless it is there; a build already running in a worker
# (pitpg_granger_prepare) is waited for instead of done twice.
sub pitpg_granger_file (@) {
 my ($W,$H,$min,$max,$bits,$fb)=@_;
 my $file=&pitpg_granger_path(@_);
 my $until=Time::HiRes::time()+60;
 while(!-s $file && Time::HiRes::time() < $until) {
  last if(!&pitpg_granger_building($file));
  select(undef,undef,undef,0.05);
 }
 return $file if(-s $file);
 unlink("$file.building") if(!&pitpg_granger_own_marker($file) && !&pitpg_granger_building($file));
 # Keep the cache small: one GRANGER at a time. A young .tmp.png is a
 # worker's build in progress (calman_g1_save_image), an old one its remains.
 unlink(grep { $_ ne $file && !($_=~/\.tmp\.png$/ && abs(time()-((stat($_))[9] // 0)) < 600) } glob(&calman_g1_cache_dir()."/pitpg_granger_*.png"));
 my $t0=Time::HiRes::time();
 my $img=&pitpg_granger_image($W,$H,$min,$max,$bits,$fb);
 if(!&calman_g1_save_image($img,$file,$W,$H)) {
  &log("PiTPG: GRANGER could not be written to $file");
  return "";
 }
 &log(sprintf("PiTPG: GRANGER %dx%d written in %.1f s",$W,$H,Time::HiRes::time()-$t0));
 return $file;
}

# With a client's hello: GRANGER at the default levels (0-255, 8-bit) for
# the screen is built in a worker, so the request for it does not wait
# for the per-pixel image (seconds in Perl at 2160p).
sub pitpg_granger_prepare (@) {
 return if(!defined &webui_spawn_detached || &legacy_external_dv_active());
 my ($W,$H)=&pitpg_screen();
 my @key=($W,$H,0,255,8,&pitpg_fb_bits());
 my $file=&pitpg_granger_path(@key);
 return if(-s $file || &pitpg_granger_building($file));
 &webui_spawn_detached(sub {
  if(open(my $fh,">","$file.building")) { print $fh $$; close($fh); }
  &pitpg_granger_file(@key);
  unlink("$file.building");
 });
}

sub pitpg_granger_image (@) {
 my ($W,$H,$min,$max,$bits,$fb)=@_;
 my @f=([],[],[]);
 for my $x (0..$W-1) {
  my $u=1-($x+0.5)/$W;
  push(@{$f[0]},&pitpg_hue_part(0,1,$u+1/3));
  push(@{$f[1]},&pitpg_hue_part(0,1,$u));
  push(@{$f[2]},&pitpg_hue_part(0,1,$u-1/3));
 }
 my $deep=($fb == 10) ? 1 : 0;
 my @s16=map { int($_*65535/1023+0.5) } 0..1023;
 my @cols=0..$W-1;
 my $buf="";
 for my $y (0..$H-1) {
  my $v=1-($y+0.5)/$H;
  my $q=$v < 0.5 ? 2*$v : 1;
  my $p=2*$v-$q;
  # L = 255 * hue_part(p,q,t) = 255 * (p + (q-p) * hue_part(0,1,t)).
  my @c=map { my $i=$_; map { &pitpg_level_code(255*($p+($q-$p)*$f[$_][$i]),$min,$max,$bits,$fb) } 0..2 } @cols;
  $buf.=$deep ? pack("n*",map { $s16[$_] } @c) : pack("C*",@c);
 }
 return {w=>$W,h=>$H,buf=>$buf,($deep ? (depth=>16) : ())};
}

sub pitpg_hue_part (@) {
 my ($p,$q,$t)=@_;
 $t+=1 if($t < 0);
 $t-=1 if($t > 1);
 return $p+($q-$p)*6*$t if($t < 1/6);
 return $q if($t < 1/2);
 return $p+($q-$p)*(2/3-$t)*6 if($t < 2/3);
 return $p;
}

1;
