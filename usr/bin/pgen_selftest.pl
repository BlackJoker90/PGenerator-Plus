#!/usr/bin/perl
#
# pgen_selftest.pl - PGenerator+ signal self-test.
#
# Walks the output through a fixed set of signal modes (SDR RGB/YCbCr,
# HDR10, Low Latency Dolby Vision), draws test windows with known codes and
# reads back what the vc4 plane scans out (pgen_scanout via PGenerator_cmd.pl
# SCANOUT_PROBE), plus the measured link depth, the range CSC, the connector
# range property and the AVI infoframe. Results go to a JSON state file the
# WebUI polls. The user's signal settings are put back at the end, also on
# cancel and on error.
#
# Usage: pgen_selftest.pl <state_file> [quick|full]
# Started by webui.pm (POST /api/selftest/start); runs as the daemon user.
#
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use JSON::PP ();
use MIME::Base64 qw(encode_base64);
use Time::HiRes qw(sleep time);

my $state_file=shift || "/tmp/pgen-selftest.json";
my $set=lc(shift || "full");
my $cancel_file="/tmp/pgen-selftest.cancel";
my $var_dir="/var/lib/PGenerator";
my $command_file="$var_dir/running/operations.txt";
my $JSON=JSON::PP->new->utf8->canonical;
# The daemon removes a stale cancel file before it launches this script; one
# that exists now is a cancel sent during start-up.

#
# Scenarios. "codes" are drawn as BITS=10 windows, "codes8" as BITS=8 windows
# (an 8-bit pattern on a deeper link, e.g. G1 plates and test images). Each
# entry is [label, r, g, b].
#
my @grey10=(["Black",64,64,64],["Black +1",65,65,65],["Grey 50 %",502,502,502],["Grey 75 %",721,721,721],["White",940,940,940]);
my @grey8=(["8-bit black",16,16,16],["8-bit grey",126,126,126],["8-bit white",235,235,235]);
my @scenarios=(
 { id=>"sdr_rgb_lim_8", group=>"SDR", label=>"RGB Limited", depth=>8,
   config=>{signal_mode=>"sdr",color_format=>"0",max_bpc=>"8",rgb_quant_range=>"1"},
   range=>"LIMITED", codes8=>[["Black",16,16,16],["Grey 50 %",126,126,126],["Grey 75 %",180,180,180],["White",235,235,235],["Red 75 %",180,16,16]] },
 { id=>"sdr_rgb_lim_10", group=>"SDR", label=>"RGB Limited", depth=>10,
   config=>{signal_mode=>"sdr",color_format=>"0",max_bpc=>"10",rgb_quant_range=>"1"},
   range=>"LIMITED", codes=>[@grey10,["Red 75 %",721,64,64]], codes8=>[@grey8] },
 { id=>"sdr_rgb_full_10", group=>"SDR", label=>"RGB Full", depth=>10,
   config=>{signal_mode=>"sdr",color_format=>"0",max_bpc=>"10",rgb_quant_range=>"2"},
   range=>"FULL", codes=>[["Black",0,0,0],["Black +1",1,1,1],["Grey 50 %",513,513,513],["Grey 75 %",767,767,767],["Blue 75 %",0,0,767]],
   codes8=>[["8-bit black",0,0,0],["8-bit grey",128,128,128],["8-bit white",255,255,255]] },
 { id=>"sdr_ycc422_10", group=>"SDR", label=>"YCbCr 4:2:2", depth=>10,
   config=>{signal_mode=>"sdr",color_format=>"2",max_bpc=>"10",rgb_quant_range=>"1"},
   codes=>[@grey10], codes8=>[@grey8] },
 { id=>"sdr_ycc444_10", group=>"SDR", label=>"YCbCr 4:4:4", depth=>10,
   config=>{signal_mode=>"sdr",color_format=>"1",max_bpc=>"10",rgb_quant_range=>"1"},
   codes=>[@grey10], codes8=>[@grey8] },
 { id=>"hdr10_rgb_lim_10", group=>"HDR10", label=>"RGB Limited", depth=>10,
   config=>{signal_mode=>"hdr10",color_format=>"0",max_bpc=>"10",rgb_quant_range=>"1"},
   range=>"LIMITED", codes=>[@grey10,["Red 75 %",721,64,64]], codes8=>[@grey8], drm=>1 },
 { id=>"hdr10_ycc422_10", group=>"HDR10", label=>"YCbCr 4:2:2", depth=>10,
   config=>{signal_mode=>"hdr10",color_format=>"2",max_bpc=>"10",rgb_quant_range=>"1"},
   codes=>[@grey10], codes8=>[@grey8], drm=>1 },
 { id=>"hdr10_ycc444_10", group=>"HDR10", label=>"YCbCr 4:4:4", depth=>10,
   config=>{signal_mode=>"hdr10",color_format=>"1",max_bpc=>"10",rgb_quant_range=>"1"},
   codes=>[@grey10], codes8=>[@grey8], drm=>1 },
 # Standard DV tunnels 12-bit YCbCr 4:2:2 in full-range 8-bit RGB. At 8 bpc
 # the 8-bit framebuffer holds the packed bytes exactly (a 10 bpc surface
 # rescales them), so this mode is pinned to 8 bpc.
 { id=>"dv_std_rgb_8", group=>"Dolby Vision", label=>"Standard", depth=>8,
   config=>{signal_mode=>"dv",dv_transport=>"standard",max_bpc=>"8"},
   range=>"FULL", tunnel=>1, codes=>[@grey10], codes8=>[@grey8] },
 { id=>"lldv_ycc422_12", group=>"Dolby Vision", label=>"Low Latency", depth=>12,
   config=>{signal_mode=>"dv",dv_transport=>"lldv"},
   codes=>[@grey10], codes8=>[@grey8] },
);
@scenarios=grep { $_->{id}=~/^(sdr_rgb_lim_10|sdr_ycc444_10|hdr10_ycc444_10)$/ } @scenarios if($set eq "quick");

