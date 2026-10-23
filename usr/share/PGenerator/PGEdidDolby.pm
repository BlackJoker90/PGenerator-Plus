package PGEdidDolby;

# Dolby Vision Vendor-Specific Video Data Block (VSVDB) from a raw EDID: what
# the display declares about itself (versions 0, 1 and 2). Bit layout as in
# edid-decode's cta_dolby_video() (v4l-utils, parse-cta-block.cpp). The
# target max/min luminance is the display's own peak and black: TV-led DV
# should be mastered to that peak, and LLDV codes above it are clipped by
# the display.

use strict;
use warnings;
use Exporter qw(import);
use File::Basename ();
use lib File::Basename::dirname(__FILE__);
use PGMath qw(pq_decode_nits);

our @EXPORT_OK=qw(dolby_vsvdb_from_edid dolby_vsvdb_parse dolby_vsvdb_json);

our %V2_INTERFACE=(
 0=>"Low-Latency",
 1=>"Low-Latency + Low-Latency-HDMI",
 2=>"Standard + Low-Latency",
 3=>"Standard + Low-Latency + Low-Latency-HDMI",
);

# Raw EDID bytes -> parsed block (hashref) or undef when there is none.
sub dolby_vsvdb_from_edid {
 my ($edid)=@_;
 return undef if(!defined $edid || length($edid) < 256);
 my @b=unpack("C*",$edid);
 for(my $ext=128;$ext+128<=@b;$ext+=128) {
  next if($b[$ext] != 0x02);       # CTA-861 extension
  my $dtd=$b[$ext+2];
  next if($dtd < 4 || $dtd > 127);
  my $i=$ext+4;
  while($i < $ext+$dtd) {
   my $tag=$b[$i] >> 5;
   my $len=$b[$i] & 0x1f;
   last if($i+$len >= $ext+$dtd);   # block would run into the DTDs
   # Extended tag 1 = VSVDB, OUI 00-D0-46 (little endian in the block)
   if($tag == 7 && $len >= 5 && $b[$i+1] == 0x01 &&
      $b[$i+2] == 0x46 && $b[$i+3] == 0xd0 && $b[$i+4] == 0x00) {
    my @payload=@b[$i+5 .. $i+$len];
    return dolby_vsvdb_parse(\@payload);
   }
   $i+=$len+1;
  }
 }
 return undef;
}

sub _pq12_nits { my ($pq)=@_; return pq_decode_nits($pq/4095); }

