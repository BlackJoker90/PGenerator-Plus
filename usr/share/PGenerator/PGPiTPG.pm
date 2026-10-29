package PGPiTPG;

# PiTPG protocol 2: what ColourSpace's "PiTPG" hardware entry speaks on
# port 85. A client starts with the 4 bytes "PTG2"; then every message, both
# ways, is a 32-bit big-endian length (1 .. 0xFFFFF) and that many bytes of
# JSON, one reply per request. Classic PGenerator clients never start with
# "PTG2", so the daemon tells the two apart on the first bytes.
#
# The server side is taken from Light Illusion's pitpgd 2.0.0 (static
# analysis, docs/research/pitpg-2.0.0/protocol2-spec.md, v1-layer.md):
# request fields, their types and ranges, the order settings are applied
# in, rollback, error codes. Message texts are our own. What ColourSpace
# sends and reads is not known beyond what pitpgd accepts.
#
# This module is the protocol only: framing, a JSON parser that keeps the
# order of object members (settings are applied in the order sent), the
# checks of every request, and the replies. What a request does to the
# output is up to the backend the daemon passes in (a hash of callbacks,
# see handle()).

use strict;
use Time::HiRes qw(CLOCK_MONOTONIC);
use warnings;

our $MAGIC="PTG2";
our $MAX_MESSAGE=0xFFFFF;
our $PROTOCOL=2;
# pitpgd's version and edition: the protocol behaviour implemented here.
our $COMPAT_VERSION="2.0.0";
our $EDITION="basic";

# Settings a client may send, in pitpgd's order, and those that apply
# without restarting the output.
our @SETTING_KEYS=qw(mode color_format rgb_quant_range max_bpc is_sdr is_hdr eotf colorimetry
                     primaries max_luma min_luma max_cll max_fall is_ll_dovi is_std_dovi dv_status
                     dv_interface dv_metadata dv_color_space dv_map_mode dv_profile dv_minpq dv_maxpq
                     dv_diagonal);
our %SETTING_KEY=map { $_=>1 } @SETTING_KEYS;
our %LIVE_KEY=map { $_=>1 } qw(max_luma min_luma max_cll max_fall primaries);
our %RANGE_CODE=(full=>0,legal=>1,extended=>2,user=>3);
our @RANGE_NAME=qw(full legal extended user);

###############################################
#                 Framing                     #
###############################################

# 1 when $buf starts with the magic, 0 when it cannot, undef while it is
# shorter than the magic and could still become it.
sub detect {
 my ($buf)=@_;
 $buf="" if(!defined($buf));
 my $n=length($buf) < length($MAGIC) ? length($buf) : length($MAGIC);
 return 0 if(substr($buf,0,$n) ne substr($MAGIC,0,$n));
 return length($buf) >= length($MAGIC) ? 1 : undef;
}

# Cuts the whole messages off the front of $$buf (the magic already
# removed). Returns (\@payloads,$error): $error is set when the stream is
# broken (a length of 0 or above $MAX_MESSAGE) and the connection has to
# close; the payloads before it are still valid.
sub take_messages {
 my ($buf)=@_;
 my @out;
 while(length($$buf) >= 4) {
  my $len=unpack("N",substr($$buf,0,4));
  return (\@out,"message length $len is outside 1..$MAX_MESSAGE") if($len < 1 || $len > $MAX_MESSAGE);
  last if(length($$buf) < 4+$len);
  push(@out,substr($$buf,4,$len));
  substr($$buf,0,4+$len)="";
 }
 return (\@out,"");
}

sub frame {
 my ($payload)=@_;
 return pack("N",length($payload)).$payload;
}

###############################################
#                  JSON                       #
###############################################
# Parsed values are typed nodes, so a number is never taken for a string:
#  {t=>"obj",pairs=>[[key,node],...]}  {t=>"arr",items=>[node,...]}
#  {t=>"str",v=>bytes}  {t=>"num",v=>number}  {t=>"bool",v=>0|1}  {t=>"null"}
# Strings stay UTF-8 bytes.

