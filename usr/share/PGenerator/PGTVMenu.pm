package PGTVMenu;
#
# On-screen pattern menu for the TV remote. The pure parts live here: the
# entries (test patterns and playlists), the grid layout on a 1920 px wide
# canvas, remote-key navigation and the scroll offset. webui.pm renders the
# menu images with ImageMagick and dispatches the keys
# (POST /api/remote/key from usr/bin/pgen_cec_remote.py).
#
use strict;
use warnings;
use PGPlaylists;

our $W        = 1920;   # canvas width; the image is scaled to the output
our $VIEW_H   = 1080;   # visible height of one menu image
our $MARGIN_X = 96;
our $TOP      = 128;    # below the title
our $FOOTER   = 84;     # hint line at the bottom of every view
our $COLS     = 8;
our $GAP_X    = 24;
our $THUMB_W  = int(($W - 2*$MARGIN_X - ($COLS-1)*$GAP_X) / $COLS);
our $THUMB_H  = int($THUMB_W * 9 / 16 + 0.5);
our $LABEL_H  = 40;
our $ROW_GAP  = 16;
our $ROW_H    = $THUMB_H + $LABEL_H + $ROW_GAP;
our $HEAD_H   = 50;     # section title above its first row

# Entries in menu order: the catalog patterns by group, then the playlists.
sub build_entries {
 my $playlists=shift || [];
 my @e;
 foreach my $c (@PGPlaylists::CATALOG) {
  push(@e,{ kind => "pattern", name => $c->{name}, label => $c->{label}, group => $c->{group}, sdr => ($c->{sdr} ? 1 : 0) });
 }
 foreach my $pl (@$playlists) {
  my $items=ref($pl->{items}) eq "ARRAY" ? $pl->{items} : [];
  next if(!@$items);
  push(@e,{ kind => "playlist", id => $pl->{id}, label => $pl->{name}, group => "Playlists",
            count => scalar(@$items), first => $items->[0] });
 }
 return \@e;
}