my %state=(
 state=>"running", message=>"Preparing the self-test.", set=>$set, pid=>$$,
 started=>int(time()), finished=>0, step=>0, steps=>0, current=>"",
 scenarios=>[ map { { id=>$_->{id}, group=>$_->{group}, label=>$_->{label}, depth=>$_->{depth},
                      status=>"pending", note=>"", link=>{}, checks=>[], passed=>0, total=>0 } } @scenarios ],
);
$state{steps}+=1+scalar(@{$_->{codes} || []})+scalar(@{$_->{codes8} || []}) for(@scenarios);

sub write_state {
 my $tmp="$state_file.$$.tmp";
 open(my $fh,">",$tmp) or return;
 print $fh $JSON->encode(\%state);
 close($fh);
 rename($tmp,$state_file);
}

sub http {
 my ($method,$path,$body)=@_;
 my $sock=IO::Socket::INET->new(PeerAddr=>"127.0.0.1",PeerPort=>80,Proto=>"tcp",Timeout=>10) or return (0,"");
 $body="" if(!defined($body));
 my $req="$method $path HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n";
 $req.="Content-Type: application/json\r\nContent-Length: ".length($body)."\r\n" if($method eq "POST");
 print $sock $req."\r\n".$body;
 my $resp="";
 my $deadline=time()+40;
 my $sel=IO::Select->new($sock);
 while(time() < $deadline) {
  # Bounded wait per read: a stalled daemon must not hang the test forever.
  last if(!$sel->can_read($deadline-time()));
  my $n=sysread($sock,my $buf,65536);
  last if(!$n);
  $resp.=$buf;
 }
 close($sock);
 my ($code)=$resp=~/^HTTP\/1\.\d (\d+)/;
 my ($payload)=$resp=~/\r\n\r\n(.*)$/s;
 return ($code || 0,defined($payload) ? $payload : "");
}

sub http_json {
 my ($method,$path,$body)=@_;
 my ($code,$payload)=&http($method,$path,$body);
 my $data=eval { $JSON->decode($payload) };
 return ($code,$data || {});
}

sub cancelled { return -e $cancel_file; }

sub calibration_busy {
 my ($code,$info)=&http_json("GET","/api/info");
 return 0 if($code != 200);
 my $cal=$info->{calibration} || {};
 return ($cal->{connected} && "$cal->{connected}" ne "0" && "$cal->{connected}" ne "false") ? ($cal->{software} || "Calibration software") : 0;
}

