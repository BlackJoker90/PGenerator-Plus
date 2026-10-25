package PGSignalCheck;

# Can this signal go out as asked? A requested output (mode, colour format,
# bit depth, HDR / Dolby Vision) is checked against what the board can send
# and what the display declares in its EDID (PGEdidCaps.pm). A request that
# cannot be met is refused with the reason; the caller keeps the current
# output instead of letting the HDMI driver quietly pick something else
# (vc4 lowers the bit depth until the TMDS rate fits), so nothing is ever
# measured in a mode that was not selected.
#
# Pure functions: no conf, no files. command.pm gathers the inputs.

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK=qw(
 signal_check signal_board_limits signal_port_info signal_tmds_mhz
 signal_format_label signal_mode_label signal_hdr_label
 signal_wire_from_infoframes signal_wire_parts signal_wire_label signal_wire_adjustments
 signal_vsif_dv signal_avi_fields signal_range_expectation signal_range_plate_lines
);

our %FORMAT_NAME=(0=>"RGB",1=>"YCbCr 4:4:4",2=>"YCbCr 4:2:2",3=>"YCbCr 4:2:0");

# TMDS limit of one HDMI port. vc4: BCM2711 HDMI0 600 MHz (HDMI 2.0), HDMI1
# 340 MHz (HDMI_14_MAX_TMDS_CLK); BCM2712 600 MHz on both ports.
sub signal_board_limits {
 my ($model,$port)=@_;
 $model="" if(!defined $model);
 $port="" if(!defined $port);
 my $pi5=($model=~/Raspberry Pi 5|Compute Module 5|BCM2712/i) ? 1 : 0;
 my $name=$pi5 ? "Raspberry Pi 5" : "Raspberry Pi 4";
 $name=$1 if($model=~/(Raspberry Pi (?:Compute Module \d|\d+)(?: Model [A-Z])?)/);
 $name=~s/\s+Model\s+[A-Z]$//;
 my $max=600;
 $max=340 if(!$pi5 && $port eq "HDMI-A-2");
 return {name=>$name,board=>($pi5 ? "pi5" : "pi4"),port=>$port,max_tmds_mhz=>$max};
}

# The port as the board labels it (HDMI-A-1/-2 are HDMI0/HDMI1) and the
# largest mode its TMDS limit carries: 3840x2160 at 60 Hz needs 594 MHz,
# at 30 Hz 297 MHz (8-bit RGB). On a Pi 4 only HDMI0 does 4Kp60 (Raspberry
# Pi documentation, config.txt, hdmi_enable_4kp60); "faster" names the
# other port when it can do more than this one.
sub signal_port_info {
 my ($model,$port)=@_;
 return undef if(!defined $port || $port!~/^HDMI-A-(\d+)$/);
 my $n=$1;
 my $max_mode=sub { my $mhz=shift; return $mhz >= 594 ? "4K60" : ($mhz >= 297 ? "4K30" : "1080p60"); };
 my $b=signal_board_limits($model,$port);
 my %info=(port=>$port,label=>"HDMI".($n-1),max_tmds_mhz=>$b->{max_tmds_mhz},max_mode=>$max_mode->($b->{max_tmds_mhz}));
 # Pi 4 Model B: HDMI0 is the micro-HDMI socket next to USB-C power.
 my %where=($b->{name} eq "Raspberry Pi 4" ? ("HDMI-A-1"=>"next to the USB-C power socket") : ());
 $info{where}=$where{$port} if($where{$port});
 foreach my $other ("HDMI-A-1","HDMI-A-2") {
  next if($other eq $port);
  my $o=signal_board_limits($model,$other);
  next if($o->{max_tmds_mhz} <= $b->{max_tmds_mhz});
  my ($m)=$other=~/(\d+)$/;
  $info{faster}={port=>$other,label=>"HDMI".($m-1),max_mode=>$max_mode->($o->{max_tmds_mhz})};
  $info{faster}{where}=$where{$other} if($where{$other});
 }
 # Both sockets of the board, HDMI0 first, for the port picture.
 $info{board}=$b->{board};
 $info{ports}=[map {
  my $o=signal_board_limits($model,$_);
  my ($m)=$_=~/(\d+)$/;
  my %q=(port=>$_,label=>"HDMI".($m-1),max_tmds_mhz=>$o->{max_tmds_mhz},max_mode=>$max_mode->($o->{max_tmds_mhz}));
  $q{where}=$where{$_} if($where{$_});
  \%q;
 } ("HDMI-A-1","HDMI-A-2")];
 return \%info;
}

