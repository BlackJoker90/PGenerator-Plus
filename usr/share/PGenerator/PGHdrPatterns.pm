#!/usr/bin/perl
#
# HDR Steps and the HDR Metadata Cycle plate: grey bars at absolute
# luminances, each drawn at the code SMPTE ST 2084 (PQ) gives it.
#
# - HDR Steps: bars up to the mastering peak the HDR10 metadata names
#   (MaxDML, the Max Luma setting). A display that clips below it shows the
#   bars above its own peak alike.
# - HDR Metadata Cycle: the same bars up to 10000 cd/m2, unchanged while
#   webui.pm steps the metadata; the caption names the step on the cable.
#
# Codes follow BT.2100 Table 9: narrow range D = Round[(219 E' + 16) 2^(n-8)],
# full range D = Round[(2^n - 1) E'], with E' the PQ signal of the luminance.
# Pure Perl, no daemon state: t/hdr_patterns.t runs it on the workstation.
#
package PGHdrPatterns;

use strict;
use warnings;
use Exporter qw(import);
use PGMath;
use PGG1Patterns;

our @EXPORT_OK=qw(hdr_pq_code hdr_steps_levels hdr_cycle_levels hdr_cycle_peaks hdr_plate_render);

our $VERSION="1";

# Luminances a bar can take, in cd/m2.
my @LADDER=(10,20,30,40,50,60,80,100,150,200,300,400,500,600,700,800,900,1000,
            1200,1500,2000,2500,3000,4000,5000,6000,8000,10000);
our $MAX_BARS=16;
# The bars together stay under a tenth of the screen, so an OLED's
# brightness limiter does not move the point where the bars merge.
our $MAX_BAR_AREA=0.10;
# Text and captions, in cd/m2: readable, far below the bars that matter.
my ($TEXT_NITS,$DIM_NITS)=(60,20);

# Code of $nits at $bits (8 or 10) in narrow ($limited) or full range.
sub hdr_pq_code {
 my ($nits,$bits,$limited)=@_;
 $bits=(defined($bits) && int($bits) == 10) ? 10 : 8;
 my $e=PGMath::pq_encode_normalized($nits);
 return int(($e*219+16)*(1 << ($bits-8))+0.5) if($limited);
 return int($e*((1 << $bits)-1)+0.5);
}

# Bars of HDR Steps for a mastering peak: the ladder below it, then the
# peak itself, the upper $MAX_BARS of them. The peak is the integer the
# renderer sends as MaxDML (updateHDR_Infoframe truncates the conf value).
sub hdr_steps_levels {
 my $max=shift;
 $max=0 if(!defined($max) || $max!~/^\d+(?:\.\d+)?$/);
 $max=int($max);
 $max=10000 if($max > 10000);
 return () if($max < 1);
 my @levels=((grep { $_ < $max } @LADDER),$max);
 splice(@levels,0,scalar(@levels)-$MAX_BARS) if(@levels > $MAX_BARS);
 return @levels;
}

# The cycle's picture: bars up to the PQ ceiling, whatever the metadata says.
sub hdr_cycle_levels {
 return (100,200,400,600,800,1000,1500,2000,3000,4000,6000,8000,10000);
}

# Mastering peak and MaxCLL of each step, in cd/m2.
sub hdr_cycle_peaks {
 return (600,1000,2000,4000,10000);
}

# Largest font scale (5x7 font, 6 columns a character) at which $chars
# characters fit into $room pixels, from $want down to 1.
sub _fit_scale {
 my ($chars,$room,$want)=@_;
 my $s=$want;
 $s-- while($s > 1 && ($chars*6-1)*$s > $room);
 return $s < 1 ? 1 : $s;
}