# Apply signal settings through the WebUI path and wait for the renderer.
# Returns (error, refusal): a refusal is a mode the board or display cannot
# carry (PGSignalCheck.pm), not a failure.
sub apply_config {
 my $config=shift;
 # "selftest" tells the daemon this switch is ours: it keeps the user's
 # pre-Dolby-Vision values (pre_dv_*) instead of saving the scenario's.
 my $body=$JSON->encode({%$config,selftest=>1});
 my ($code,$res)=&http_json("POST","/api/config",$body);
 return ("",$res->{message} || "Not possible with this display.") if($code == 200 && $res->{refused});
 return "The settings were refused (HTTP $code)." if($code != 200 || ($res->{status} || "") ne "ok");
 if($res->{restart_id}) {
  my $deadline=time()+75;
  while(time() < $deadline) {
   sleep(0.5);
   my ($c,$st)=&http_json("GET","/api/restart/status?id=$res->{restart_id}");
   my $s=$st->{state} || "";
   return "" if($s eq "ready");
   if($s eq "error") {
    # The daemon's own text usually names the renderer already.
    my $m=$st->{message} || "";
    return ($m=~/^The renderer/) ? $m : "The renderer did not start".($m ne "" ? ": $m" : ".");
   }
  }
  return "The renderer restart did not finish within 75 seconds.";
 }
 sleep(1.0);
 return "";
}

sub sudo_cmd {
 my @args=@_;
 my $env=join(" ",map { encode_base64($_,"") } @args);
 local $ENV{PG_CMD}=$env;
 my $out=`timeout 15 sudo -E /usr/bin/PGenerator_cmd.pl 2>/dev/null`;
 return defined($out) ? $out : "";
}

# The scanned-out plane: the largest one with a decodable, mapped buffer.
sub scanout {
 my ($x,$y,$w,$h)=@_;
 my $out=&sudo_cmd("SCANOUT_PROBE",$x,$y,$w,$h);
 my (@planes,$cur);
 foreach my $line (split(/\n/,$out)) {
  if($line=~/^FB .*width=(\d+) height=(\d+) format=(\S+) bits=(\d+)/) {
   $cur={ width=>$1, height=>$2, format=>$3, bits=>$4 };
   push(@planes,$cur);
  } elsif($cur && $line=~/^AREA .* r=(\d+)-(\d+) g=(\d+)-(\d+) b=(\d+)-(\d+)/) {
   $cur->{area}=[[$1,$2],[$3,$4],[$5,$6]];
  } elsif($cur && $line=~/^ERR (\S+)/) {
   $cur->{error}=$1;
  }
 }
 my @good=sort { $b->{width}*$b->{height} <=> $a->{width}*$a->{height} } grep { $_->{area} } @planes;
 return $good[0] if(@good);
 return { error=>(@planes ? ($planes[0]{error} || "no-area") : "no-plane") };
}

sub screen_size {
 my $plane=&scanout(0,0,1,1);
 return (0,0) if(!$plane->{width});
 return ($plane->{width},$plane->{height});
}

sub hdmi_regs {
 my %reg;
 foreach my $status (sort glob("/sys/class/drm/card*-HDMI-A-*/status")) {
  open(my $fh,"<",$status) or next;
  my $s=<$fh>;
  close($fh);
  next if(!defined($s) || $s!~/^connected/);
  my ($port)=$status=~/HDMI-A-(\d+)\/status$/;
  my ($file)=glob("/sys/kernel/debug/dri/*/hdmi".($port-1)."_regs");
  last if(!$file || !open(my $rf,"<",$file));
  while(my $line=<$rf>) { $reg{$1}=hex($2) if($line=~/^\s*(\w+)\s*=\s*0x([0-9a-fA-F]+)/); }
  close($rf);
  last;
 }
 return %reg;
}

sub hdmi_connected {
 foreach my $status (glob("/sys/class/drm/card*-HDMI-A-*/status")) {
  open(my $fh,"<",$status) or next;
  my $s=<$fh>;
  close($fh);
  return 1 if(defined($s) && $s=~/^connected/);
 }
 return 0;
}