# Rows of the grid on the tall canvas. Each entry gets x/y/w/h for its
# thumbnail; each section a title position.
sub layout {
 my $entries=shift;
 my (@rows,@sections,%pos);
 my $y=$TOP;
 my $group="";
 my $row;
 for(my $i=0;$i<@$entries;$i++) {
  my $g=$entries->[$i]{group};
  if($g ne $group) {
   $y+=$ROW_H if($row);
   push(@sections,{ title => $g, y => $y });
   $y+=$HEAD_H;
   $row=undef;
   $group=$g;
  }
  if(!$row || @{$row->{items}} >= $COLS) {
   $y+=$ROW_H if($row);
   $row={ y => $y, items => [] };
   push(@rows,$row);
  }
  my $col=scalar(@{$row->{items}});
  push(@{$row->{items}},$i);
  $pos{$i}={ x => $MARGIN_X + $col*($THUMB_W+$GAP_X), y => $y, w => $THUMB_W, h => $THUMB_H,
             row => $#rows, col => $col };
 }
 my $height=($row ? $y+$ROW_H : $TOP)+$FOOTER;
 return { rows => \@rows, sections => \@sections, pos => \%pos, height => $height };
}

# New selection for a key: left/right walk the list, up/down keep the column.
sub navigate {
 my ($sel,$key,$lay,$count)=@_;
 return 0 if($count <= 0);
 $sel=0 if(!defined($sel) || $sel < 0);
 $sel=$count-1 if($sel >= $count);
 return $sel < $count-1 ? $sel+1 : $sel if($key eq "right");
 return $sel > 0 ? $sel-1 : 0 if($key eq "left");
 if($key eq "up" || $key eq "down") {
  my $p=$lay->{pos}{$sel} or return $sel;
  my $r=$p->{row}+($key eq "down" ? 1 : -1);
  return $sel if($r < 0 || $r > $#{$lay->{rows}});
  my $items=$lay->{rows}[$r]{items};
  my $c=$p->{col} < @$items ? $p->{col} : $#$items;
  return $items->[$c];
 }
 return $sel;
}

# Top of the visible window on the tall canvas: 0 while everything fits,
# else the selected row is kept in view (with its section title when it is
# the section's first row).
sub view_offset {
 my ($sel,$lay)=@_;
 my $avail=$VIEW_H-$FOOTER;
 my $content=$lay->{height}-$FOOTER;
 return 0 if($content <= $avail);
 my $p=$lay->{pos}{$sel} or return 0;
 my $top=$p->{y}-$HEAD_H-24;
 my $bottom=$p->{y}+$ROW_H;
 my $off=$bottom-$avail;
 $off=$top if($off > $top);
 $off=0 if($off < 0);
 my $max=$content-$avail;
 $off=$max if($off > $max);
 return $off;
}

# Next/previous pattern entry from $sel (playlists are skipped); stays put at
# the ends.
sub step_pattern {
 my ($sel,$dir,$entries)=@_;
 my $step=($dir eq "prev") ? -1 : 1;
 for(my $i=$sel+$step;$i >= 0 && $i < @$entries;$i+=$step) {
  return $i if($entries->[$i]{kind} eq "pattern");
 }
 return $sel;
}

# Remote key -> (action, argument) for the dispatcher.
#   menu view:      arrows move, OK opens the tile, Back/Exit/Menu close
#   item view:      left/right (and up/down) step the patterns, OK/Back/Menu
#                   return to the menu, Exit closes
#   playlist view:  a playlist opened from the menu; keys step it, Back/Menu
#                   stop it and return to the menu, Exit closes
#   no view:        a playlist started in the WebUI steps as before (Back or
#                   Exit end it, Menu ends it and opens the menu); otherwise
#                   OK or Menu open the menu
sub menu_action {
 my ($view,$key,$playlist_active)=@_;
 $view="" if(!defined($view));
 $key="" if(!defined($key));
 if($view eq "menu") {
  return ("move",$key) if($key=~/^(?:up|down|left|right)$/);
  return ("open","") if($key eq "ok");
  return ("close","") if($key=~/^(?:back|exit|menu)$/);
  return ("","");
 }
 if($view eq "item") {
  return ("step","prev") if($key=~/^(?:left|up|prev)$/);
  return ("step","next") if($key=~/^(?:right|down|next)$/);
  return ("menu","") if($key=~/^(?:ok|back|menu)$/);
  return ("close","") if($key eq "exit");
  return ("","");
 }
 if($view eq "playlist" || $playlist_active) {
  return ("playlist","next") if($key=~/^(?:right|down|next|ok)$/);
  return ("playlist","prev") if($key=~/^(?:left|up|prev)$/);
  return ("playlist",($key eq "0" ? "10" : $key)) if($key=~/^[0-9]$/);
  return ("playlist_menu","") if($key eq "menu" || ($key eq "back" && $view eq "playlist"));
  return ("playlist_close","") if($key eq "back" || $key eq "exit");
  return ("","");
 }
 return ("open_menu","") if($key eq "ok" || $key eq "menu");
 return ("","");
}

# The menu is an sRGB-style 8-bit picture. In HDR the same codes are read as
# PQ or HLG signal, so they are re-encoded first: SDR display light (gamma
# 2.4) with white at the BT.2408 graphics white of 203 cd/m2 (HLG: 75 %
# signal). A picture the renderer takes as Limited RGB wire codes (SOURCE_RANGE
# =LIMITED on an RGB Limited link) gets 16-235. Returns the 256 output codes
# for transfer "sdr", "pq" or "hlg".
our $GRAPHICS_WHITE = 203;

sub signal_fraction {
 my ($v,$transfer)=@_;
 my $e=$v / 255;
 return $e if($transfer eq "sdr");
 my $light=$e ** 2.4;
 if($transfer eq "hlg") {
  # Scene light that the HLG OETF puts at 75 %.
  my $s=$light * 0.264962;
  return sqrt(3 * $s) if($s <= 1/12);
  my ($a,$b,$c)=(0.17883277,0.28466892,0.55991073);
  return $a * log(12 * $s - $b) + $c;
 }
 my ($m1,$m2,$c1,$c2,$c3)=(2610/16384,2523/4096*128,3424/4096,2413/4096*32,2392/4096*32);
 my $y=($light * $GRAPHICS_WHITE / 10000) ** $m1;
 return (($c1 + $c2 * $y) / (1 + $c3 * $y)) ** $m2;
}

sub signal_lut {
 my ($transfer,$limited)=@_;
 return map {
  my $f=signal_fraction($_,$transfer);
  $limited ? 16 + int($f * 219 + 0.5) : int($f * 255 + 0.5);
 } 0..255;
}

1;
