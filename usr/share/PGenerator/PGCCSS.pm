package PGCCSS;
use strict;
use warnings;
use POSIX ();

# PGenerator resource policy, not CGATS reader limits. xspect.h:81 allows
# 601 spectral bands; reserve another 32 fields for IDs/auxiliary data.
use constant MAX_BYTES => 1024*1024;
use constant MAX_FIELDS => 601+32;

# File-only checks for the image's upstream ArgyllCMS 3.5.0 runtime.
# The vendor submodule adds ICC v4.4/profile and headless-build changes.
# Sources: https://www.argyllcms.com/Argyll_V3.5.0_src.zip
# cgats/cgats.c:377-785, xicc/ccss.c:258-406, spectro/i1d3.c:2536-2625.
# This cannot certify a particular meter's matrix: its sensor CMFs live in
# the instrument. Do not impose wavelength coverage or technology enums.
sub _brief {
 my ($s)=@_;
 $s='<missing>' if(!defined($s));
 return length($s)>80 ? substr($s,0,77).'...' : $s;
}
sub _bad {
 my ($field,$value,$reason)=@_;
 return (0,"Invalid CCSS file: "._brief($field)." '"._brief($value)."': $reason");
}

sub _unquote {
 my ($s)=@_;
 if($s=~s/\A"(.*)"\z/$1/s) { $s=~s/""/"/g; }
 return $s;
}

# cgats.c:1916-1974 guess_type is intentionally more permissive than a
# strict decimal grammar. Headers use C atoi/atof, including numeric prefixes.
sub _type {
 my ($s)=@_;
 return 's' if(substr($s,0,1) eq '"');
 my ($dot,$exp)=(0,0);
 for(my $i=0;$i<length($s);$i++) {
  my $c=substr($s,$i,1);
  next if($c=~/[0-9]/);
  next if($c=~/[+-]/ && ($i==0 || substr($s,$i-1,1)=~/[eE]/));
  if($c eq '.' && !$dot && !$exp) { $dot=1; next; }
  if($c=~/[eE]/ && !$exp) { $exp=1; next; }
  return 's';
 }
 return ($dot || $exp) ? 'r' : 'i';
}
sub _atof {
 my ($s)=@_;
 # ccss.c:355,360,365 uses libc atof, including hex, inf and nan.
 # Core POSIX strtod shares that conversion; finiteness is checked by caller.
 my ($value)=POSIX::strtod($s);
 return $value;
}
sub _atoi {
 my ($s)=@_;
 return $s=~/^\s*([+-]?[0-9]+)/ ? 0+$1 : 0;
}
sub _finite { return defined($_[0]) && "$_[0]"!~/(?:inf|nan)/i; }

# Header/grid checks need no retained data tokens (ccss.c:346-405).
sub _layout {
 my ($h,$f)=@_;
 my %header=%$h; my @fields=@$f;
 return _bad('DISPLAY/TECHNOLOGY',undef,'at least one keyword required') if(!exists($header{DISPLAY}) && !exists($header{TECHNOLOGY}));
 foreach my $field (qw(SPECTRAL_BANDS SPECTRAL_START_NM SPECTRAL_END_NM)) {
  return _bad($field,undef,'keyword required') if(!exists($header{$field}));
 }
 my $bands=_atoi($header{SPECTRAL_BANDS});
 # ccss.c:265,350,369-405; xspect.h:81-88; xspect.c:4178-4192.
 # Upper bound protects the fixed xspect array. The minimum of three is
 # deliberately stricter: Argyll can return a numerically worthless matrix
 # for two-band negative spectra after clamping.
 return _bad('SPECTRAL_BANDS',$header{SPECTRAL_BANDS},'exceeds XSPECT_MAX_BANDS (601)') if($bands>601);
 return _bad('SPECTRAL_BANDS',$header{SPECTRAL_BANDS},'PGenerator safety policy requires at least 3 spectral bands') if($bands<3);
 my $start=_atof($header{SPECTRAL_START_NM});
 my $end=_atof($header{SPECTRAL_END_NM});
 return _bad('SPECTRAL_START_NM',$header{SPECTRAL_START_NM},'non-finite wavelength') if(!_finite($start));
 return _bad('SPECTRAL_END_NM',$header{SPECTRAL_END_NM},'must exceed SPECTRAL_START_NM '._brief($header{SPECTRAL_START_NM})) if(!_finite($end) || $end<=$start);
 # ccss.c:362-366 defaults absent norm to 1; xspect.c:4380-4383 divides
 # by it; i1d3.c:2563-2587 clamps sensor integrals then inverts the matrix.
 my $norm=exists($header{SPECTRAL_NORM}) ? _atof($header{SPECTRAL_NORM}) : 1;
 return _bad('SPECTRAL_NORM',$header{SPECTRAL_NORM},'must be finite and greater than zero') if(!_finite($norm) || $norm<=0);
 my %index;
 for(my $i=0;$i<@fields;$i++) { $index{$fields[$i]}=$i if(!exists($index{$fields[$i]})); }
 my @spectral;
 for(my $j=0;$j<$bands;$j++) {
  # ccss.c:373-383: C int truncation after adding 0.5, minimum 3 digits.
  my $nm=$start+$j/($bands-1)*($end-$start)+0.5;
  return _bad('SPECTRAL_END_NM',$header{SPECTRAL_END_NM},'wavelength outside C int range') if($nm>2147483647 || $nm< -2147483648);
  my $field=sprintf('SPEC_%03d',int($nm));
  return _bad($field,'<missing>','field required by spectral grid') if(!exists($index{$field}));
  push @spectral,$index{$field};
 }
 my %used=map { $_=>1 } @spectral;
 my @standard=map { /^(?:CMYK_[CMYK].*|CMY_[CMY].*|D_(?:RED|GREEN|BLUE|VIS)|RGB_[RGB].*|SPECTRAL_(?:NM|PCT)|XYZ_[XYZ].*|XYY_(?:[XY].*|CAPY)|LAB_(?:[LABCH].*|DE)|STDEV_(?:[XYZLAB].*|DE))$/ ? 1 : 0 } @fields;
 return (1,'',{spectral=>\@spectral,used=>\%used,standard=>\@standard});
}

sub validate {
 my ($raw)=@_;
 return _bad('CCSS',undef,'file identifier required') if(!defined($raw));
 return _bad('FILE_SIZE',length($raw),'PGenerator resource limit is '.MAX_BYTES.' bytes (1 MiB)') if(length($raw)>MAX_BYTES);
 # pars.c:452-459,491: NUL in comment mode can replay the preceding line.
 # Reject internal NUL rather than emulate that unsafe reader side effect.
 my $nul=index($raw,"\0");
 if($nul>=0) {
  return _bad('NUL','0x00 at byte '.$nul,'PGenerator safety policy permits NUL only as trailing padding') if(substr($raw,$nul)=~/[^\0]/);
  $raw=substr($raw,0,$nul);
 }
 my (%header,@fields);
 my ($layout,$count)=(undef,0);
 my (@real,@bad_string,@bad_integer,@row,%spectra,%cache);
 my ($state,$key,$finished)=('ident','',0);
 my ($format_offset,$data_offset);
 # cgats.c:452,586-615: header keywords start a line; duplicate values replace
 # earlier ones; KEYWORD and NUMBER_OF_FIELDS declarations are ignored.
 # Stream logical tokens rather than allocating one scalar per input byte.
 # pars.c:425-493,539-594: comments/newlines outside quotes delimit logical
 # lines; quoted spans retain whitespace and doubled quotes verbatim.
 # Internal NUL was refused above; trailing zero padding is not tokenized.
 # A legal token has at most 1000 bytes/fragments (cgats.c:419-424).
 # Bound repetition before Perl can recurse through an oversized token.
 my $column=0;
 pos($raw)=0;
 while($raw=~/\G(?:[ \t]++|(\r\n|\r|\n|\0)|((?:[^ \t\r\n\0"#]++|"[^"\0]*+(?:"|(?=\0)|\z)){1,1001}+)|(\#[^\r\n]*+))/gc) {
   if(defined($1)) { $column=0; next; }
   if(defined($3)) {
    # pars.c:452-459,491: even EOF padding replays an unfinished comment.
    return _bad('NUL','0x00 at byte '.$nul,'padding after a comment requires a preceding newline') if($nul>=0 && pos($raw)==length($raw));
    next;
   }
   next if(!defined($2));
   my $t=$2;
   my $token_offset=pos($raw)-length($t);
   my $first=($column++==0);
   return _bad('CGATS token',$t,'symbol exceeds 1000 bytes') if(length($t)>1000);
   next if($finished && !$first); # Ignore non-leading tokens after END_DATA.
   return _bad('CCSS',$t,'expected exactly one table') if($finished);
   if($state eq 'ident') {
    return _bad('CCSS',$t,'file identifier required') if($t ne 'CCSS');
    $state='header'; next;
   }
   if($state eq 'value') {
    # cgats.c:593-608,968-971: only non-reserved keyword names go through
    # add_kword_at/cs_has_ws. Check names, not KEYWORD declaration values.
    if($key!~/^(?:NUMBER_OF_FIELDS|BEGIN_DATA_FORMAT|END_DATA_FORMAT|NUMBER_OF_SETS|BEGIN_DATA|END_DATA|KEYWORD)$/) {
     return _bad('CGATS keyword',$key,'illegal keyword name') if($key=~/[ \t\r\n"#]/);
    }
    $header{$key}=$key eq 'NUMBER_OF_SETS' ? $t : _unquote($t);
    $state='header'; next;
   }
   if($state eq 'header') {
    next if(!$first);
    next if($t eq 'CCSS' || $t=~/^(?:CGATS\.|IT8\.7\/[1-4]$)/);
    if($t eq 'BEGIN_DATA_FORMAT' || $t eq 'SAMPLE_ID') {
     $format_offset=$token_offset if(!defined($format_offset));
     @fields=(); $state='format';
     push @fields,$t if($t eq 'SAMPLE_ID');
    } elsif($t eq 'BEGIN_DATA') { $state='data'; $data_offset=$token_offset; }
    else { $key=$t; $state='value'; }
    next;
   }
   if($state eq 'format') {
    if($t eq 'END_DATA_FORMAT') { $state='header'; }
    elsif($t eq 'BEGIN_DATA') { $state='data'; $data_offset=$token_offset; }
    elsif($t eq 'DEVICE_NAME') { $key=$t; $state='value'; }
    else {
     return _bad('BEGIN_DATA_FORMAT',$t,'illegal field name') if($t=~/[ \t\r\n"#]/);
     return _bad('BEGIN_DATA_FORMAT',scalar(@fields)+1,'PGenerator resource limit is '.MAX_FIELDS.' fields (601 spectral + 32 auxiliary)') if(@fields>=MAX_FIELDS);
     push @fields,$t;
    }
    next;
   }
   if(!$layout) {
    return _bad('BEGIN_DATA_FORMAT',undef,'data without field definitions') if(!@fields);
    my ($ok,$error,$plan)=_layout(\%header,\@fields);
    return ($ok,$error) if(!$ok);
    $layout=$plan;
   }
   if($t eq 'END_DATA') { $finished=1; next; }
   my $col=$count++ % @fields;
   if($layout->{used}{$col} || $layout->{standard}[$col]) {
    # Retain column type summaries, not one scalar per data token. A bounded
    # cache avoids repeatedly converting common zero/one spectral values.
    my $parsed=$cache{$t};
    if(!$parsed) {
     my $type=_type($t);
     $parsed=[$type,$type eq 's' ? undef : _atof($t)];
     $cache{$t}=$parsed if(keys(%cache)<256);
    }
    my ($type,$value)=@$parsed;
    $real[$col]=1 if($type eq 'r');
    $bad_string[$col]=$t if($type eq 's' && !defined($bad_string[$col]));
    if($layout->{used}{$col}) {
     $bad_integer[$col]=$t if($type eq 'i' && _atoi($t)!=0 && !defined($bad_integer[$col]));
     return _bad($fields[$col],$t,'non-finite spectral value') if($type ne 's' && !_finite($value));
     $row[$col]=$value if(keys(%spectra)<3);
    }
   }
   if($col==$#fields && keys(%spectra)<3) {
    my @s=map { $row[$_] || 0 } @{$layout->{spectral}};
    $spectra{pack('d*',@s)}=1 if(grep { $_!=0 } @s);
   }
 }
 # Missing terminators leave unconverted/uninitialised CGATS data, not a safe
 # read_ccss double array. Reject rather than emulate that undefined C read.
 return _bad('END_DATA',undef,'data section not completed') if(!$finished);
 return _bad('BEGIN_DATA_FORMAT',undef,'spectral fields required') if(!@fields);
 return _bad('BEGIN_DATA',$count,'data count is not a multiple of '.scalar(@fields).' fields') if($count % @fields);
 my $sets=$count/@fields;
 my $expected=exists($header{NUMBER_OF_SETS}) ? _atoi($header{NUMBER_OF_SETS}) : 0;
 return _bad('NUMBER_OF_SETS',$header{NUMBER_OF_SETS},"read $sets samples") if($expected && $expected!=$sets);
 return _bad('NUMBER_OF_SETS',$sets,'at least three spectral samples required') if($sets<3);
 for(my $col=0;$col<@fields;$col++) {
  # cgats.c:700-719 standard numeric fields reject string types. SPEC_* is
  # nonstandard, but ccss.c:404 reads double*: allow real or all-zero int
  # columns (calloc at cgats.c:1658-1663), refuse nonzero integer storage.
  return _bad($fields[$col],$bad_string[$col],'expected numeric field') if(defined($bad_string[$col]));
  return _bad($fields[$col],$bad_integer[$col],'integer-only spectral column; use real values (e.g. 0.0)') if($layout->{used}{$col} && !$real[$col] && defined($bad_integer[$col]));
 }
 # Count distinct nonzero spectra only. This is not a rank/independence
 # test: r,g,r+g are distinct and remain accepted. Retain at most three.
 return _bad('BEGIN_DATA',scalar(keys %spectra).' distinct nonzero spectra','PGenerator safety policy requires at least 3 distinct nonzero spectra') if(keys(%spectra)<3);
 return (1,'',\%header,{format_offset=>$format_offset,data_offset=>$data_offset,fields=>[ @fields ],sets=>$sets});
}
1;