sub quant_range_prop {
 my $out=`timeout 5 modetest -M vc4 -c 2>/dev/null`;
 my ($p)=$out=~/rgb quant range:.*?value:\s*(\d+)/s;
 return defined($p) ? int($p) : -1;
}

# Last infoframe burst in the kernel log: AVI bytes and whether a DRM (HDR)
# frame followed it.
sub infoframes {
 my $dmesg=`timeout 3 dmesg 2>/dev/null`;
 my ($avi,$drm)=("","");
 foreach my $line (split(/\n/,$dmesg)) {
  if($line=~/AVI IF:\s*(.+)/) { $avi=$1; $drm=""; }
  if($line=~/DRM IF:\s*(.+)/) { $drm=$1; }
 }
 my @b=map { hex($_) } ($avi=~/([0-9a-fA-F]{2})/g);
 return { bytes=>\@b, drm=>($drm ne "" ? 1 : 0), count=>scalar(() = $dmesg=~/AVI IF:/g) };
}

# The vendor infoframe on the wire (pgen_hdmi_packet reads the packet RAM,
# as root through PGenerator_cmd.pl).
sub vendor_infoframe {
 my $line=&sudo_cmd("HDMI_PACKET",1);
 return { kind=>"unreadable", label=>"packet RAM not readable" }
  if($line!~/^slot=1 enabled=(\d) type=([0-9a-f]{2}) version=([0-9a-f]{2}) length=([0-9a-f]{2}) bytes=([0-9a-f:]*)/m);
 my ($on,$type,$ver,$len,@b)=($1,hex($2),hex($3),hex($4),map { hex($_) } split(/:/,$5));
 return { kind=>"none", label=>"none" } if($on ne "1");
 my $label=sprintf("infoframe type 0x%02x",$type);
 return { kind=>"other", label=>$label } if($type != 0x81);
 # Checksum byte first, then the payload: type + version + length + all
 # bytes sum to 0 (mod 256).
 return { kind=>"other", label=>"vendor infoframe, ".scalar(@b)." of ".($len+1)." bytes" } if(@b < $len+1 || $len < 4);
 my $sum=$type+$ver+$len;
 $sum+=$b[$_] for(0..$len);
 return { kind=>"other", label=>"vendor infoframe with a bad checksum" } if($sum & 0xff);
 my $oui=sprintf("%02x:%02x:%02x",$b[3],$b[2],$b[1]);
 # Both DV vendor frames are version 1 (the Pi sends 81:01:1b and 81:01:18).
 return { kind=>"other", label=>sprintf("vendor infoframe, OUI %s, version 0x%02x",$oui,$ver) } if($ver != 1);
 if($oui eq "00:d0:46") {
  return { kind=>"other", label=>sprintf("Dolby VSIF with length 0x%02x instead of 0x1b",$len) } if($len != 0x1b);
  # PB4 bit 1 Dolby_Vision_Signal, bit 0 Low_Latency; the renderer's "off"
  # frame carries the OUI with both clear.
  return { kind=>"Dolby VSIF", label=>"Dolby VSIF" } if(($b[4] & 0x03) == 0x03);
  return { kind=>"other", label=>sprintf("Dolby VSIF without the low-latency DV signal (PB4 0x%02x)",$b[4]) };
 }
 return { kind=>"Standard DV VSIF", label=>"Standard DV VSIF" } if($oui eq "00:0c:03" && $len == 0x18);
 return { kind=>"other", label=>"vendor infoframe, OUI $oui, length ".sprintf("0x%02x",$len) };
}

sub write_pattern {
 my ($bits,$max,$range,$rgb,$bg,$w,$h)=@_;
 my $s=sqrt(0.10);
 my $pw=int($w*$s); my $ph=int($h*$s);
 my $px=int(($w-$pw)/2); my $py=int(($h-$ph)/2);
 my $pat="PATTERN_NAME=selftest\nBITS=$bits\nSOURCE_MAX=$max\n";
 $pat.="DRAW=RECTANGLE\nDIM=$pw,$ph\nRGB=$rgb\nBG=$bg\nPOSITION=$px,$py\n";
 $pat.="SOURCE_RANGE=$range\n" if($range ne "");
 $pat.="END=1\nFRAME=1\n";
 open(my $fh,">","$command_file.tmp") or return 0;
 print $fh $pat;
 close($fh);
 rename("$command_file.tmp",$command_file) or return 0;
 open(my $rf,">","$var_dir/running/return") or return 0;
 close($rf);
 return 1;
}