# TMDS character rate in MHz. RGB / 4:4:4 scale with the bit depth;
# 4:2:2 always travels in a 12-bit container at the pixel clock.
sub signal_tmds_mhz {
 my ($clock_khz,$format,$bpc)=@_;
 return 0 if(!$clock_khz);
 $bpc=8 if(!$bpc);
 return $clock_khz/1000 if(defined $format && $format == 2);
 return $clock_khz*$bpc/8/1000;
}

sub signal_format_label {
 my ($format,$bpc)=@_;
 my $name=$FORMAT_NAME{defined $format ? $format : 0} || "RGB";
 return $name if(!$bpc);
 return "$bpc-bit $name";
}

sub _hz {
 my ($hz)=@_;
 return "" if(!defined $hz || $hz eq "");
 my $s=sprintf("%.3f",$hz);
 $s=~s/\.?0+$//;
 return "$s Hz";
}

sub signal_mode_label {
 my ($req)=@_;
 return "" if(!$req->{width} || !$req->{height});
 my $s="$req->{width}x$req->{height}";
 $s.=($req->{interlaced} ? "i" : "");
 $s.=" "._hz($req->{refresh}) if(defined $req->{refresh} && $req->{refresh} ne "");
 return $s;
}

sub signal_hdr_label {
 my ($req)=@_;
 my $m=lc($req->{signal_mode} || "sdr");
 return "HDR10" if($m eq "hdr10");
 return "HLG" if($m eq "hlg");
 if($m eq "dv") {
  return (lc($req->{dv_transport} || "") eq "lldv") ? "Dolby Vision (low latency)" : "Dolby Vision";
 }
 return "SDR";
}

sub _fmt_mhz {
 my ($v)=@_;
 my $s=sprintf("%.1f",$v);
 $s=~s/\.0$//;
 return "$s MHz";
}

# Display-side check of one format + bit depth (EDID only).
sub _display_accepts {
 my ($d,$format,$bpc)=@_;
 return (1,"") if(!$d || !$d->{known});
 my $label=signal_format_label($format,$bpc);
 if($format == 1 && !$d->{has_ycbcr444}) {
  return (0,"The display does not accept YCbCr 4:4:4 (not in its EDID).");
 }
 if($format == 2 && !$d->{has_ycbcr422}) {
  return (0,"The display does not accept YCbCr 4:2:2 (not in its EDID).");
 }
 if(($format == 0 || $format == 1) && $bpc > 8) {
  my $flag=($bpc == 10) ? "dc_30bit" : "dc_36bit";
  my $bits=($bpc == 10) ? 30 : 36;
  if(!$d->{hdmi}) {
   return (0,"The display does not accept $label: its EDID has no HDMI block, so it takes 8-bit RGB only.");
  }
  if(!$d->{$flag}) {
   return (0,"The display does not accept $label (no $bits-bit deep colour in its EDID).");
  }
  if($format == 1 && !$d->{dc_y444}) {
   return (0,"The display does not accept $label (its EDID allows deep colour for RGB only).");
  }
 }
 return (1,"");
}

# Highest TMDS rate the link may carry: the lower of board and display.
sub _tmds_limit {
 my ($board,$d)=@_;
 my $board_max=($board && $board->{max_tmds_mhz}) ? $board->{max_tmds_mhz} : 600;
 my ($limit,$by)=($board_max,"board");
 if($d && $d->{known}) {
  my $disp=$d->{max_tmds_mhz} || 0;
  $disp=340 if($disp == 0);
  # Above 340 MHz HDMI 2.0 scrambles the link, which needs SCDC.
  $disp=340 if($disp > 340 && !$d->{scdc});
  ($limit,$by)=($disp,"display") if($disp < $limit);
 }
 return ($limit,$by);
}