# Payload after the OUI (edid-decode's x[]) -> hashref.
sub dolby_vsvdb_parse {
 my ($x)=@_;
 my $length=scalar(@$x);
 return undef if($length < 1);
 my %d=(version=>($x->[0] >> 5) & 0x07, length=>$length+5,
        yuv422_12bit=>($x->[0] & 0x01) ? 1 : 0);
 my $v=$d{version};
 if($v == 0) {
  return {%d,error=>"short"} if($length < 17);
  $d{supports_2160p60}=($x->[0] & 0x02) ? 1 : 0;
  $d{global_dimming}=($x->[0] & 0x04) ? 1 : 0;
  $d{dm_version}=($x->[16] >> 4).".".($x->[16] & 0xf);
  $d{min_pq}=($x->[14] << 4) | ($x->[13] >> 4);
  $d{max_pq}=($x->[15] << 4) | ($x->[13] & 0xf);
  $d{min_nits}=_pq12_nits($d{min_pq});
  $d{max_nits}=int(_pq12_nits($d{max_pq}));
  my $p=sub { my ($lo,$hx,$hy)=@_; return [(($x->[$lo] >> 4) | ($x->[$hx] << 4))/4096, (($x->[$lo] & 0xf) | ($x->[$hy] << 4))/4096]; };
  $d{primaries}={r=>$p->(1,2,3),g=>$p->(4,5,6),b=>$p->(7,8,9),w=>$p->(10,11,12)};
  $d{interface}="Standard";
  $d{standard}=1; $d{low_latency}=0;
  return \%d;
 }
 if($v == 1) {
  return {%d,error=>"short"} if($length < 7);
  $d{supports_2160p60}=($x->[0] & 0x02) ? 1 : 0;
  $d{global_dimming}=($x->[1] & 0x01) ? 1 : 0;
  $d{dm_version}=((($x->[0] >> 2) & 0x07)+2).".x";
  $d{colorimetry}=($x->[2] & 0x01) ? "P3-D65" : "BT.709";
  $d{low_latency}=($x->[3] & 0x01) ? 1 : 0;
  $d{standard}=1;
  $d{interface}=$d{low_latency} ? "Standard + Low-Latency" : "Standard";
  my $lm=($x->[2] >> 1)/127;
  $d{min_nits}=$lm*$lm;
  $d{max_nits}=100+($x->[1] >> 1)*50;
  if($length == 10) {
   $d{primaries}={r=>[$x->[4]/256,$x->[5]/256],g=>[$x->[6]/256,$x->[7]/256],b=>[$x->[8]/256,$x->[9]/256]};
  } else {
   my ($rx,$ry)=(0.625+(0.74609375-0.625)/31*($x->[6] >> 3),
                 0.25+(0.37109375-0.25)/31*((($x->[6] & 0x7) << 2) | ($x->[4] & 0x01) | (($x->[5] & 0x01) << 1)));
   my ($gx,$gy)=(0.49609375/127*($x->[4] >> 1), 0.5+(0.99609375-0.5)/127*($x->[5] >> 1));
   my ($bx,$by)=(0.125+(0.15234375-0.125)/7*($x->[3] >> 5), 0.03125+(0.05859375-0.03125)/7*(($x->[3] >> 2) & 0x07));
   $d{primaries}={r=>[$rx,$ry],g=>[$gx,$gy],b=>[$bx,$by]};
  }
  return \%d;
 }
 if($v == 2) {
  return {%d,error=>"short"} if($length < 7);
  $d{backlight_control}=($x->[0] & 0x02) ? 1 : 0;
  $d{global_dimming}=($x->[1] & 0x04) ? 1 : 0;
  $d{dm_version}=((($x->[0] >> 2) & 0x07)+2).".x";
  $d{backlight_min_nits}=25+($x->[1] & 0x03)*25;
  my $if=$x->[2] & 0x03;
  $d{interface}=$V2_INTERFACE{$if};
  $d{low_latency}=1;
  $d{standard}=($if >= 2) ? 1 : 0;
  $d{ycc444}=(qw(none 10 12 reserved))[(($x->[3] & 0x01) << 1) | ($x->[4] & 0x01)];
  $d{min_pq}=20*($x->[1] >> 3);
  $d{max_pq}=2055+65*($x->[2] >> 3);
  $d{min_nits}=_pq12_nits($d{min_pq});
  $d{max_nits}=int(_pq12_nits($d{max_pq}));
  $d{primaries}={
   r=>[0.625+($x->[5] >> 3)/256, 0.25+($x->[6] >> 3)/256],
   g=>[($x->[3] >> 1)/256, 0.5+($x->[4] >> 1)/256],
   b=>[0.125+($x->[5] & 0x07)/256, 0.03125+($x->[6] & 0x07)/256],
  };
  return \%d;
 }
 return {%d,error=>"unknown version"};
}

sub _num { my ($v,$places)=@_; my $s=sprintf("%.${places}f",$v); $s=~s/0+$//; $s=~s/\.$//; return $s eq "-0" ? "0" : $s; }

# Parsed block -> JSON object text ("null" without a block).
sub dolby_vsvdb_json {
 my ($d)=@_;
 return "null" if(!$d);
 my @f;
 foreach my $k (qw(version length yuv422_12bit supports_2160p60 global_dimming backlight_control
                  backlight_min_nits low_latency standard max_pq min_pq max_nits)) {
  push(@f,"\"$k\":".int($d->{$k})) if(defined $d->{$k});
 }
 push(@f,"\"min_nits\":"._num($d->{min_nits},6)) if(defined $d->{min_nits});
 foreach my $k (qw(interface dm_version colorimetry ycc444 error)) {
  push(@f,"\"$k\":\"$d->{$k}\"") if(defined $d->{$k});
 }
 if($d->{primaries}) {
  my @p;
  foreach my $c (qw(r g b w)) {
   next if(!$d->{primaries}{$c});
   push(@p,"\"$c\":["._num($d->{primaries}{$c}[0],5).","._num($d->{primaries}{$c}[1],5)."]");
  }
  push(@f,"\"primaries\":{".join(",",@p)."}");
 }
 return "{".join(",",@f)."}";
}

1;