# Expected framebuffer channels for a grey or colour window.
sub expected_fb {
 my ($sc,$link_format,$bits,$r,$g,$b)=@_;
 # Standard DV packer (dovi_pattern_shader): source code -> 12 bit, a grey
 # is Y=code, Cb=Cr=2048; each pixel carries R=C>>4, G=Y>>4,
 # B=(Y&15)|((C&15)<<4), so a grey reads 128, Y>>4, Y&15.
 if($sc->{tunnel}) {
  my $y=($bits == 8) ? ($g << 4) : ($g << 2);
  return [2048 >> 4,$y >> 4,$y & 15];
 }
 my $promote=($bits == 8 && $sc->{depth} >= 10);
 my @c=($r,$g,$b);
 if($promote) {
  if($link_format eq "RGB" && ($sc->{range} || "") eq "FULL") {
   @c=map { int(($_*1023+127)/255) } @c;
  } else {
   @c=map { $_ << 2 } @c;
  }
 }
 my $neutral=($sc->{depth} >= 10) ? 512 : 128;
 # YCbCr: greys only; the renderer stores 4:4:4 as Cb,Cr,Y and 4:2:2 as Y,Cb,Cr.
 return [$neutral,$neutral,$c[2]] if($link_format eq "YCbCr 4:4:4");
 return [$c[0],$neutral,$neutral] if($link_format eq "YCbCr 4:2:2");
 return [@c];
}

sub link_format_for {
 my $sc=shift;
 if(($sc->{config}{signal_mode} || "") eq "dv") {
  return (($sc->{config}{dv_transport} || "") eq "standard") ? "RGB" : "YCbCr 4:2:2";
 }
 my $f=$sc->{config}{color_format} || "0";
 return $f eq "1" ? "YCbCr 4:4:4" : $f eq "2" ? "YCbCr 4:2:2" : "RGB";
}

sub add_check {
 my ($entry,$label,$expect,$got,$ok,$info,$swatch)=@_;
 push(@{$entry->{checks}},{label=>$label,expect=>"$expect",got=>"$got",ok=>($ok ? JSON::PP::true : JSON::PP::false),
                          ($info ? (info=>JSON::PP::true) : ()),($swatch ? (swatch=>$swatch) : ())});
 $entry->{total}++ if(!$info);
 $entry->{passed}++ if($ok && !$info);
}

#
# Saved state of the user's output, restored at the end.
#
my %restore;
sub save_user_state {
 my ($code,$cfg)=&http_json("GET","/api/config");
 return 0 if($code != 200 || !%$cfg);
 my $mode=$cfg->{signal_mode} || "";
 if($mode eq "") {
  $mode=(($cfg->{dv_status} || 0) == 1) ? "dv" : (($cfg->{is_hdr} || 0) == 1) ? ((($cfg->{eotf} || 0) == 3) ? "hlg" : "hdr10") : "sdr";
 }
 %restore=(signal_mode=>$mode);
 foreach my $k (qw(color_format max_bpc rgb_quant_range colorimetry dv_transport)) {
  $restore{$k}="$cfg->{$k}" if(defined($cfg->{$k}) && "$cfg->{$k}" ne "");
 }
 # The result holds for this output mode: the WebUI names it and flags the
 # result once the output runs another mode.
 $state{mode_idx}="$cfg->{mode_idx}" if(defined($cfg->{mode_idx}));
 my ($icode,$info)=&http_json("GET","/api/info");
 $state{resolution}=$info->{resolution} if($icode == 200 && ($info->{resolution} || "") ne "");
 return 1;
}

sub restore_user_state {
 return if(!%restore);
 $state{message}="Restoring your signal settings.";
 &write_state();
 my $err=&apply_config({%restore});
 # Leaving Dolby Vision, the daemon treats a format equal to the DV one
 # (LLDV 4:2:2) as a leftover and gives back the format from before DV. A
 # second apply, now outside DV, sets what the user really had.
 if(!$err) {
  my ($code,$cfg)=&http_json("GET","/api/config");
  if($code == 200 && grep { defined($cfg->{$_}) && "$cfg->{$_}" ne $restore{$_} } grep { $_ ne "signal_mode" } keys(%restore)) {
   $err=&apply_config({%restore});
  }
 }
 &http("POST","/api/pattern",'{"name":"stop"}');
 return $err;
}