sub _fits {
 my ($req,$board,$d,$format,$bpc)=@_;
 return 0 if($format == 3);
 my ($ok)=_display_accepts($d,$format,$bpc);
 return 0 if(!$ok);
 my ($limit)=_tmds_limit($board,$d);
 my $tmds=signal_tmds_mhz($req->{clock_khz},$format,$bpc);
 return ($tmds <= $limit + 0.0005) ? 1 : 0;
}

# What would work at this mode instead (for the refusal message).
sub _alternatives {
 my ($req,$board,$d)=@_;
 my @alt;
 for my $format (0,1) {
  for my $bpc (12,10,8) {
   if(_fits($req,$board,$d,$format,$bpc)) {
    push(@alt,signal_format_label($format,$bpc));
    last;
   }
  }
 }
 push(@alt,"YCbCr 4:2:2") if(_fits($req,$board,$d,2,10));
 return \@alt;
}

# The same for a Dolby Vision request: its transport fixes the format
# (standard: RGB, 8 or 10 bit as in PGenerator 1.6; low latency: YCbCr
# 4:2:2 12-bit unless the display lists RGB / 4:4:4), so only other DV
# forms are offered. $v is the display's Dolby Vision block, if read.
sub _dv_alternatives {
 my ($req,$board,$d,$v,$lldv,$bpc)=@_;
 my @alt;
 my $ok=($v && !$v->{error}) ? $v : undef;
 if(!$lldv) {
  push(@alt,"8-bit Dolby Vision") if($bpc != 8 && _fits($req,$board,$d,0,8));
  push(@alt,"Dolby Vision (low latency)") if((!$ok || !defined $ok->{low_latency} || $ok->{low_latency}) && _fits($req,$board,$d,2,12));
 } else {
  push(@alt,"Dolby Vision (low latency) in YCbCr 4:2:2") if(int($req->{color_format} || 0) != 2 && _fits($req,$board,$d,2,12));
  push(@alt,"8-bit Dolby Vision") if((!$ok || !defined $ok->{standard} || $ok->{standard}) && _fits($req,$board,$d,0,8));
 }
 return \@alt;
}

sub _is_2160p_above30 {
 my ($req)=@_;
 return 0 if(!$req->{height} || $req->{height} < 2160 || $req->{interlaced});
 return (($req->{refresh} || 0) > 30.5) ? 1 : 0;
}