sub json_parse {
 my ($text)=@_;
 return undef if(!defined($text));
 my $pos=0;
 my $node=eval { _value(\$text,\$pos,0) };
 return undef if(!$node);
 pos($text)=$pos;
 $text=~/\G[ \t\r\n]*/gc;
 return undef if(pos($text) != length($text));
 return $node;
}

sub _ws { my ($t,$p)=@_; pos($$t)=$$p; $$t=~/\G[ \t\r\n]*/gc; $$p=pos($$t); }

sub _value {
 my ($t,$p,$depth)=@_;
 die "too deep\n" if($depth > 64);
 _ws($t,$p);
 pos($$t)=$$p;
 if($$t=~/\G\{/gc) {
  $$p=pos($$t);
  my @pairs;
  _ws($t,$p); pos($$t)=$$p;
  if($$t=~/\G\}/gc) { $$p=pos($$t); return {t=>"obj",pairs=>\@pairs}; }
  while(1) {
   _ws($t,$p);
   my $k=_value($t,$p,$depth+1);
   die "key\n" if($k->{t} ne "str");
   _ws($t,$p); pos($$t)=$$p;
   die "colon\n" if($$t!~/\G:/gc);
   $$p=pos($$t);
   push(@pairs,[$k->{v},_value($t,$p,$depth+1)]);
   _ws($t,$p); pos($$t)=$$p;
   if($$t=~/\G,/gc) { $$p=pos($$t); next; }
   die "object\n" if($$t!~/\G\}/gc);
   $$p=pos($$t);
   return {t=>"obj",pairs=>\@pairs};
  }
 }
 if($$t=~/\G\[/gc) {
  $$p=pos($$t);
  my @items;
  _ws($t,$p); pos($$t)=$$p;
  if($$t=~/\G\]/gc) { $$p=pos($$t); return {t=>"arr",items=>\@items}; }
  while(1) {
   push(@items,_value($t,$p,$depth+1));
   _ws($t,$p); pos($$t)=$$p;
   if($$t=~/\G,/gc) { $$p=pos($$t); next; }
   die "array\n" if($$t!~/\G\]/gc);
   $$p=pos($$t);
   return {t=>"arr",items=>\@items};
  }
 }
 if($$t=~/\G"((?:[^"\\\x00-\x1f]++|\\(?:["\\\/bfnrt]|u[0-9a-fA-F]{4}))*+)"/gc) {
  $$p=pos($$t);
  return {t=>"str",v=>_unescape($1)};
 }
 if($$t=~/\G(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/gc) {
  $$p=pos($$t);
  return {t=>"num",v=>0+$1};
 }
 if($$t=~/\Gtrue/gc)  { $$p=pos($$t); return {t=>"bool",v=>1}; }
 if($$t=~/\Gfalse/gc) { $$p=pos($$t); return {t=>"bool",v=>0}; }
 if($$t=~/\Gnull/gc)  { $$p=pos($$t); return {t=>"null"}; }
 die "value\n";
}

sub _utf8 {
 my ($c)=@_;
 return chr($c) if($c < 0x80);
 return chr(0xc0|($c>>6)).chr(0x80|($c&0x3f)) if($c < 0x800);
 return chr(0xe0|($c>>12)).chr(0x80|(($c>>6)&0x3f)).chr(0x80|($c&0x3f)) if($c < 0x10000);
 return chr(0xf0|($c>>18)).chr(0x80|(($c>>12)&0x3f)).chr(0x80|(($c>>6)&0x3f)).chr(0x80|($c&0x3f));
}

sub _unescape {
 my ($s)=@_;
 my %simple=('"'=>'"','\\'=>'\\','/'=>'/',b=>"\b",f=>"\f",n=>"\n",r=>"\r",t=>"\t");
 $s=~s{\\(?:u([dD][89abAB][0-9a-fA-F]{2})\\u([dD][c-fC-F][0-9a-fA-F]{2})|u([0-9a-fA-F]{4})|(.))}{
  defined($1) ? _utf8(0x10000+((hex($1)-0xd800)<<10)+(hex($2)-0xdc00))
  : defined($3) ? _utf8(hex($3))
  : $simple{$4}
 }ge;
 return $s;
}

# First member named $key of an object node, undef when absent.
sub get {
 my ($node,$key)=@_;
 return undef if(!$node || $node->{t} ne "obj");
 for my $pr (@{$node->{pairs}}) { return $pr->[1] if($pr->[0] eq $key); }
 return undef;
}

sub str_of { my ($n)=@_; return ($n && $n->{t} eq "str") ? $n->{v} : undef; }

# The integer in a number node within [$min,$max], undef otherwise (a
# number with a fraction is not an integer).
sub int_of {
 my ($n,$min,$max)=@_;
 return undef if(!$n || $n->{t} ne "num");
 my $v=$n->{v};
 return undef if($v < $min || $v > $max || $v != int($v));
 return int($v);
}

# [r,g,b] within 0..$max, undef otherwise.
sub triplet_of {
 my ($n,$max)=@_;
 return undef if(!$n || $n->{t} ne "arr" || @{$n->{items}} != 3);
 my @v=map { int_of($_,0,$max) } @{$n->{items}};
 return undef if(grep { !defined($_) } @v);
 return \@v;
}

# Encoding. Replies are built from plain Perl data: a hash is an object
# (keys sorted, except those listed in $order first), an array an array,
# \1 / \0 true / false, undef null, PGPiTPG::raw("...") a number or other
# literal as given, anything else a string (bytes; invalid UTF-8 becomes
# "?").
sub raw { my ($s)=@_; return bless(\$s,"PGPiTPG::Raw"); }
sub num { my ($v)=@_; return raw(defined($v) && $v=~/^-?\d+$/ ? $v : (defined($v) && $v=~/^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/ ? $v : "null")); }

sub _quote {
 my ($s)=@_;
 # Keep valid UTF-8 sequences, replace any other byte >= 0x80.
 $s=~s/((?:[\xc2-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee\xef][\x80-\xbf]{2}|\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf]{2}|[\xf1-\xf3][\x80-\xbf]{3}|\xf4[\x80-\x8f][\x80-\xbf]{2}))|[\x80-\xff]/defined($1) ? $1 : "?"/ge;
 $s=~s/(["\\])/\\$1/g;
 $s=~s/\n/\\n/g; $s=~s/\r/\\r/g; $s=~s/\t/\\t/g;
 $s=~s/([\x00-\x1f\x7f])/sprintf("\\u%04x",ord($1))/ge;
 return "\"$s\"";
}

sub encode {
 my ($v,@order)=@_;
 return "null" if(!defined($v));
 my $r=ref($v);
 return $$v if($r eq "PGPiTPG::Raw");
 if($r eq "SCALAR") { return $$v ? "true" : "false"; }
 if($r eq "ARRAY") { return "[".join(",",map { encode($_) } @$v)."]"; }
 if($r eq "HASH") {
  my %first; my $i=0; $first{$_}=$i++ for(@order);
  my @keys=sort { (exists $first{$a} ? $first{$a} : 1e9) <=> (exists $first{$b} ? $first{$b} : 1e9) || $a cmp $b } keys(%$v);
  return "{".join(",",map { _quote($_).":".encode($v->{$_}) } @keys)."}";
 }
 return _quote("$v");
}

###############################################
#                 Requests                    #
###############################################

sub _ok {
 my ($id,@kv)=@_;
 my $s="{\"id\":$id,\"ok\":true";
 while(@kv) {
  my $k=shift(@kv);
  my $v=shift(@kv);
  $s.=",".&_quote($k).":".&encode($v);
 }
 return $s."}";
}

# CLOCK_MONOTONIC in microseconds: the clock of DRM's page flip events.
sub monotonic_us {
 return int(Time::HiRes::clock_gettime(CLOCK_MONOTONIC)*1000000);
}

sub _err {
 my ($id,$code,$message)=@_;
 return "{\"id\":$id,\"ok\":false,\"error\":{\"code\":"._quote($code).",\"message\":"._quote($message)."}}";
}

# One request. $b is the backend:
#  hello()                -> {model=>..., hostname=>..., server=>...}
#  log($text)
#  state()                -> hash for "state" (encode() data)
#  snapshot() / restore($snap)
#  set_setting($key,$value) -> "" or why it was refused (bad_request)
#  set_setting_direct($key,$value)   (no checks, as pitpgd's config_set)
#  apply()                -> "" or why the output could not be applied (refused;
#                            the protocol then restores the snapshot)
#  apply_live(\@keys)     (optional) only live keys were set
#  refusal()              -> ("" ) or ($code,$message) when nothing can be shown
#  patch(\%p)             -> ("",\%frame,$peak_note) or ($code,$message);
#                            %p: rgb bg bits range(-1|0..3) rect([x,y,w,h]|undef)
#  test_pattern(\%p)      -> ("",\%frame) or ($code,$message); %p: name min max bits off
#  text($op)              -> ("",$text) or ($code,$message)
# Returns ($reply,$close): $close when the connection ends after the reply.
sub handle {
 my ($b,$payload)=@_;
 my $req=json_parse($payload);
 return (_err(0,"bad_request","The message is not a JSON object."),0) if(!$req || $req->{t} ne "obj");
 my $id=int_of(get($req,"id"),-2147483648,2147483647);
 $id=0 if(!defined($id));
 my $op=str_of(get($req,"op"));
 return (_err($id,"bad_request","The request has no \"op\"."),0) if(!defined($op));

 if($op eq "hello") {
  my $p=int_of(get($req,"protocol"),0,1000);
  return (_err($id,"bad_request","This server speaks PiTPG protocol $PROTOCOL."),0) if(!defined($p) || $p != $PROTOCOL);
  my $client=str_of(get($req,"client"));
  $b->{log}->("PiTPG protocol 2 client: ".(defined($client) ? $client : "(unnamed)"));
  my $h=$b->{hello}->();
  return (_ok($id,protocol=>raw($PROTOCOL),version=>$COMPAT_VERSION,edition=>$EDITION,
              model=>$h->{model},hostname=>$h->{hostname},features=>[],
              (defined($h->{server}) ? (server=>$h->{server}) : ())),0);
 }
 if($op eq "get_state") {
  return (_ok($id,state=>$b->{state}->()),0);
 }
 if($op eq "set_settings") {
  my $s=get($req,"settings");
  return (_err($id,"bad_request","set_settings needs a \"settings\" object."),0) if(!$s || $s->{t} ne "obj");
  if(@{$s->{pairs}}) {
   my $snap=$b->{snapshot}->();
   my $all_live=1;
   for my $pr (@{$s->{pairs}}) {
    my ($k,$n)=@$pr;
    my $why="";
    my $value;
    if(!$SETTING_KEY{$k}) {
     $why="Unknown setting \"".substr($k,0,40)."\".";
    } elsif($k eq "mode" && $n->{t} eq "str") {
     $value=$n->{v};
    } elsif(defined(my $i=int_of($n,-2147483647,2147483647))) {
     $value="$i";
    } elsif($n->{t} eq "null") {
     $value="";
    } else {
     $why="Setting \"$k\" has a value of the wrong kind.";
    }
    $why=$b->{set_setting}->($k,$value) if($why eq "");
    if($why ne "") {
     $b->{restore}->($snap);
     return (_err($id,"bad_request",$why),0);
    }
    $all_live=0 if(!$LIVE_KEY{$k});
   }
   # A colour format without a range: RGB full, YCbCr limited.
   my $cf=int_of(get($s,"color_format"),0,3);
   if(defined($cf) && !get($s,"rgb_quant_range")) {
    $b->{set_setting_direct}->("rgb_quant_range",$cf == 0 ? "2" : "1");
   }
   if(!$all_live) {
    my $why=$b->{apply}->();
    if($why ne "") {
     # The output stays as it was; so do the settings (pitpgd keeps the
     # refused ones in its config, PGenerator+ puts them back).
     $b->{restore}->($snap);
     return (_err($id,"refused",$why),0);
    }
   } elsif($b->{apply_live}) {
    # HDR metadata only: applied now when HDR is on (pitpgd: no error path).
    $b->{apply_live}->([map { $_->[0] } @{$s->{pairs}}]);
   }
  }
  return (_ok($id,state=>$b->{state}->()),0);
 }
 if($op eq "patch") {
  my $bits=8;
  if(get($req,"bits")) {
   $bits=int_of(get($req,"bits"),8,10);
   return (_err($id,"bad_request","\"bits\" must be 8 or 10."),0) if(!defined($bits) || ($bits != 8 && $bits != 10));
  }
  my $max=$bits == 10 ? 1023 : 255;
  my $rgb=triplet_of(get($req,"rgb"),$max);
  my $bg=[0,0,0];
  $bg=triplet_of(get($req,"background"),$max) if($rgb && get($req,"background"));
  return (_err($id,"bad_request","\"rgb\" and \"background\" must be three code values within the bit depth."),0) if(!$rgb || !$bg);
  my $range=-1;
  if(get($req,"range")) {
   my $r=str_of(get($req,"range"));
   return (_err($id,"bad_request","\"range\" must be full, legal, extended or user."),0) if(!defined($r) || !exists($RANGE_CODE{$r}));
   $range=$RANGE_CODE{$r};
  }
  my $rect;
  if(my $rn=get($req,"rect")) {
   my @v;
   if($rn->{t} eq "arr" && @{$rn->{items}} == 4) {
    @v=(int_of($rn->{items}[0],-16384,16384),int_of($rn->{items}[1],-16384,16384),
        int_of($rn->{items}[2],0,16384),int_of($rn->{items}[3],0,16384));
   }
   return (_err($id,"bad_request","\"rect\" must be [x, y, width, height] in pixels."),0) if(@v != 4 || grep { !defined($_) } @v);
   $rect=\@v;
  }
  my @r=$b->{refusal}->();
  return (_err($id,$r[0],$r[1]),0) if(@r && $r[0] ne "");
  my ($code,$x,$peak)=$b->{patch}->({rgb=>$rgb,bg=>$bg,bits=>$bits,range=>$range,rect=>$rect});
  return (_err($id,$code,$x),0) if($code ne "");
  return (_ok($id,frame=>_frame($x),(defined($peak) && $peak ne "" ? (peak_note=>$peak) : ())),0);
 }
 if($op eq "test_pattern") {
  my $name=str_of(get($req,"name"));
  return (_err($id,"bad_request","test_pattern needs a \"name\"."),0) if(!defined($name) || length($name) > 40);
  # As pitpgd: a min, max or bits out of range keeps its default.
  my %p=(name=>$name,min=>undef,max=>undef,bits=>undef);
  for my $k (qw(min max)) { my $v=int_of(get($req,$k),0,1023); $p{$k}=$v if(defined($v)); }
  { my $v=int_of(get($req,"bits"),8,10); $p{bits}=$v if(defined($v) && ($v == 8 || $v == 10)); }
  $p{off}=(lc($name) eq "off") ? 1 : 0;
  if(!$p{off}) {
   my @r=$b->{refusal}->();
   return (_err($id,$r[0],$r[1]),0) if(@r && $r[0] ne "");
  }
  my ($code,$x)=$b->{test_pattern}->(\%p);
  return (_err($id,$code,$x),0) if($code ne "");
  return (_ok($id,frame=>_frame($x)),0);
 }
 if($op=~/^(?:hdmi_info|edid_info|log|kernel_log|infoframes)$/) {
  my ($code,$x)=$b->{text}->($op);
  return (_err($id,$code,$x),0) if($code ne "");
  return (_ok($id,text=>$x),0);
 }
 if($op eq "bye") {
  return (_ok($id),1);
 }
 return (_err($id,"unsupported","This server does not support the operation \"".substr($op,0,40)."\"."),0);
}

sub _frame {
 my ($f)=@_;
 $f={} if(ref($f) ne "HASH");
 return raw("{\"seq\":".${num($f->{seq} // 0)}.",\"time_us\":".${num($f->{time_us} // 0)}.",\"period_us\":".${num($f->{period_us} // 0)}."}");
}

1;
