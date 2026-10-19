package PGG1Patterns;

# Specialty patterns of the Portrait Displays G1, as Calman selects them.
#
# Calman's G1 source (SOURCE_PPG_G1) sends SPECIALTY:<name> for most menu
# entries, IMAGE:IMAGE800.BMP / IMAGE:IMAGE801.BMP for Skintones and Granger,
# and plain patches for Full White / Full Black. The layouts and code values
# below were measured from Portrait Displays' published G1 captures and are
# authored in a 1920x1080 reference grid, scaled to the output size.
#
# Code values are what the G1 puts on the wire with Range=Limited. With
# Range=Full the video-level patterns are expanded (16..235 -> 0..255); the
# Brightness/Contrast step bars keep their labelled codes in both ranges,
# matching the G1 documentation.
#
# This module only builds RGB pixel buffers ({w,h,buf} with packed 8-bit
# RGB, the same layout as the WebUI image helpers). Writing files and
# driving the renderer is up to the caller.

use strict;
use warnings;
use Exporter qw(import);
use POSIX qw(floor);

our @EXPORT_OK=qw(g1_pattern_key g1_pattern_render g1_pattern_keys g1_pattern_level g1_pattern_has_10bit);

our $VERSION="2";

# Calman token (SPECIALTY:<token> or IMAGE:<token>) -> pattern key.
my %TOKEN=(
 "ALIGNMENT"     => "alignment",
 "BASIC"         => "basic_alignment",
 "BRIGHTNESS"    => "brightness",
 "CONTRAST"      => "contrast",
 # The Color Bars menu entry sends COLOR and then COLORBARS (both strstr
 # branches match its "Colorbars" action); both show the same pattern.
 "COLOR"         => "color_bars",
 "COLORBARS"     => "color_bars",
 "TINT"          => "tint",
 "SHARPNESS"     => "sharpness",
 "SMPTE"         => "smpte",
 "SCREENSAVER"   => "screensaver",
 "WARMUP"        => "warmup",
 "SPLIT21"       => "stair21",
 "SPLIT51"       => "stair51",
 "GRAYSCALE"     => "stair21",
 "H_RAMP"        => "ramp",
 "ANSI_CHECK_5N" => "checker_5n",
 "ANSI_CHECK_5I" => "checker_5i",
 "ANSI_CHECK_4N" => "checker_4n",
 "ANSI_CHECK_4I" => "checker_4i",
 "IMAGE800.BMP"  => "skintones",
 "IMAGE801.BMP"  => "granger",
);

my %RENDER=(
 "alignment"       => \&_alignment,
 "basic_alignment" => \&_basic_alignment,
 "brightness"      => \&_brightness,
 "contrast"        => \&_contrast,
 "color_bars"      => \&_color_bars,
 "tint"            => \&_tint,
 "sharpness"       => \&_sharpness,
 "smpte"           => \&_smpte,
 "screensaver"     => \&_screensaver,
 "warmup"          => \&_warmup,
 "stair21"         => \&_stair21,
 "stair51"         => \&_stair51,
 "ramp"            => \&_ramp,
 "checker_5n"      => sub { _checker(5,0,@_) },
 "checker_5i"      => sub { _checker(5,1,@_) },
 "checker_4n"      => sub { _checker(4,0,@_) },
 "checker_4i"      => sub { _checker(4,1,@_) },
 "skintones"       => \&_skintones,
 "granger"         => \&_granger,
);

sub g1_pattern_keys { return sort keys %RENDER; }

# Output code for a video-level code (as measured with Range=Limited).
sub g1_pattern_level {
 my ($range,$v)=@_;
 return _lv({range => lc($range || "limited")},$v);
}