# $req:   {width,height,refresh,interlaced,clock_khz,color_format,max_bpc,
#          signal_mode (sdr|hdr10|hlg|dv),dv_transport (standard|lldv)}
# $board: signal_board_limits()
# $d:     PGEdidCaps caps ({known=>0} = no EDID: display checks skipped)
# %opt:   dv_vsvdb => PGEdidDolby block, dv_kernel => 0/1/undef
# Returns {ok, reason, code, tmds_mhz, limit_mhz, limit_by, alternatives,
#          adjustments => [text,...]}.
sub signal_check {
 my ($req,$board,$d,%opt)=@_;
 $d=$d || {known=>0};
 my $format=int($req->{color_format} || 0);
 my $bpc=int($req->{max_bpc} || 8);
 $bpc=8 if($bpc != 8 && $bpc != 10 && $bpc != 12);
 my $mode=lc($req->{signal_mode} || "sdr");
 my $dv=($mode eq "dv") ? 1 : 0;
 my $lldv=($dv && lc($req->{dv_transport} || "") eq "lldv") ? 1 : 0;
 my $where=signal_mode_label($req);
 my $label=signal_format_label($format,$bpc);
 my %r=(ok=>1,reason=>"",code=>"",tmds_mhz=>0,limit_mhz=>0,limit_by=>"",
        alternatives=>[],adjustments=>[]);
 my $refuse=sub {
  my ($code,$reason)=@_;
  @r{qw(ok code reason)}=(0,$code,$reason);
  return \%r;
 };

 return $refuse->("format","YCbCr 4:2:0 is not available: PGenerator+ has no 4:2:0 output. Choose RGB, YCbCr 4:4:4 or YCbCr 4:2:2.") if($format == 3);

 # 4:2:2 travels in a 12-bit container; the renderer draws it from 10-bit
 # codes (LLDV: 12-bit). Not a refusal, but say so.
 if($format == 2 && !$dv && $bpc != 10) {
  push(@{$r{adjustments}},"$bpc-bit YCbCr 4:2:2 is sent as 10-bit codes (4:2:2 is always a 12-bit HDMI container).");
  $bpc=10;
  $label=signal_format_label($format,$bpc);
 }

 # HDR and Dolby Vision as declared by the display.
 if($d->{known}) {
  if($mode eq "hdr10" && !$d->{has_hdr_st2084}) {
   return $refuse->("hdr","The display does not declare HDR10 (SMPTE ST 2084) in its EDID, so it would show the patches as SDR.");
  }
  if($mode eq "hlg" && !$d->{has_hdr_hlg}) {
   return $refuse->("hdr","The display does not declare HLG in its EDID, so it would show the patches as SDR.");
  }
  if($dv) {
   my $v=$opt{dv_vsvdb};
   if(!$d->{has_dv} && !($v && !$v->{error})) {
    return $refuse->("dv","The display does not declare Dolby Vision in its EDID.");
   }
   if($v && !$v->{error}) {
    if($lldv && defined $v->{low_latency} && !$v->{low_latency}) {
     return $refuse->("dv","The display accepts only standard (TV-led) Dolby Vision, not low latency.");
    }
    if(!$lldv && defined $v->{standard} && !$v->{standard}) {
     return $refuse->("dv","The display accepts only low-latency Dolby Vision. Choose the LLDV transport.");
    }
    # Version 0/1 blocks say whether TV-led DV runs at 2160p60; version 2
    # has no such flag, so nothing is assumed there.
    if(!$lldv && defined $v->{supports_2160p60} && !$v->{supports_2160p60} && _is_2160p_above30($req)) {
     $r{alternatives}=["3840x2160 at 30 Hz or less"];
     push(@{$r{alternatives}},"low-latency Dolby Vision") if($v->{low_latency});
     return $refuse->("dv","The display accepts TV-led Dolby Vision at 3840x2160 only up to 30 Hz (its Dolby Vision block has no 2160p60).");
    }
    # Low-latency DV in RGB/4:4:4 needs the "Low-Latency-HDMI" interface
    # and the 10/12-bit 4:4:4 flag of a version 2 block; otherwise the
    # display takes low-latency DV as YCbCr 4:2:2 12-bit only.
    if($lldv && $format != 2) {
     my $rgb=(($v->{interface} || "") =~ /Low-Latency-HDMI/) ? ($v->{ycc444} || "none") : "none";
     if($rgb ne "10" && $rgb ne "12") {
      $r{alternatives}=["YCbCr 4:2:2 12-bit (low latency)"];
      return $refuse->("dv","The display takes low-latency Dolby Vision as YCbCr 4:2:2 only; its Dolby Vision block lists no RGB / 4:4:4 form.");
     }
     if($rgb eq "10" && $bpc == 12) {
      $r{alternatives}=[signal_format_label($format,10)." (low latency)","YCbCr 4:2:2 12-bit (low latency)"];
      return $refuse->("dv","The display lists low-latency Dolby Vision in RGB / 4:4:4 at 10-bit only, not 12-bit.");
     }
    }
   }
  }
 }
 if($dv && defined $opt{dv_kernel} && !$opt{dv_kernel}) {
  return $refuse->("dv","This HDMI driver cannot send Dolby Vision metadata.");
 }

 # Colour format and deep colour.
 my ($accepts,$why)=_display_accepts($d,$format,$bpc);
 if(!$accepts) {
  $r{alternatives}=($dv ? _dv_alternatives($req,$board,$d,$opt{dv_vsvdb},$lldv,$bpc) : _alternatives($req,$board,$d)) if($req->{clock_khz});
  return $refuse->("format",$why);
 }

 # TMDS bandwidth.
 if($req->{clock_khz}) {
  my $tmds=signal_tmds_mhz($req->{clock_khz},$format,$bpc);
  my ($limit,$by)=_tmds_limit($board,$d);
  @r{qw(tmds_mhz limit_mhz limit_by)}=($tmds,$limit,$by);
  if($tmds > $limit + 0.0005) {
   my $who=($by eq "display")
    ? "the display accepts at most "._fmt_mhz($limit)
    : "the ".($board->{name} || "Raspberry Pi").($board->{port} ? " on ".$board->{port} : "")." sends at most "._fmt_mhz($limit);
   my $what=$dv ? signal_hdr_label($req)." ($label)" : $label;
   $r{alternatives}=$dv ? _dv_alternatives($req,$board,$d,$opt{dv_vsvdb},$lldv,$bpc) : _alternatives($req,$board,$d);
   return $refuse->("bandwidth","$what at ".($where ne "" ? $where : "this resolution")." needs "._fmt_mhz($tmds)." on the HDMI link; $who.");
  }
 }
 return \%r;
}