# hdr_plate_render($w,$h,\%opt)
#  opt: bits    => 8 | 10          depth of the codes (10: 16-bit samples,
#                                   as the G1 10-bit plates)
#       limited => 0 | 1           narrow or full range codes
#       levels  => [cd/m2, ...]    the bars, left to right
#       title   => text above the bars
#       lines   => [text, ...]     caption under the bars
# Returns {img => {w,h,buf[,depth]}, bars => [{nits,code,x1,y1,x2,y2}, ...],
# black => code} with [x1,x2) x [y1,y2) per bar, or undef when there is
# nothing to draw.
sub hdr_plate_render {
 my ($w,$h,$o)=@_;
 $o={} if(ref($o) ne "HASH");
 $w=int($w || 0); $h=int($h || 0);
 return undef if($w < 64 || $h < 64);
 my $bits=(int($o->{bits} || 8) == 10) ? 10 : 8;
 my $lim=$o->{limited} ? 1 : 0;
 my @levels=grep { defined($_) && /^\d+$/ && $_ >= 0 && $_ <= 10000 } @{ref($o->{levels}) eq "ARRAY" ? $o->{levels} : []};
 return undef if(!@levels);
 my $grey=sub { my $c=hdr_pq_code($_[0],$bits,$lim); return [$c,$c,$c]; };
 my $black=$grey->(0);
 my $im=($bits == 10) ? PGG1Patterns::_img10($w,$h,$black) : PGG1Patterns::_img($w,$h,$black);
 my ($text,$dim)=($grey->($TEXT_NITS),$grey->($DIM_NITS));
 my $n=scalar(@levels);
 my $area_x=int($w*0.07);
 my $area_w=$w-2*$area_x;
 my $by1=int($h*0.36);
 my $bh=int($h*0.145);
 my $want=int($h/360+0.5);
 $want=2 if($want < 2);
 my @bars;
 my $slot_min=$area_w;
 for(my $i=0;$i<$n;$i++) {
  my $sx1=$area_x+int($i*$area_w/$n);
  my $sx2=$area_x+int(($i+1)*$area_w/$n);
  my $gap=int(($sx2-$sx1)*0.11);
  $gap=1 if($gap < 1);
  my ($x1,$x2)=($sx1+$gap,$sx2-$gap);
  ($x1,$x2)=($sx1,$sx2) if($x2 <= $x1);
  my $c=$grey->($levels[$i]);
  PGG1Patterns::_fill($im,$x1,$by1,$x2,$by1+$bh,$c);
  push(@bars,{nits => $levels[$i], code => $c->[0], x1 => $x1, y1 => $by1, x2 => $x2, y2 => $by1+$bh, sx1 => $sx1, sx2 => $sx2});
  $slot_min=$sx2-$sx1 if($sx2-$sx1 < $slot_min);
 }
 # One scale for every label of a row, so the row reads as a scale.
 my ($nits_chars,$code_chars)=(1,1);
 for my $b (@bars) {
  $nits_chars=length($b->{nits}) if(length($b->{nits}) > $nits_chars);
  $code_chars=length($b->{code}) if(length($b->{code}) > $code_chars);
 }
 my $ns=_fit_scale($nits_chars,$slot_min-2,$want);
 my $cs=_fit_scale($code_chars,$slot_min-2,$want > 2 ? $want-1 : $want);
 $cs=$ns if($cs > $ns);
 my $ny=$by1+$bh+int($h*0.035);
 my $cy=$ny+7*$ns+int($h*0.022);
 for my $b (@bars) {
  my $cx=($b->{sx1}+$b->{sx2})/2;
  PGG1Patterns::_text_center($im,$b->{nits},$cx,$ny+3.5*$ns,$ns,$text);
  PGG1Patterns::_text_center($im,$b->{code},$cx,$cy+3.5*$cs,$cs,$dim);
  delete @$b{qw(sx1 sx2)};
 }
 # Row names left of the first bar, where the margin holds them: clear of
 # the screen edge an overscanning display cuts off.
 my $edge=int($w*0.025);
 my $room=$area_x-$edge-int($w*0.008);
 my $ls=_fit_scale(5,$room,$cs);
 if($room >= (5*6-1)*$ls) {
  my $lx=$area_x-int($w*0.008)-(5*6-1)*$ls;
  PGG1Patterns::_text($im,"CD/M2",$lx,$ny+int((7*$ns-7*$ls)/2),$ls,$dim);
  PGG1Patterns::_text($im,"CODE",$lx,$cy+int((7*$cs-7*$ls)/2),$ls,$dim);
 }
 my $title=defined($o->{title}) ? "$o->{title}" : "";
 if($title ne "") {
  my $ts=_fit_scale(length($title),$area_w,$want+1);
  PGG1Patterns::_text_center($im,$title,$w/2,int($h*0.2),$ts,$text);
 }
 my $ly=$cy+7*$cs+int($h*0.09);
 for my $line (@{ref($o->{lines}) eq "ARRAY" ? $o->{lines} : []}) {
  next if(!defined($line) || $line eq "");
  my $s=_fit_scale(length($line),$area_w,$want);
  PGG1Patterns::_text_center($im,$line,$w/2,$ly+3.5*$s,$s,$dim);
  $ly+=7*$s+int($h*0.03);
 }
 return {img => $im, bars => \@bars, black => $black->[0]};
}

1;