my $finishing=0;
sub finish {
 my ($final,$message)=@_;
 return if($finishing++);
 # An error inside the restore must still leave a final state behind.
 my $err=eval { &restore_user_state() };
 $err=$@ ? "internal error: $@" : ($err || "");
 $message.=" Restoring the settings failed: $err" if($err);
 $state{state}=$final;
 $state{message}=$message;
 $state{current}="";
 $state{finished}=int(time());
 &write_state();
 unlink($cancel_file);
 exit(0);
}

$SIG{TERM}=sub { &finish("cancelled","The self-test was stopped."); };
# A closed connection must not kill the script before it restores settings;
# an unexpected error still ends in finish() and the restore.
$SIG{PIPE}="IGNORE";
$SIG{__DIE__}=sub { return if($^S || $finishing); &finish("error","The self-test stopped on an internal error: ".join("",@_)); };

&write_state();
if(!&hdmi_connected()) {
 $state{state}="error"; $state{message}="No display is connected. Connect a display and run the self-test again.";
 $state{finished}=int(time()); &write_state(); exit(0);
}
if(my $sw=&calibration_busy()) {
 $state{state}="error"; $state{message}="$sw is connected. The self-test does not take over an active calibration session.";
 $state{finished}=int(time()); &write_state(); exit(0);
}
if(!&save_user_state()) {
 $state{state}="error"; $state{message}="The current signal settings could not be read, so the self-test did not start.";
 $state{finished}=int(time()); &write_state(); exit(0);
}