# The vendor infoframe in slot 1, as pgen_hdmi_packet prints it
# ("slot=1 enabled=1 type=81 version=01 length=1b bytes=<PB0>:..."), the
# same rules as the self-test: "standard" = HDMI 1.4b VSIF (OUI 00:0c:03)
# of length 0x18, the one the Pi sends for standard Dolby Vision; "lldv" =
# Dolby VSIF (OUI 00:d0:46, length 0x1b) with Dolby_Vision_Signal and
# Low_Latency set (PB4 bits 1 and 0); "" = no Dolby Vision signal (slot
# off or another vendor frame); undef = not readable.
sub signal_vsif_dv {
 my ($line)=@_;
 return undef if(!defined $line || $line!~/^slot=1 enabled=(\d) type=([0-9a-f]{2}) version=([0-9a-f]{2}) length=([0-9a-f]{2}) bytes=([0-9a-f:]*)/m);
 my ($on,$type,$ver,$len,@b)=($1,hex($2),hex($3),hex($4),map { hex($_) } split(/:/,$5));
 return "" if($on ne "1" || $type != 0x81 || $ver != 1 || $len < 4 || @b < $len+1);
 my $sum=$type+$ver+$len;
 $sum+=$b[$_] for(0..$len);
 return "" if($sum & 0xff);
 my $oui=sprintf("%02x:%02x:%02x",$b[3],$b[2],$b[1]);
 return "lldv" if($oui eq "00:d0:46" && $len == 0x1b && ($b[4] & 0x03) == 0x03);
 return "standard" if($oui eq "00:0c:03" && $len == 0x18);
 return "";
}

# What is on the cable, from the AVI and DRM infoframes of the last modeset
# (hex "82:02:0d:..", as vc4 logs them), the encoder's link readback
# ({bpc,tmds_mhz}, Pi 4 registers; undef where it cannot be read) and the
# vendor infoframe (signal_vsif_dv input; undef when not read).
# Returns {format,range,eotf,bpc,tmds_mhz,dv}; a field is undef when unknown.
sub signal_wire_from_infoframes {
 my ($avi,$drm,$link,$vsif)=@_;
 my %w=(format=>undef,range=>undef,eotf=>undef,bpc=>undef,tmds_mhz=>undef,dv=>undef);
 $w{dv}=signal_vsif_dv($vsif) if(defined $vsif);
 my @a=map {hex($_)} grep {/^[0-9a-fA-F]{1,2}$/} split(/:/,$avi || "");
 if(@a >= 9 && $a[0] == 0x82) {
  my %fmt=(0=>0,1=>2,2=>1,3=>3);     # AVI Y1Y0 -> conf color_format
  $w{format}=$fmt{($a[4] >> 5) & 3};
  if($w{format} == 0) {
   my $q=($a[6] >> 2) & 3;
   $w{range}=($q == 1) ? 1 : (($q == 2) ? 2 : undef);
  } else {
   $w{range}=((($a[8] >> 6) & 3) == 1) ? 2 : 1;
  }
  # No DRM frame after this AVI frame: SDR.
  $w{eotf}=0;
 }
 my @d=map {hex($_)} grep {/^[0-9a-fA-F]{1,2}$/} split(/:/,$drm || "");
 $w{eotf}=$d[4] if(@d >= 5 && $d[0] == 0x87);
 if($link && $link->{bpc}) {
  $w{bpc}=$link->{bpc};
  $w{tmds_mhz}=$link->{tmds_mhz} if($link->{tmds_mhz});
 }
 return \%w;
}

our %EOTF_NAME=(0=>"SDR",1=>"HDR (traditional)",2=>"HDR10 (PQ)",3=>"HLG");

our %DV_WIRE_NAME=(standard=>"Dolby Vision",lldv=>"Dolby Vision (low latency)");

