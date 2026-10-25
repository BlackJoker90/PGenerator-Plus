package PGPlaylists;
#
# Pattern playlists: ordered setup patterns the operator steps through with
# the TV remote (HDMI-CEC, pgen_cec_remote.py) or the WebUI. This module holds
# the pure parts -- the pattern catalog, the built-in playlists, validation of
# user playlists, window code levels and stepping -- so they can be tested
# without the daemon. webui.pm does the file IO and draws the patterns.
#
use strict;
use warnings;

our $MAX_PLAYLISTS = 24;
our $MAX_ITEMS     = 40;

# Patterns a playlist can show. "sdr" marks the Calman G1 plates, which the
# renderer only draws in SDR.
our @CATALOG = (
 { name => "g1_basic_alignment", label => "Basic Alignment",            group => "G1 plates", sdr => 1 },
 { name => "g1_alignment",       label => "Alignment",                  group => "G1 plates", sdr => 1 },
 { name => "g1_brightness",      label => "Brightness",                 group => "G1 plates", sdr => 1 },
 { name => "g1_contrast",        label => "Contrast",                   group => "G1 plates", sdr => 1 },
 { name => "g1_color_bars",      label => "Color Bars",                 group => "G1 plates", sdr => 1 },
 { name => "g1_smpte",           label => "SMPTE Bars",                 group => "G1 plates", sdr => 1 },
 { name => "g1_tint",            label => "Tint",                       group => "G1 plates", sdr => 1 },
 { name => "g1_sharpness",       label => "Sharpness",                  group => "G1 plates", sdr => 1 },
 { name => "g1_stair21",         label => "Grayscale Steps 21",         group => "G1 plates", sdr => 1 },
 { name => "g1_stair51",         label => "Grayscale Steps 51",         group => "G1 plates", sdr => 1 },
 { name => "g1_ramp",            label => "Horizontal Ramp",            group => "G1 plates", sdr => 1 },
 { name => "g1_checker_4n",      label => "ANSI Checkerboard 4x4",      group => "G1 plates", sdr => 1 },
 { name => "g1_checker_5n",      label => "ANSI Checkerboard 5x5",      group => "G1 plates", sdr => 1 },
 { name => "g1_skintones",       label => "Skin Tones",                 group => "G1 plates", sdr => 1 },
 { name => "g1_granger",         label => "Granger Rainbow",            group => "G1 plates", sdr => 1 },
 { name => "g1_warmup",          label => "Warm-Up",                    group => "G1 plates", sdr => 1 },
 { name => "range_check",        label => "Range Check",                group => "Test images", sdr => 1 },
 { name => "black_clipping",     label => "Black Clipping",             group => "Test images" },
 { name => "white_clipping",     label => "White Clipping",             group => "Test images" },
 { name => "overscan",           label => "Overscan",                   group => "Test images" },
);
our %CATALOG_BY_NAME = map { $_->{name} => $_ } @CATALOG;

sub window_item {
 my ($level,$size)=@_;
 $size=10 if(!defined($size));
 return { type => "window", level => $level, size => $size, label => "$level % window" . ($size == 10 ? "" : " ($size %)") };
}

sub pattern_item {
 my $name=shift;
 my $c=$CATALOG_BY_NAME{$name} or return undef;
 return { type => "pattern", name => $name, label => $c->{label} };
}

# Built-in playlists are read-only; the WebUI offers "Duplicate" to edit one.
sub builtin_playlists {
 return (
  { id => "builtin-picture", builtin => 1, name => "Picture setup",
    description => "Range, black level, white level, colour and geometry, in the order a manual setup goes.",
    items => [ map { pattern_item($_) } qw(range_check black_clipping g1_brightness white_clipping g1_contrast g1_color_bars g1_tint g1_sharpness overscan) ] },
  { id => "builtin-greyscale", builtin => 1, name => "Greyscale windows",
    description => "10 % windows from 20 % to 100 %, for a quick look at greyscale tracking.",
    items => [ map { window_item($_) } (20,30,40,50,60,70,80,90,100) ] },
  { id => "builtin-panel", builtin => 1, name => "Panel check",
    description => "Uniformity, banding and gradation plates for a new or serviced panel.",
    items => [ map { pattern_item($_) } qw(g1_warmup g1_stair21 g1_ramp g1_granger g1_checker_5n g1_skintones) ] },
 );
}