my $failed=0;
my $skipped=0;
my $refused=0;
for(my $n=0;$n<@scenarios;$n++) {
 my $sc=$scenarios[$n];
 my $entry=$state{scenarios}[$n];
 &finish("cancelled","The self-test was stopped. Your signal settings are back.") if(&cancelled());
 if(my $sw=&calibration_busy()) {
  &finish("error","$sw connected during the test, so the self-test stopped and gave the output back.");
 }
 $entry->{status}="running";
 $state{current}="$sc->{group} $sc->{label}";
 $state{message}="Switching to $sc->{group} $sc->{label}, ".($sc->{depth})."-bit.";
 &write_state();

 my ($err,$refusal)=&apply_config($sc->{config});
 $state{step}++;
 if($refusal) {
  $entry->{status}="skip"; $entry->{refused}=1; $entry->{note}="Not possible here: $refusal"; $refused++;
  $state{step}+=scalar(@{$sc->{codes} || []})+scalar(@{$sc->{codes8} || []});
  &write_state();
  next;
 }
 # Without a display every further switch would fail the same way after a
 # long wait; stop and say why.
 if($err && !&hdmi_connected()) {
  $entry->{status}="fail"; $entry->{note}=$err;
  &finish("error","The display was disconnected during the test, so it stopped. Connect a display and run it again.");
 }
 if($err) {
  $entry->{status}="fail"; $entry->{note}=$err; $failed++;
  $state{step}+=scalar(@{$sc->{codes} || []})+scalar(@{$sc->{codes8} || []});
  &write_state();
  next;
 }
 my ($w,$h)=&screen_size();
 if(!$w) {
  $entry->{status}="fail"; $entry->{note}="Nothing is being scanned out after the mode switch."; $failed++;
  $state{step}+=scalar(@{$sc->{codes} || []})+scalar(@{$sc->{codes8} || []});
  &write_state();
  next;
 }

 # Link state.
 my $format=&link_format_for($sc);
 my %reg=&hdmi_regs();
 my %bpc_for_depth=(4=>8,5=>10,6=>12);
 my $bpc=$bpc_for_depth{($reg{"HDMI_DEEP_COLOR_CONFIG_1"} || 0) & 0xf} || 0;
 my $csc=$reg{"HDMI_CSC_12_11"};
 my $csc_unity=(defined($csc) && ($csc & 0xffff) == 0x2000) ? 1 : 0;
 my $prop=&quant_range_prop();
 my $if=&infoframes();
 my @avi=@{$if->{bytes}};
 my %fmt_name=(0=>"RGB",1=>"YCbCr 4:2:2",2=>"YCbCr 4:4:4");
 my $avi_format=@avi > 4 ? ($fmt_name{($avi[4]>>5)&3} || "?") : "";
 my $avi_q=@avi > 6 ? (($avi[6]>>2)&3) : -1;
 $entry->{link}={ bpc=>$bpc, format=>$format, csc=>($csc_unity ? "unity" : "range"), prop=>$prop,
                  avi=>join(" ",map { sprintf("%02x",$_) } @avi[0..($#avi < 7 ? $#avi : 7)]), drm=>$if->{drm}, width=>$w, height=>$h };

 add_check($entry,"AVI colour format",$format,$avi_format || "none",$avi_format eq $format);
 if($format eq "RGB") {
  my $want_q=(($sc->{range} || "") eq "FULL") ? 2 : 1;
  add_check($entry,"AVI quantisation",$want_q == 2 ? "Full" : "Limited",$avi_q == 2 ? "Full" : $avi_q == 1 ? "Limited" : "Default",$avi_q == $want_q);
 } elsif($format=~/^YCbCr/ && @avi > 8) {
  # YQ (PB5 bits 7..6): 0 Limited, 1 Full
  my $want_yq=(($sc->{range} || "") eq "FULL") ? 1 : 0;
  my $avi_yq=($avi[8]>>6)&3;
  add_check($entry,"AVI YCC quantisation",$want_yq ? "Full" : "Limited",$avi_yq == 1 ? "Full" : $avi_yq == 0 ? "Limited" : "Reserved",$avi_yq == $want_yq);
 }
 if($format ne "YCbCr 4:2:2") {
  my $want_bpc=$sc->{depth} > 10 ? 10 : $sc->{depth};
  add_check($entry,"Link depth","$want_bpc-bit",$bpc ? "$bpc-bit" : "unknown",$bpc == $want_bpc);
 }
 # HDR metadata from the packet gate (bit 7), so a frame left over from an
 # earlier HDR mode cannot pass SDR; the kernel log when the register is
 # unreadable.
 my $pkt=$reg{"HDMI_RAM_PACKET_CONFIG"};
 my $drm_on=defined($pkt) ? (($pkt & 0x80) ? 1 : 0) : $if->{drm};
 if($sc->{drm}) {
  add_check($entry,"HDR metadata","DRM infoframe",$drm_on ? "DRM infoframe" : "none",$drm_on);
 } else {
  add_check($entry,"HDR metadata","none",$drm_on ? "DRM infoframe" : "none",!$drm_on);
 }
 # Dolby Vision is signalled by the vendor infoframe, not the pixels: LLDV
 # by the Dolby VSIF (OUI 00:D0:46), standard DV by the HDMI 1.4b VSIF
 # (OUI 00:0C:03) with the DV length 0x18. Outside DV neither may be sent.
 my $vsif=&vendor_infoframe();
 my $dv_kind=$vsif->{kind};
 my $want_dv=(($sc->{config}{signal_mode} || "") eq "dv") ? ((($sc->{config}{dv_transport} || "") eq "standard") ? "Standard DV VSIF" : "Dolby VSIF") : "none";
 if($dv_kind eq "unreadable") {
  # No packet data: neither DV on nor DV off is proven.
  add_check($entry,"Dolby Vision signalling",$want_dv,"not verified (".$vsif->{label}.")",0,1);
  $entry->{unverified}=1;
 } else {
  add_check($entry,"Dolby Vision signalling",$want_dv,$vsif->{label},$dv_kind eq $want_dv);
 }

 # Scanout = wire only while the range CSC is unity (YCbCr, RGB Full, RGB
 # Limited on the patched vc4). Otherwise the codes are not provable here.
 my $provable=$csc_unity;
 if(!$provable) {
  $entry->{note}="The vc4 range CSC is active after the framebuffer, so the codes on the cable cannot be read back in this mode.";
  $state{step}+=scalar(@{$sc->{codes} || []})+scalar(@{$sc->{codes8} || []});
 }
 my $range=($format eq "RGB") ? ($sc->{range} || "LIMITED") : "";
 my @windows=();
 push(@windows,map { [10,1023,$_] } @{$sc->{codes} || []}) if($provable);
 push(@windows,map { [8,255,$_] } @{$sc->{codes8} || []}) if($provable);
 my $fb_format="";
 foreach my $win (@windows) {
  &finish("cancelled","The self-test was stopped. Your signal settings are back.") if(&cancelled());
  my ($bits,$max,$code)=@$win;
  my ($label,$r,$g,$b)=@$code;
  my $black=($range eq "FULL") ? 0 : ($bits == 10 ? 64 : 16);
  my $expect=&expected_fb($sc,$format,$bits,$r,$g,$b);
  $state{message}="$sc->{group} $sc->{label}: drawing $label.";
  &write_state();
  if($sc->{tunnel} && $bits == 10) {
   # Standard DV patterns are BITS=8 with 12-bit source codes, as the WebUI
   # and Calman send them: BITS=10 would switch the renderer to its 10-bit
   # surface, which rescales the packed tunnel bytes.
   my @s=map { $_ << 2 } ($r,$g,$b,$black);
   &write_pattern(8,4095,$range,"$s[0],$s[1],$s[2]","$s[3],$s[3],$s[3]",$w,$h);
  } else {
   &write_pattern($bits,$max,$range,"$r,$g,$b","$black,$black,$black",$w,$h);
  }
  my ($got,$ok,$plane)=("",0,{});
  # The first frame after a switch can still be the previous one.
  for(my $try=0;$try<6 && !$ok;$try++) {
   sleep($try ? 0.5 : 0.7);
   $plane=&scanout(int($w/2)-32,int($h/2)-32,64,64);
   next if(!$plane->{area});
   my @a=@{$plane->{area}};
   my $uniform=($a[0][0] == $a[0][1] && $a[1][0] == $a[1][1] && $a[2][0] == $a[2][1]);
   $got=$uniform ? "$a[0][0] $a[1][0] $a[2][0]" : "$a[0][0]-$a[0][1] $a[1][0]-$a[1][1] $a[2][0]-$a[2][1]";
   $ok=$uniform && $a[0][0] == $expect->[0] && $a[1][0] == $expect->[1] && $a[2][0] == $expect->[2];
  }
  $got="no readback (".($plane->{error} || "unknown").")" if($got eq "");
  $fb_format=$plane->{format} || $fb_format;
  my $kind=($bits == 8 && $sc->{depth} >= 10) ? " (8-bit pattern)" : "";
  # The window's source code, for the WebUI swatch strip.
 add_check($entry,$label.$kind,join(" ",@$expect),$got,$ok,0,
           { r=>$r, g=>$g, b=>$b, max=>$max, full=>($range eq "FULL" ? 1 : 0), bits=>$bits });
  $state{step}++;
  &write_state();
 }
 $entry->{link}{fb}=$fb_format;
 if(!$provable) {
  $entry->{status}=($entry->{passed} == $entry->{total}) ? "skip" : "fail";
  $skipped++ if($entry->{status} eq "skip");
 } else {
  $entry->{status}=($entry->{passed} == $entry->{total}) ? "pass" : "fail";
  # Codes fine but the infoframe could not be read: not a pass.
  if($entry->{status} eq "pass" && $entry->{unverified}) {
   $entry->{status}="skip";
   $entry->{note}="The Dolby Vision infoframe could not be read, so this mode is not fully verified.";
   $skipped++;
  }
 }
 $failed++ if($entry->{status} eq "fail");
 &write_state();
}

my $total=scalar(@scenarios);
if($failed) {
 &finish("failed","$failed of $total modes did not match. Your signal settings are back.");
}
my $refused_text=$refused ? " $refused ".($refused == 1 ? "mode is" : "modes are")." not possible with this display and resolution." : "";
&finish("passed",$skipped ? "All provable modes are bit-exact; $skipped could not be read back.$refused_text Your signal settings are back."
                          : ($refused ? "Every possible mode is bit-exact.$refused_text Your signal settings are back."
                                      : "Every mode is bit-exact. Your signal settings are back."));