# The parts of what is on the cable, for the label and the WebUI tiles:
# format (with the depth, except 4:2:2 which always rides a 12-bit
# container), name and depth (the same split for the tiles), range, mode
# (signal_mode_label) and signal (the Dolby Vision
# name from the vendor frame, else the EOTF of the DRM frame). Dolby Vision
# carries no DRM frame, so its EOTF reads as SDR: while the vendor frame is
# not read yet and the request ($req, as in signal_check) is DV, signal is
# empty rather than SDR. Undef when the wire is unknown.
sub signal_wire_parts {
 my ($w,$mode,$req)=@_;
 return undef if(!defined $w->{format});
 my %range=(1=>"Limited",2=>"Full");
 # depth for the tiles: the link depth register, except 4:2:2, whose
 # register always reads 8 bpc (webui_hdmi_link_info) for the fixed 12-bit
 # container; "" when the register was not read.
 my $depth=($w->{format} == 2) ? "12-bit container" : ($w->{bpc} ? "$w->{bpc}-bit" : "");
 my %p=(format=>signal_format_label($w->{format},($w->{format} != 2) ? $w->{bpc} : 0),
  name=>signal_format_label($w->{format},0),depth=>$depth,
  range=>(defined $w->{range} && $range{$w->{range}}) ? $range{$w->{range}} : "",
  mode=>(defined $mode) ? $mode : "",signal=>"");
 if($w->{dv} && $DV_WIRE_NAME{$w->{dv}}) {
  $p{signal}=$DV_WIRE_NAME{$w->{dv}};
 } elsif(defined $w->{eotf} && (defined $w->{dv} || lc(($req || {})->{signal_mode} || "") ne "dv")) {
  $p{signal}=$EOTF_NAME{$w->{eotf}} || "EOTF $w->{eotf}";
 }
 return \%p;
}

# "8-bit RGB Full, 3840x2160 60 Hz, Dolby Vision": the same order as the
# requested label (signal_request_label).
sub signal_wire_label {
 my ($w,$mode,$req)=@_;
 my $p=signal_wire_parts($w,$mode,$req) || return "";
 my $s=$p->{format}.($p->{range} ne "" ? " $p->{range}" : "");
 $s.=", $p->{mode}" if($p->{mode} ne "");
 $s.=", $p->{signal}" if($p->{signal} ne "");
 return $s;
}

# Quiet adjustments: where the cable differs from the settings ($req as in
# signal_check, plus rgb_quant_range 1/2 as resolved for the wire). For
# Dolby Vision only its signalling is compared: the transport sets format,
# depth and range itself.
sub signal_wire_adjustments {
 my ($req,$w)=@_;
 my @adj;
 my $mode=lc($req->{signal_mode} || "sdr");
 if(defined $w->{dv}) {
  my $want=($mode ne "dv") ? "" : ((lc($req->{dv_transport} || "") eq "lldv") ? "lldv" : "standard");
  if($w->{dv} ne $want) {
   push(@adj,signal_hdr_label($req)." setting is sent ".($w->{dv} eq "" ? "without Dolby Vision signalling." : "with ".($mode eq "dv" ? "the $DV_WIRE_NAME{$w->{dv}} signal." : "Dolby Vision signalling.")));
  }
 }
 return \@adj if($mode eq "dv" || !defined $w->{format});
 my $format=int($req->{color_format} || 0);
 my $bpc=int($req->{max_bpc} || 8);
 if($w->{format} != $format) {
  push(@adj,signal_format_label($format)." setting is sent as ".signal_format_label($w->{format}).".");
 } elsif($format != 2 && $w->{bpc} && $w->{bpc} != $bpc) {
  push(@adj,"$bpc-bit setting is sent as $w->{bpc}-bit.");
 }
 my %range=(1=>"Limited",2=>"Full");
 my $rr=int($req->{rgb_quant_range} || 0);
 if($format == 0 && $w->{format} == 0 && $range{$rr} && defined $w->{range} && $w->{range} != $rr) {
  push(@adj,"$range{$rr} range setting is signalled as $range{$w->{range}}.");
 }
 my %want=(sdr=>0,hdr10=>2,hlg=>3);
 if(defined $w->{eotf} && exists $want{$mode} && $w->{eotf} != $want{$mode}) {
  push(@adj,signal_hdr_label($req)." setting is sent as ".($EOTF_NAME{$w->{eotf}} || "EOTF $w->{eotf}").".");
 }
 return \@adj;
}