sub _clean_text {
 my ($s,$max)=@_;
 $s="" if(!defined($s));
 $s=~s/[\x00-\x1f\x7f]+/ /g;
 $s=~s/^\s+|\s+$//g;
 $s=~s/\s{2,}/ /g;
 $s=substr($s,0,$max) if(length($s) > $max);
 return $s;
}

# Validate one user item; returns a clean copy or undef.
sub normalize_item {
 my $item=shift;
 return undef if(ref($item) ne "HASH");
 my $type=$item->{type} || "";
 if($type eq "pattern") {
  my $name=$item->{name} || "";
  return undef if(!$CATALOG_BY_NAME{$name});
  return pattern_item($name);
 }
 if($type eq "window") {
  my $level=$item->{level};
  my $size=defined($item->{size}) ? $item->{size} : 10;
  return undef if(!defined($level) || "$level" !~ /^\d{1,3}$/ || $level > 100);
  return undef if("$size" !~ /^\d{1,3}$/ || $size < 1 || $size > 100);
  return window_item(int($level),int($size));
 }
 if($type eq "image") {
  my $file=$item->{filename} || "";
  return undef if($file eq "" || $file=~m{[/\\]} || $file=~/^\./ || length($file) > 120 || $file!~/^[\w .()+-]+$/);
  my $label=_clean_text($item->{label} || $file,60);
  return { type => "image", filename => $file, label => $label };
 }
 return undef;
}

# Validate a user playlist. Returns (clean_playlist, "") or (undef, error).
sub normalize_playlist {
 my $pl=shift;
 return (undef,"The playlist is not readable.") if(ref($pl) ne "HASH");
 my $name=_clean_text($pl->{name},48);
 return (undef,"Give the playlist a name.") if($name eq "");
 my @items;
 foreach my $raw (@{ ref($pl->{items}) eq "ARRAY" ? $pl->{items} : [] }) {
  my $item=normalize_item($raw);
  return (undef,"One of the patterns is not available on this device.") if(!$item);
  push(@items,$item);
 }
 return (undef,"Add at least one pattern.") if(!@items);
 return (undef,"A playlist holds up to $MAX_ITEMS patterns.") if(@items > $MAX_ITEMS);
 my $id=defined($pl->{id}) ? "$pl->{id}" : "";
 $id="" if($id!~/^user-[a-z0-9]{6,24}$/);
 return ({ id => $id, name => $name, items => \@items },"");
}

sub new_id {
 my @c=("a".."z",0..9);
 return "user-".join("",map { $c[int(rand(@c))] } 1..10);
}

# Code for a window at $level % of the signal range. Limited range spans
# 64..940 (10 bit) or 16..235 (8 bit); full range 0..1023 / 0..255.
sub window_code {
 my ($level,$bits,$limited)=@_;
 $level=0 if($level < 0);
 $level=100 if($level > 100);
 my ($black,$white)=$bits >= 10 ? ($limited ? (64,940) : (0,1023)) : ($limited ? (16,235) : (0,255));
 return int($black + ($white-$black)*$level/100 + 0.5);
}

# Next index for a step. "next"/"prev" stop at the ends (a remote press past
# the last plate keeps it on screen); "first"/"last" jump; a number (1-based)
# selects that item.
sub step_index {
 my ($index,$count,$dir)=@_;
 return 0 if($count <= 0);
 $index=0 if(!defined($index) || $index < 0);
 $index=$count-1 if($index >= $count);
 $dir="" if(!defined($dir));
 return $index+1 < $count ? $index+1 : $index if($dir eq "next");
 return $index > 0 ? $index-1 : 0 if($dir eq "prev");
 return 0 if($dir eq "first");
 return $count-1 if($dir eq "last");
 if($dir=~/^\d+$/) {
  my $n=int($dir);
  return $n-1 if($n >= 1 && $n <= $count);
 }
 return $index;
}

1;