sub g1_pattern_key {
 my $token=uc("".(shift // ""));
 $token=~s/^\s+|\s+$//g;
 return $TOKEN{$token};
}

# g1_pattern_render($key,$w,$h,\%opt)
#  opt: range  => "limited" | "full"   (default limited)
#       ip     => address shown on the Warm-Up box
#       photo  => {w,h,buf} at $w x $h for Skintones (optional)
#       logo   => {w,h,buf} for Screensaver (optional)
#       bits   => 10 for the 10-bit Brightness/Contrast plates (see
#                 g1_pattern_has_10bit); their img has depth=>16 and a
#                 buf of 16-bit big-endian samples carrying 10-bit codes
# Returns {frames => [{img=>{w,h,buf}, ms=>N, x=>X, y=>Y}, ...], bg=>[r,g,b]}
# or undef for an unknown key. A frame with x/y set is drawn at that offset
# over a background filled with bg (used for the moving patterns).
sub g1_pattern_render {
 my ($key,$w,$h,$opt)=@_;
 my $render=$RENDER{$key || ""};
 return undef if(!$render);
 $w=int($w); $h=int($h);
 return undef if($w < 64 || $h < 64);
 my %o=%{$opt || {}};
 $o{range}=lc($o{range} || "limited");
 $o{range}="limited" if($o{range} ne "full");
 my $out=$render->($w,$h,\%o);
 return $out if(exists $out->{frames});
 return {frames => [{img => $out, ms => 0}]};
}

###############################################
#              Pixel primitives               #
###############################################

sub _img {
 my ($w,$h,$c)=@_;
 return {w => $w, h => $h, buf => pack("C3",@$c) x ($w*$h)};
}

# 10-bit plate: colours are 10-bit codes, stored as 16-bit samples
# round(code * 65535 / 1023) so a renderer that reads the sample as
# sample / 65535 and writes it to a 10-bit plane gets the code back exactly.
sub _img10 {
 my ($w,$h,$c)=@_;
 return {w => $w, h => $h, depth => 16, buf => _px($c,16) x ($w*$h)};
}

sub _clamp8 { my $v=int(shift); return $v < 0 ? 0 : ($v > 255 ? 255 : $v); }

sub _s16 {
 my $v=int(shift);
 $v=0 if($v < 0); $v=1023 if($v > 1023);
 return int($v*65535/1023+0.5);
}

# One packed pixel for an 8-bit or 16-bit image.
sub _px {
 my ($c,$depth)=@_;
 return pack("n3",map { _s16($_) } @$c) if(($depth || 8) == 16);
 return pack("C3",@$c);
}

# Fill [x1,x2) x [y1,y2).
sub _fill {
 my ($im,$x1,$y1,$x2,$y2,$c)=@_;
 $x1=0 if($x1 < 0); $y1=0 if($y1 < 0);
 $x2=$im->{w} if($x2 > $im->{w}); $y2=$im->{h} if($y2 > $im->{h});
 return if($x2 <= $x1 || $y2 <= $y1);
 my $bpp=(($im->{depth} || 8) == 16) ? 6 : 3;
 my $row=_px($c,$im->{depth}) x ($x2-$x1);
 my $len=length($row);
 my $stride=$im->{w}*$bpp;
 for(my $y=$y1;$y<$y2;$y++) {
  substr($im->{buf},$y*$stride+$x1*$bpp,$len,$row);
 }
}

sub _frame {
 my ($im,$t,$c)=@_;
 my ($w,$h)=($im->{w},$im->{h});
 _fill($im,0,0,$w,$t,$c);
 _fill($im,0,$h-$t,$w,$h,$c);
 _fill($im,0,0,$t,$h,$c);
 _fill($im,$w-$t,0,$w,$h,$c);
}

# Copy a packed row segment (already RGB) into rows [y1,y2) at x.
sub _row_copy {
 my ($im,$x,$y1,$y2,$row)=@_;
 my $stride=$im->{w}*3;
 for(my $y=$y1;$y<$y2;$y++) {
  substr($im->{buf},$y*$stride+$x*3,length($row),$row);
 }
}

# Annulus of radius r (centre line), thickness t, centred on cx,cy.
sub _ring {
 my ($im,$cx,$cy,$r,$t,$c)=@_;
 my $ro=$r+$t/2;
 my $ri=$r-$t/2;
 $ri=0 if($ri < 0);
 for(my $y=int($cy-$ro)-1;$y<=int($cy+$ro)+1;$y++) {
  my $dy=$y+0.5-$cy;
  next if(abs($dy) > $ro);
  my $xo=sqrt($ro*$ro-$dy*$dy);
  if(abs($dy) >= $ri) {
   _fill($im,int($cx-$xo+0.5),$y,int($cx+$xo+0.5),$y+1,$c);
   next;
  }
  my $xi=sqrt($ri*$ri-$dy*$dy);
  _fill($im,int($cx-$xo+0.5),$y,int($cx-$xi+0.5),$y+1,$c);
  _fill($im,int($cx+$xi+0.5),$y,int($cx+$xo+0.5),$y+1,$c);
 }
}

# Straight line of thickness t from (x1,y1) to (x2,y2).
sub _line {
 my ($im,$x1,$y1,$x2,$y2,$t,$c)=@_;
 my $len=sqrt(($x2-$x1)**2+($y2-$y1)**2);
 my $steps=int($len*2)+1;
 my $half=$t/2;
 for(my $i=0;$i<=$steps;$i++) {
  my $x=$x1+($x2-$x1)*$i/$steps;
  my $y=$y1+($y2-$y1)*$i/$steps;
  _fill($im,int($x-$half+0.5),int($y-$half+0.5),int($x-$half+0.5)+$t,int($y-$half+0.5)+$t,$c);
 }
}

# 5x7 bitmap font: digits, upper case letters and a few symbols.
my %FONT=(
 "0"=>"01110100011001110101110011000101110", "1"=>"00100011000010000100001000010001110",
 "2"=>"01110100010000100010001000100011111", "3"=>"11111000100010000010000011000101110",
 "4"=>"00010001100101010010111110001000010", "5"=>"11111100001111000001000011000101110",
 "6"=>"00110010001000011110100011000101110", "7"=>"11111000010001000100010000100001000",
 "8"=>"01110100011000101110100011000101110", "9"=>"01110100011000101111000010001001100",
 "A"=>"01110100011000111111100011000110001", "B"=>"11110100011000111110100011000111110",
 "C"=>"01110100011000010000100001000101110", "D"=>"11100100101000110001100011001011100",
 "E"=>"11111100001000011110100001000011111", "F"=>"11111100001000011110100001000010000",
 "G"=>"01110100011000010111100011000101111", "H"=>"10001100011000111111100011000110001",
 "I"=>"01110001000010000100001000010001110", "J"=>"00111000100001000010000101001001100",
 "K"=>"10001100101010011000101001001010001", "L"=>"10000100001000010000100001000011111",
 "M"=>"10001110111010110101100011000110001", "N"=>"10001100011100110101100111000110001",
 "O"=>"01110100011000110001100011000101110", "P"=>"11110100011000111110100001000010000",
 "Q"=>"01110100011000110001101011001001101", "R"=>"11110100011000111110101001001010001",
 "S"=>"01111100001000001110000010000111110", "T"=>"11111001000010000100001000010000100",
 "U"=>"10001100011000110001100011000101110", "V"=>"10001100011000110001100010101000100",
 "W"=>"10001100011000110101101011010101010", "X"=>"10001100010101000100010101000110001",
 "Y"=>"10001100011000101010001000010000100", "Z"=>"11111000010001000100010001000011111",
 ":"=>"00000011000110000000011000110000000", "."=>"00000000000000000000000000110001100",
 "-"=>"00000000000000011111000000000000000", "+"=>"00000001000010011111001000010000000",
 "/"=>"00000000010001000100010001000000000", " "=>"00000000000000000000000000000000000",
);

sub _text_width {
 my ($text,$s)=@_;
 my $n=length($text);
 return 0 if(!$n);
 return ($n*6-1)*$s;
}

sub _text {
 my ($im,$text,$x,$y,$s,$c)=@_;
 $text=uc($text);
 for my $ch (split(//,$text)) {
  my $bits=$FONT{$ch} // $FONT{" "};
  for(my $row=0;$row<7;$row++) {
   my $col=0;
   while($col < 5) {
    if(substr($bits,$row*5+$col,1) ne "1") { $col++; next; }
    my $start=$col;
    $col++ while($col < 5 && substr($bits,$row*5+$col,1) eq "1");
    _fill($im,$x+$start*$s,$y+$row*$s,$x+$col*$s,$y+($row+1)*$s,$c);
   }
  }
  $x+=6*$s;
 }
}

sub _text_center {
 my ($im,$text,$cx,$cy,$s,$c)=@_;
 _text($im,$text,int($cx-_text_width($text,$s)/2+0.5),int($cy-3.5*$s+0.5),$s,$c);
}

###############################################
#             Geometry and levels             #
###############################################

# Map 1920x1080 reference coordinates to the output.
sub _sx { my ($w,$v)=@_; return int($v*$w/1920+0.5); }
sub _sy { my ($h,$v)=@_; return int($v*$h/1080+0.5); }

# Video-level code (as measured with Range=Limited) for the active range.
sub _lv {
 my ($o,$v)=@_;
 return _clamp8($v) if($o->{range} ne "full");
 return _clamp8(floor(($v-16)*255/219+0.5));
}

sub _lc { my ($o,@c)=@_; return [map { _lv($o,$_) } @c]; }

sub _border_t { my $h=shift; my $t=int($h/270+0.5); return $t < 2 ? 2 : $t; }

###############################################
#          Brightness / Contrast frame        #
###############################################

# Shared layout of Brightness, Contrast, Tint and Sharpness: a border, a
# block of three bars left and right, an optional centre panel and a
# 12-column step grid. Colours are listed left to right.
#
# Deliberately centred, unlike the G1 capture: the G1 puts the left block
# 40 px and the right block 50 px from the edge and its step grid at
# 488-1428 (centre 958). Here both blocks sit 40 px from the edge and the
# grid spans 490-1430, mirror-symmetric about the centre of the screen.
sub _plate {
 my ($w,$h,$bg,$border,$left,$right,$panel,$depth)=@_;
 my $im=(($depth || 8) == 16) ? _img10($w,$h,$bg) : _img($w,$h,$bg);
 _frame($im,_border_t($h),$border);
 my @lx=(40,140,240,340);
 my @rx=(1580,1680,1780,1880);
 for my $i (0..2) {
  _fill($im,_sx($w,$lx[$i]),_sy($h,140),_sx($w,$lx[$i+1]),_sy($h,940),$left->[$i]);
  _fill($im,_sx($w,$rx[$i]),_sy($h,140),_sx($w,$rx[$i+1]),_sy($h,940),$right->[$i]);
 }
 _fill($im,_sx($w,470),_sy($h,140),_sx($w,1450),_sy($h,940),$panel) if($panel);
 return $im;
}

sub _step_col { my ($w,$col)=@_; return (_sx($w,490+80*$col),_sx($w,550+80*$col)); }

# Step rows in reference units: 2 tall rows for the 8-bit plates (24 steps),
# 8 rows for the 10-bit plates (96 steps), as on the G1.
my @STEP_ROWS_8=([155,525],[555,925]);
my @STEP_ROWS_10=map { [155+100*$_,225+100*$_] } 0..7;

# Step bars, 12 per row, each labelled with its code and centred.
sub _steps {
 my ($im,$w,$h,$first,$mark,$label_c,$mark_c,$rows,$label_div)=@_;
 my $s=int($h/$label_div+0.5); $s=1 if($s < 1);
 for my $i (0..(12*scalar(@$rows)-1)) {
  my $v=$first+$i;
  my ($x1,$x2)=_step_col($w,$i % 12);
  my ($y1,$y2)=(_sy($h,$rows->[int($i/12)][0]),_sy($h,$rows->[int($i/12)][1]));
  _fill($im,$x1,$y1,$x2,$y2,[$v,$v,$v]);
  _text_center($im,"$v",($x1+$x2)/2,($y1+$y2)/2,$s,$v == $mark ? $mark_c : $label_c);
 }
}

# 8-bit plate codes on the 10-bit plates: times 4, and 255 (peak white)
# becomes 1023 like the top step of the 10-bit Contrast plate.
sub _c10 { return [map { $_ >= 255 ? 1023 : 4*$_ } @{$_[0]}]; }

sub _brightness {
 my ($w,$h,$o)=@_;
 # Step codes are the labelled values in both ranges; the plate around them
 # follows the same raw codes as the G1 capture. The right block is the
 # mirror of the left one (the G1 repeats it unmirrored), so the visible
 # bars sit symmetrically about the centre.
 my @dark=([0,0,0],[15,15,15],[31,31,31]);
 if(($o->{bits} || 8) == 10) {
  # 96 steps 0-95, marker at 64 (black on a 10-bit link).
  my @dark10=map { _c10($_) } @dark;
  my $im=_plate($w,$h,[0,0,0],_c10([63,63,63]),\@dark10,[reverse @dark10],undef,16);
  _steps($im,$w,$h,0,64,_c10([63,63,63]),_c10([180,16,16]),\@STEP_ROWS_10,1080);
  return $im;
 }
 my $im=_plate($w,$h,[0,0,0],[63,63,63],\@dark,[reverse @dark],undef);
 _steps($im,$w,$h,0,16,[63,63,63],[180,16,16],\@STEP_ROWS_8,540);
 return $im;
}

sub _contrast {
 my ($w,$h,$o)=@_;
 my @left=([0,0,0],[15,15,15],[31,31,31]);
 my @right=([224,224,224],[240,240,240],[255,255,255]);
 if(($o->{bits} || 8) == 10) {
  # 96 steps 928-1023, marker at 940 (reference white on a 10-bit link).
  my $im=_plate($w,$h,_c10([63,63,63]),_c10([255,255,255]),
   [map { _c10($_) } @left],[map { _c10($_) } @right],_c10([255,255,255]),16);
  _steps($im,$w,$h,928,940,_c10([128,128,128]),_c10([200,16,16]),\@STEP_ROWS_10,1080);
  return $im;
 }
 my $im=_plate($w,$h,[63,63,63],[255,255,255],\@left,\@right,[255,255,255]);
 _steps($im,$w,$h,232,235,[128,128,128],[200,16,16],\@STEP_ROWS_8,540);
 return $im;
}

# Plates with their own 10-bit layout on 10-bit links.
sub g1_pattern_has_10bit { my $k=shift // ""; return ($k eq "brightness" || $k eq "contrast") ? 1 : 0; }

sub _tint {
 my ($w,$h,$o)=@_;
 my $im=_plate($w,$h,_lc($o,16,16,16),_lc($o,72,72,72),
  [_lc($o,16,16,16),_lc($o,29,29,29),_lc($o,43,43,43)],
  [_lc($o,222,222,222),_lc($o,208,208,208),_lc($o,235,235,235)],
  undef);
 my %c=(
  M => _lc($o,235,16,235), C => _lc($o,16,235,235),
  W => _lc($o,235,235,235), B => _lc($o,16,16,235),
 );
 my @order=("MCWB","CMBW","WBMC","BWCM");
 my @rows=([155,340],[340,525],[555,740],[740,925]);
 for my $r (0..3) {
  for my $col (0..11) {
   my ($x1,$x2)=_step_col($w,$col);
   _fill($im,$x1,_sy($h,$rows[$r][0]),$x2,_sy($h,$rows[$r][1]),$c{substr($order[$r],$col % 4,1)});
  }
 }
 return $im;
}

sub _sharpness {
 my ($w,$h,$o)=@_;
 my $black=_lc($o,16,16,16);
 my $gray=_lc($o,70,70,70);
 my $im=_plate($w,$h,$black,_lc($o,235,235,235),
  [$black,_lc($o,29,29,29),_lc($o,43,43,43)],
  [_lc($o,208,208,208),_lc($o,222,222,222),_lc($o,235,235,235)],
  $gray);
 # Grid 490-1430 (centred; the G1 draws it at 488-1428), and every line is
 # centred on its position rather than starting there.
 my ($gx1,$gx2,$gy1,$gy2)=(_sx($w,490),_sx($w,1430),_sy($h,159),_sy($h,921));
 my @widths=(1,2,2,4,8);
 my $unit=$h/576;
 my (@vx,@hy);
 for my $i (0..4) {
  my $t=int($widths[$i]*$unit+0.5); $t=1 if($t < 1);
  my $x=_sx($w,660+150*$i)-int($t/2);
  my $y=_sy($h,319+110.6*$i)-int($t/2);
  _fill($im,$x,$gy1,$x+$t,$gy2,$black);
  _fill($im,$gx1,$y,$gx2,$y+$t,$black);
  push(@vx,[$x,$x+$t]);
  push(@hy,[$y,$y+$t]);
 }
 # Fine grids in the four cells around the centre: dense top-left and
 # bottom-right, coarse top-right and bottom-left.
 my $lt=int($h/1080+0.5); $lt=1 if($lt < 1);
 my @cells=(
  [$vx[1][1],$vx[2][0],$hy[1][1],$hy[2][0],$h/144],
  [$vx[2][1],$vx[3][0],$hy[1][1],$hy[2][0],$h/72],
  [$vx[1][1],$vx[2][0],$hy[2][1],$hy[3][0],$h/72],
  [$vx[2][1],$vx[3][0],$hy[2][1],$hy[3][0],$h/144],
 );
 for my $cell (@cells) {
  my ($x1,$x2,$y1,$y2,$pitch)=@$cell;
  my $ix=int(($x2-$x1)*0.09+0.5);
  my $iy=int(($y2-$y1)*0.11+0.5);
  ($x1,$x2,$y1,$y2)=($x1+$ix,$x2-$ix,$y1+$iy,$y2-$iy);
  for(my $x=$x1;$x<=$x2-$lt;$x+=$pitch) { _fill($im,int($x),$y1,int($x)+$lt,$y2,$black); }
  for(my $y=$y1;$y<=$y2-$lt;$y+=$pitch) { _fill($im,$x1,int($y),$x2,int($y)+$lt,$black); }
  _fill($im,$x2-$lt,$y1,$x2,$y2,$black);
  _fill($im,$x1,$y2-$lt,$x2,$y2,$black);
 }
 return $im;
}

###############################################
#           Color bars / alignment            #
###############################################

sub _color_bars {
 my ($w,$h,$o)=@_;
 my $im=_img($w,$h,_lc($o,70,70,70));
 _frame($im,int($h/288+0.5) || 1,_lc($o,235,235,235));
 my @hi=([235,235,235],[235,16,16],[16,235,16],[16,16,235],[16,235,235],[235,16,235],[235,235,16]);
 my $x0=int($w*54/1024+0.5);
 my $x1=$w-$x0;
 my $y0=int($h*27/576+0.5);
 my $y1=$h-$y0;
 my $ym=int($h/2+0.5);
 my $gy1=int($h*0.375+0.5);
 my $gy2=int($h*0.625+0.5);
 for my $i (0..6) {
  my $bx1=$x0+int($i*($x1-$x0)/7+0.5);
  my $bx2=$x0+int(($i+1)*($x1-$x0)/7+0.5);
  my @top=@{$hi[$i]};
  my @half=map { $_ == 235 ? 125 : 16 } @top;
  _fill($im,$bx1,$y0,$bx2,$ym,_lc($o,@top));
  _fill($im,$bx1,$ym,$bx2,$y1,_lc($o,@half));
  # Gradient box: black at the top to the full bar colour at the bottom.
  my $bw=$bx2-$bx1;
  my $gx1=$bx1+int($bw*0.25+0.5);
  my $gx2=$bx1+int($bw*0.75+0.5);
  for(my $y=$gy1;$y<$gy2;$y++) {
   my $t=($gy2-$gy1 > 1) ? ($y-$gy1)/($gy2-$gy1-1) : 1;
   my @c=map { $_ == 235 ? 16+int(219*$t+0.5) : 0 } @top;
   _fill($im,$gx1,$y,$gx2,$y+1,_lc($o,@c));
  }
 }
 return $im;
}

sub _target {
 my ($im,$w,$h,$ring_c,$spoke_c)=@_;
 my ($cx,$cy)=($w/2,$h/2);
 my $t=int($h/576+0.5); $t=1 if($t < 1);
 _ring($im,$cx,$cy,$h*$_/27,$t,$ring_c) for(2..6);
 my $len=$h*0.2135;
 my $st=int($h*1.5/576+0.5); $st=1 if($st < 1);
 for my $deg (90,210,330) {
  my $a=$deg*3.14159265358979/180;
  _line($im,$cx,$cy,$cx+$len*cos($a),$cy-$len*sin($a),$st,$spoke_c);
 }
}

sub _alignment {
 my ($w,$h,$o)=@_;
 my $im=_color_bars($w,$h,$o);
 _target($im,$w,$h,_lc($o,235,235,235),_lc($o,180,16,16));
 return $im;
}

sub _basic_alignment {
 my ($w,$h,$o)=@_;
 my $im=_img($w,$h,_lc($o,70,70,70));
 _frame($im,int($h/288+0.5) || 1,_lc($o,100,100,100));
 _target($im,$w,$h,_lc($o,112,112,112),_lc($o,160,16,16));
 return $im;
}

sub _smpte {
 my ($w,$h,$o)=@_;
 # The G1 SMPTE plate uses full-scale codes (0 black, 191 bars, 255 white).
 my $im=_img($w,$h,[0,0,0]);
 my $f=int($h*8/576+0.5);
 my ($x0,$x1,$y0,$y1)=($f,$w-$f,$f,$h-$f);
 my $iw=$x1-$x0;
 my $ih=$y1-$y0;
 my $ya=$y0+int($ih*0.652+0.5);
 my $yb=$ya+int($ih*0.0964+0.5);
 my $bx=sub { return $x0+int($_[0]*$iw/7+0.5); };
 my @top=([191,191,191],[191,191,0],[0,191,191],[0,191,0],[191,0,191],[191,0,0],[0,0,191]);
 my @mid=([0,0,191],[0,0,0],[191,0,191],[0,0,0],[0,191,191],[0,0,0],[191,191,191]);
 for my $i (0..6) {
  _fill($im,$bx->($i),$y0,$bx->($i+1),$ya,$top[$i]);
  _fill($im,$bx->($i),$ya,$bx->($i+1),$yb,$mid[$i]);
 }
 my @low=([0,15,62],[255,255,255],[32,0,88]);
 for my $i (0..2) {
  _fill($im,$x0+int($i*$iw/6+0.5),$yb,$x0+int(($i+1)*$iw/6+0.5),$y1,$low[$i]);
 }
 my ($p1,$p2)=($bx->(5),$bx->(6));
 my @pluge=(8,16,24);
 for my $i (0..2) {
  my $v=$pluge[$i];
  _fill($im,$p1+int($i*($p2-$p1)/3+0.5),$yb,$p1+int(($i+1)*($p2-$p1)/3+0.5),$y1,[$v,$v,$v]);
 }
 return $im;
}

###############################################
#             Grayscale patterns              #
###############################################

sub _stair21 {
 my ($w,$h,$o)=@_;
 my $im=_img($w,$h,[0,0,0]);
 my $ym=int($h/2+0.5);
 for my $i (0..20) {
  my ($x1,$x2)=(int($i*$w/21+0.5),int(($i+1)*$w/21+0.5));
  my $t=_lv($o,12*$i);
  my $b=_lv($o,255-12*$i);
  _fill($im,$x1,0,$x2,$ym,[$t,$t,$t]);
  _fill($im,$x1,$ym,$x2,$h,[$b,$b,$b]);
 }
 return $im;
}

sub _stair51 {
 my ($w,$h,$o)=@_;
 my $im=_img($w,$h,[0,0,0]);
 my $ym=int($h/2+0.5);
 my $cw=$w*40/1024;
 for(my $i=0;$i*$cw<$w;$i++) {
  my ($x1,$x2)=(int($i*$cw+0.5),int(($i+1)*$cw+0.5));
  my $t=_lv($o,17+8*$i);
  my $b=_lv($o,234-8*$i);
  _fill($im,$x1,0,$x2,$ym,[$t,$t,$t]);
  _fill($im,$x1,$ym,$x2,$h,[$b,$b,$b]);
 }
 return $im;
}

sub _ramp {
 my ($w,$h,$o)=@_;
 my $im=_img($w,$h,[0,0,0]);
 my $ym=int($h/2+0.5);
 my ($top,$bot)=("","");
 for(my $x=0;$x<$w;$x++) {
  my $p=1-abs(2*$x/($w-1)-1);
  my $v=16+int(219*$p+0.5);
  my $t=_lv($o,$v);
  my $b=_lv($o,251-$v);
  $top.=pack("C3",$t,$t,$t);
  $bot.=pack("C3",$b,$b,$b);
 }
 _row_copy($im,0,0,$ym,$top);
 _row_copy($im,0,$ym,$h,$bot);
 return $im;
}

sub _checker {
 my ($n,$inv,$w,$h,$o)=@_;
 my $im=_img($w,$h,[0,0,0]);
 my ($cw,$ch)=($w/4,$h/4);
 # 4x4: top-left white. 5x5: the grid is shifted half a cell so a cell
 # sits on the screen centre, which is black.
 my $off=($n == 5) ? 0.5 : 0;
 for my $r (-1..4) {
  for my $c (-1..4) {
   my $white=(($r+$c) % 2 == 0) ? 1 : 0;
   $white=1-$white if($n == 5);
   $white=1-$white if($inv);
   next if(!$white);
   my $x1=int(($c-$off)*$cw+0.5);
   my $y1=int(($r-$off)*$ch+0.5);
   _fill($im,$x1,$y1,int(($c+1-$off)*$cw+0.5),int(($r+1-$off)*$ch+0.5),[255,255,255]);
  }
 }
 return $im;
}

###############################################
#                  Granger                    #
###############################################

# Hue (degrees) across the screen, measured from the G1 Granger capture.
my @GRANGER_HUE=(
 [0,0],[0.09,0],[0.125,10],[0.156,24],[0.1875,36],[0.219,48],[0.25,55],
 [0.281,62],[0.3125,71],[0.344,81],[0.375,93],[0.406,108],[0.4375,129],
 [0.469,140],[0.5,149],[0.531,158],[0.5625,165],[0.594,175],[0.625,184],
 [0.656,190],[0.6875,201],[0.719,211],[0.75,221],[0.781,232],[0.8125,241],
 [0.844,256],[0.875,274],[0.906,293],[0.9375,309],[0.97,313],[1,318],
);

sub _granger_hue {
 my $f=shift;
 for my $i (1..$#GRANGER_HUE) {
  my ($a,$b)=($GRANGER_HUE[$i-1],$GRANGER_HUE[$i]);
  next if($f > $b->[0]);
  return $a->[1]+($b->[1]-$a->[1])*($f-$a->[0])/($b->[0]-$a->[0]);
 }
 return $GRANGER_HUE[-1][1];
}

sub _hue_rgb {
 my $hue=shift;
 $hue-=360*floor($hue/360);
 my $s=$hue/60;
 my $i=int($s);
 my $f=$s-$i;
 my @sextant=([1,$f,0],[1-$f,1,0],[0,1,$f],[0,1-$f,1],[$f,0,1],[1,0,1-$f]);
 return @{$sextant[$i % 6]};
}

# Each column holds one hue: it fades from white above the screen to the
# pure hue at a height set by its luma, then to black below the screen.
sub _granger {
 my ($w,$h,$o)=@_;
 my $im=_img($w,$h,[0,0,0]);
 my ($top_y,$bottom_y)=(-0.11,1.0);
 my $stride=$w*3;
 for(my $x=0;$x<$w;$x++) {
  my @c=_hue_rgb(_granger_hue($x/($w-1)));
  my $luma=0.2126*$c[0]+0.7152*$c[1]+0.0722*$c[2];
  my $knee=1-$luma**0.7;
  for(my $y=0;$y<$h;$y++) {
   my $fy=($y+0.5)/$h;
   my @p;
   if($fy < $knee) {
    my $t=($fy-$top_y)/($knee-$top_y);
    @p=map { 255+(255*$_-255)*$t } @c;
   } else {
    my $t=($fy-$knee)/($bottom_y-$knee);
    @p=map { 255*$_*(1-$t) } @c;
   }
   substr($im->{buf},$y*$stride+$x*3,3,pack("C3",map { _clamp8($_+0.5) } @p));
  }
 }
 return $im;
}

###############################################
#                 Skintones                   #
###############################################

# The G1 shows a stock photograph that cannot be shipped here. A photo
# supplied by the caller is used as is; otherwise a chart of skin tones
# (ColorChecker dark/light skin and a lightness series) stands in.
sub _skintones {
 my ($w,$h,$o)=@_;
 my $photo=$o->{photo};
 return $photo if(ref($photo) eq "HASH" && $photo->{w} == $w && $photo->{h} == $h);
 my $im=_img($w,$h,_lc($o,200,200,200));
 my @tones=(
  [115,82,68],[194,150,130],[141,93,72],[224,172,146],[90,60,46],[171,121,98],
  [233,194,166],[198,134,98],[160,105,80],[255,219,196],[121,77,58],[214,160,128],
 );
 my ($cols,$rows)=(4,3);
 my ($mx,$my)=(int($w*0.08),int($h*0.1));
 my $cw=($w-2*$mx)/$cols;
 my $ch=($h-2*$my)/$rows;
 my $gap=int($h/108+0.5);
 for my $i (0..$#tones) {
  my ($c,$r)=($i % $cols,int($i/$cols));
  _fill($im,int($mx+$c*$cw)+$gap,int($my+$r*$ch)+$gap,int($mx+($c+1)*$cw)-$gap,int($my+($r+1)*$ch)-$gap,_lc($o,@{$tones[$i]}));
 }
 return $im;
}

###############################################
#           Screensaver / Warm-Up             #
###############################################

sub _ss_logo {
 my ($w,$h,$o)=@_;
 my $logo=$o->{logo};
 return $logo if(ref($logo) eq "HASH" && $logo->{w} > 0 && $logo->{h} > 0);
 my $s=int($h/180+0.5); $s=1 if($s < 1);
 my $text="PGENERATOR+";
 my $im=_img(_text_width($text,$s)+4*$s,11*$s,_lc($o,94,94,94));
 _text($im,$text,2*$s,2*$s,$s,_lc($o,235,170,16));
 return $im;
}

# The renderer draws one frame per refresh and holds at most 2048 frames
# per pattern. It moves to the next frame on the first flip after the
# frame's time has passed, so a time just under k refreshes holds every
# frame for exactly k refreshes. Animations step every refresh, or every
# k-th one when a loop of $seconds would not fit into $max frames.
# Returns (frames, ms per frame).
use constant ANIM_MAX_FRAMES => 2000;
sub _anim_timing {
 my ($o,$seconds,$max)=@_;
 my $hz=($o->{hz} && $o->{hz} >= 10) ? $o->{hz} : 60;
 $max=ANIM_MAX_FRAMES if(!$max);
 my $k=1;
 $k++ while($seconds*$hz/$k > $max);
 my $n=int($seconds*$hz/$k+0.5);
 my $ms=($k == 1) ? 1 : int(($k-0.5)*1000/$hz);
 return ($n,$ms);
}

# A logo drifting over mid grey, bouncing off the edges. Per one-minute
# loop it crosses the screen four times horizontally and twice vertically,
# so the last frame runs straight into the first.
sub _screensaver {
 my ($w,$h,$o)=@_;
 my $logo=_ss_logo($w,$h,$o);
 my ($lw,$lh)=($logo->{w},$logo->{h});
 my ($mx,$my)=($w-$lw,$h-$lh);
 $mx=1 if($mx < 1); $my=1 if($my < 1);
 my @frames;
 my ($n,$ms)=_anim_timing($o,60);
 my ($vx,$vy)=(2*2*$mx/$n,2*$my/$n);
 for my $i (0..$n-1) {
  my $x=_bounce($w/2-$lw/2+$vx*$i,$mx);
  my $y=_bounce($h/2-$lh/2+$vy*$i,$my);
  push(@frames,{img => $logo, ms => $ms, x => int($x+0.5), y => int($y+0.5)});
 }
 return {frames => \@frames, bg => _lc($o,94,94,94)};
}

sub _bounce {
 my ($v,$max)=@_;
 my $p=$v-2*$max*floor($v/(2*$max));
 return $p <= $max ? $p : 2*$max-$p;
}

sub _ramp_row {
 my ($len,$from,$to)=@_;
 my $row="";
 for(my $i=0;$i<$len;$i++) {
  my $t=$len > 1 ? $i/($len-1) : 1;
  $row.=pack("C3",map { _clamp8($from->[$_]+($to->[$_]-$from->[$_])*$t+0.5) } 0..2);
 }
 return $row;
}

# Bands for the Warm-Up strip: grey, red, green and blue ramps from black
# and a light grey fade, as in the G1 capture.
sub _warmup_bands {
 my $o=shift;
 my $k=_lc($o,16,16,16);
 return (
  [_lc($o,235,235,235),_lc($o,200,200,200)],
  [$k,_lc($o,235,235,235)],
  [$k,_lc($o,235,16,16)],
  [$k,_lc($o,235,235,235)],
  [$k,_lc($o,16,235,16)],
  [$k,_lc($o,235,235,235)],
  [$k,_lc($o,16,16,235)],
  [$k,_lc($o,235,235,235)],
 );
}

sub _warmup_box {
 my ($w,$h,$o)=@_;
 my $s=int($h/216+0.5); $s=1 if($s < 1);
 my @lines=("PGENERATOR+","WARM-UP");
 push(@lines,"IP:".$o->{ip}) if(($o->{ip} // "") ne "");
 my $tw=0;
 for(@lines) { my $lw=_text_width($_,$s); $tw=$lw if($lw > $tw); }
 my $bw=$tw+8*$s;
 my $bh=(scalar(@lines)*10+4)*$s;
 my $box=_img($bw,$bh,[0,0,0]);
 my @colors=(_lc($o,235,170,16),_lc($o,200,200,200),_lc($o,200,200,200));
 for my $i (0..$#lines) {
  _text($box,$lines[$i],4*$s,(3+10*$i)*$s,$s,$colors[$i]);
 }
 return $box;
}

sub _paste {
 my ($dst,$src,$x,$y)=@_;
 my $sw=$src->{w}*3;
 for(my $r=0;$r<$src->{h};$r++) {
  my $dy=$y+$r;
  next if($dy < 0 || $dy >= $dst->{h});
  substr($dst->{buf},($dy*$dst->{w}+$x)*3,$sw,substr($src->{buf},$r*$sw,$sw));
 }
}

# Right-to-left scrolling ramps, then a top-to-bottom series. Each phase is
# one strip twice the screen size shown at moving offsets, so the renderer
# keeps one texture per phase.
sub _warmup {
 my ($w,$h,$o)=@_;
 my @bands=_warmup_bands($o);
 my $box=_warmup_box($w,$h,$o);
 my $bw=int(2*$w/scalar(@bands)+0.5);
 my $strip_w=$bw*scalar(@bands);
 my $hs=_img($strip_w,$h,[0,0,0]);
 my $row="";
 $row.=_ramp_row($bw,@$_) for(@bands);
 _row_copy($hs,0,0,$h,$row);
 my $bh=int(2*$h/scalar(@bands)+0.5);
 my $strip_h=$bh*scalar(@bands);
 my $vs=_img($w,$strip_h,[0,0,0]);
 for my $i (0..$#bands) {
  my ($from,$to)=@{$bands[$i]};
  for(my $y=0;$y<$bh;$y++) {
   my $t=$bh > 1 ? $y/($bh-1) : 1;
   my @c=map { _clamp8($from->[$_]+($to->[$_]-$from->[$_])*$t+0.5) } 0..2;
   _fill($vs,0,$i*$bh+$y,$w,$i*$bh+$y+1,\@c);
  }
 }
 # The box rides on the strips at a third of the way in.
 for my $k (0..1) {
  _paste($hs,$box,int($k*$strip_w/2+$w/10),int($h*0.35));
  _paste($vs,$box,int($w/10),int($k*$strip_h/2+$h*0.35));
 }
 my @frames;
 my ($n,$ms)=_anim_timing($o,6.4,ANIM_MAX_FRAMES/2);
 for my $i (0..$n-1) {
  push(@frames,{img => $hs, ms => $ms, x => -int(($strip_w-$w)*$i/$n+0.5), y => 0});
 }
 for my $i (0..$n-1) {
  push(@frames,{img => $vs, ms => $ms, x => 0, y => -int(($strip_h-$h)*($n-1-$i)/$n+0.5)});
 }
 return {frames => \@frames, bg => [0,0,0]};
}

1;