# The range fields of an AVI infoframe (hex as in signal_wire_from_infoframes):
# {format (conf color_format), q (PB3 bits 3:2), yq (PB5 bits 7:6), vic
# (PB4)}, undef when it is not an AVI frame. Bit layout as edid-decode's
# parse-if.cpp reads it.
sub signal_avi_fields {
 my ($avi)=@_;
 my @a=map {hex($_)} grep {/^[0-9a-fA-F]{1,2}$/} split(/:/,$avi || "");
 return undef if(@a < 9 || $a[0] != 0x82);
 my %fmt=(0=>0,1=>2,2=>1,3=>3);
 my $f=$fmt{($a[4] >> 5) & 3};
 return {format=>$f,q=>($a[6] >> 2) & 3,yq=>($a[8] >> 6) & 3,vic=>$a[7]};
}

our %RANGE_NAME=(1=>"Limited",2=>"Full");
our %Q_NAME=(0=>"Default",1=>"Limited",2=>"Full",3=>"Reserved");

# How the display decodes the range while its own range setting (HDMI black
# level, RGB range) is on Auto, from the AVI infoframe on the cable ($avi)
# and what the display declares in its EDID ($caps from PGEdidCaps: VCDB QS
# and QY), compared with the range of the codes on the cable ($codes: 1
# Limited, 2 Full). Rules as CTA-861 is quoted and implemented in Linux
# drm_edid.c (drm_default_rgb_quant_range, drm_hdmi_avi_infoframe_quant_range)
# and edid-decode (cta_vcdb):
#  RGB: Q=0 (Default) is the default range of the video format, Limited
#   for a CTA format with a VIC above 1, Full for VIC 1 (640x480) and IT
#   formats. A display that sets QS follows a non-zero Q. One that does not
#   is only bound to the default: a Q that differs from it may be ignored.
#   Without a VIC (0) the display may still take the timing for a CTA
#   format, so Default is not certain either. RGB ignores YQ.
#  YCbCr: YQ=0 is Limited. YQ=1 (Full) is certain only when the display
#   sets QY.
# Returns {verdict,expect,codes,format,q,yq,vic,qs,qy,basis,reason}: verdict
# "match" or "mismatch" (expect 1/2 against codes), "uncertain" (expect
# undef: the plate on screen decides) or "unknown" (no infoframe or no code
# range); qs/qy are undef without an EDID.
sub signal_range_expectation {
 my ($caps,$avi,$codes)=@_;
 my $f=signal_avi_fields($avi);
 my $known=($caps && $caps->{known}) ? 1 : 0;
 my %e=(verdict=>"unknown",expect=>undef,codes=>($codes && $RANGE_NAME{$codes}) ? $codes : undef,
  format=>undef,q=>undef,yq=>undef,vic=>undef,
  qs=>$known ? ($caps->{quant_rgb_selectable} ? 1 : 0) : undef,
  qy=>$known ? ($caps->{quant_ycc_selectable} ? 1 : 0) : undef,
  basis=>"",reason=>"");
 if(!$f) {
  @e{qw(basis reason)}=("no_avi","No AVI infoframe was read: no display is connected or the kernel log no longer has it.");
  return \%e;
 }
 @e{qw(format q yq vic)}=@$f{qw(format q yq vic)};
 my ($expect,$basis,$why);
 if($f->{format} == 0) {
  my $q=$f->{q};
  my $vic=$f->{vic};
  my $default=($vic > 1) ? 1 : 2;
  my $fmt=($vic > 1) ? "VIC $vic, a CTA video format" : (($vic == 1) ? "VIC 1 (640x480), an IT format" : "a timing without a VIC (0), an IT format");
  my $sent="The Pi signals RGB ".(($q == 0) ? "with the range flag on Default" : $Q_NAME{$q})." (AVI Q=$q) on $fmt";
  if($q == 3) {
   ($basis,$why)=("q_reserved","$sent: Q=3 is reserved, so no range is signalled.");
  } elsif($q == 0 && $vic == 0) {
   ($basis,$why)=("default_novic","$sent. Its default is Full, but a display that takes the timing for a video format decodes it as Limited.");
  } elsif($q == 0) {
   ($expect,$basis,$why)=($default,$vic > 1 ? "default_ce" : "default_it","$sent, whose default range is $RANGE_NAME{$default}.");
  } elsif($e{qs}) {
   ($expect,$basis,$why)=($q,"q","$sent. The display declares in its EDID that it follows the range flag (VCDB QS=1).");
  } elsif($q == $default) {
   ($expect,$basis,$why)=($q,"q_default","$sent, which is also the default range of that format.");
  } else {
   ($basis,$why)=("q_unsupported","$sent. That is not its default ($RANGE_NAME{$default}), and ".($known ? "the display does not declare that it follows the range flag (VCDB QS=0), so it may decode it as $RANGE_NAME{$default}." : "without an EDID it is not known whether the display follows the range flag."));
  }
 } else {
  my $yq=$f->{yq};
  my $sent="The Pi signals ".signal_format_label($f->{format})." ".(($yq <= 1) ? $RANGE_NAME{$yq+1} : "with a reserved range")." (AVI YQ=$yq)";
  if($yq == 0) {
   ($expect,$basis,$why)=(1,"yq_limited","$sent.");
  } elsif($yq == 1 && $e{qy}) {
   ($expect,$basis,$why)=(2,"yq","$sent. The display declares in its EDID that it follows the YCbCr range flag (VCDB QY=1).");
  } elsif($yq == 1) {
   ($basis,$why)=("yq_unsupported","$sent, but ".($known ? "the display does not declare that it follows the YCbCr range flag (VCDB QY=0)" : "without an EDID it is not known whether the display follows the YCbCr range flag").", so it may decode it as Limited.");
  } else {
   ($basis,$why)=("yq_reserved","$sent: YQ=$yq is reserved.");
  }
 }
 $e{basis}=$basis;
 if(!defined $e{codes}) {
  $e{reason}="$why The range of the codes on the cable is not known.";
  return \%e;
 }
 my $codes_txt="the Pi sends $RANGE_NAME{$e{codes}} codes";
 if(!defined $expect) {
  $e{verdict}="uncertain";
  $e{reason}="$why Whether the display on Auto matches the $RANGE_NAME{$e{codes}} codes is not certain: the Range Check on screen shows how it decodes.";
  return \%e;
 }
 $e{expect}=$expect;
 if($expect == $e{codes}) {
  $e{verdict}="match";
  $e{reason}="$why On Auto the display decodes $RANGE_NAME{$expect} and $codes_txt: match.";
 } else {
  $e{verdict}="mismatch";
  $e{reason}="$why On Auto the display decodes $RANGE_NAME{$expect}, but $codes_txt: mismatch. Set the display's range to $RANGE_NAME{$e{codes}} by hand or change the Pi's output range.";
 }
 return \%e;
}

# The two lines the Range Check draws for signal_range_expectation, in the
# glyphs of its stroke font (PGG1Patterns %SFONT): the verdict, then the
# basis ("AUTO DECODES LIMITED   QS 1   Q LIMITED   VIC 16").
sub signal_range_plate_lines {
 my ($e)=@_;
 return undef if(!$e);
 my %word=(match=>"MATCH",mismatch=>"MISMATCH",uncertain=>"UNCERTAIN",unknown=>"NO DATA");
 my $word=$word{$e->{verdict} || "unknown"} || "NO DATA";
 return [$word,"NO INFOFRAME READ"] if(!defined $e->{format});
 my $sp="   ";
 my $auto="AUTO DECODES ".(defined $e->{expect} ? uc($RANGE_NAME{$e->{expect}}) : "FULL OR LIMITED");
 my @p=($auto);
 if($e->{format} == 0) {
  push(@p,defined $e->{qs} ? "QS $e->{qs}" : "NO EDID","Q ".uc($Q_NAME{$e->{q}}),"VIC $e->{vic}");
 } else {
  my %yq=(0=>"LIMITED",1=>"FULL");
  push(@p,defined $e->{qy} ? "QY $e->{qy}" : "NO EDID","YQ ".($yq{$e->{yq}} || "RESERVED"));
 }
 return [$word,join($sp,@p)];
}

1;
