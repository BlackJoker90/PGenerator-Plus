package PGTestEdid;

# Test EDID: the display's own EDID replaced by a file on the boot partition
# (PGenerator-test-EDID.bin), for trying settings a display does not declare
# without that display. usr/bin/pgen_test_edid applies it as root before the
# renderer starts; the daemon only reads whether it is active.
#
# Kernel side (drivers/gpu/drm/drm_debugfs.c and drm_edid.c, rpi-5.10.y,
# the Pi's 5.10.89): writing a whole EDID to the connector's debugfs
# edid_override in one write() replaces the EDID property at once, and
# drm_get_edid() returns it instead of reading DDC on every later probe, so
# the modes, display info, /sys/class/drm/.../edid and the CEC physical
# address all follow it. It is only used while a display answers on DDC (no
# "force"). Writing "reset" drops it; the next probe reads the display again.
# Reading edid_override returns the EDID only while an override is active.

use strict;
use warnings;
use Exporter qw(import);
use Fcntl qw(O_WRONLY);

our @EXPORT_OK=qw(test_edid_check test_edid_paths test_edid_read test_edid_write test_edid_active test_edid_status);

our $FILE_NAME="PGenerator-test-EDID.bin";
our $dri_debugfs="/sys/kernel/debug/dri";
# Last result of pgen_test_edid, one line per message.
our $status_file="/var/log/PGenerator/test-edid.txt";
# CTA-861 allows up to 255 extension blocks after the base block.
our $MAX_BYTES=128*256;

# "" when $raw is an EDID the kernel takes as a whole, else the reason. The
# kernel only checks that 128 * (1 + extension count) bytes are there and
# drops the rest. drm_edid_block_valid() rejects a base block with a wrong
# checksum or a version other than 1 (no modes); it lets a CTA extension
# with a wrong checksum through. All of these are refused here, the
# extension checksum too, so a hand-edited block gets a clear reason.
sub test_edid_check {
 my ($raw)=@_;
 return "the file is empty" if(!defined($raw) || length($raw) == 0);
 my $len=length($raw);
 return "more than $MAX_BYTES bytes, more than an EDID can have" if($len > $MAX_BYTES);
 return "$len bytes, an EDID is a multiple of 128 bytes" if($len % 128);
 return "no EDID header (00 FF FF FF FF FF FF 00) at the start" if(substr($raw,0,8) ne "\x00\xff\xff\xff\xff\xff\xff\x00");
 my $version=ord(substr($raw,18,1));
 return "EDID version $version, the kernel only takes version 1" if($version != 1);
 my $ext=ord(substr($raw,126,1));
 my $want=128*(1+$ext);
 return "the base block declares $ext extension block".($ext == 1 ? "" : "s")." ($want bytes), the file has $len bytes" if($want != $len);
 for my $i (0..$len/128-1) {
  my $sum=0;
  $sum+=$_ for(unpack("C*",substr($raw,$i*128,128)));
  return "block $i has a wrong checksum" if($sum % 256);
 }
 return "";
}

# Every HDMI connector's edid_override, sorted.
sub test_edid_paths {
 my @p=glob("$dri_debugfs/*/HDMI-A-*/edid_override");
 return sort @p;
}

# Contents of an edid_override ("" when no override is active), undef when
# it cannot be read.
sub test_edid_read {
 my ($path)=@_;
 open(my $fh,"<:raw",$path) or return undef;
 local $/;
 my $raw=<$fh>;
 close($fh);
 return defined($raw) ? $raw : "";
}

# One write() of the whole buffer: edid_write() takes one write as the
# whole EDID (or "reset"). "" on success, else the reason.
sub test_edid_write {
 my ($path,$data)=@_;
 sysopen(my $fh,$path,O_WRONLY) or return "open failed: $!";
 my $n=syswrite($fh,$data);
 my $err=$!;
 if(!defined($n)) {
  close($fh);
  return "write failed: $err";
 }
 close($fh) or return "close failed: $!";
 return "short write ($n of ".length($data)." bytes)" if($n != length($data));
 return "";
}

# The ports with an active override, e.g. ("HDMI-A-1").
sub test_edid_active {
 my @ports;
 for my $path (&test_edid_paths()) {
  my $raw=&test_edid_read($path);
  next if(!defined($raw) || $raw eq "");
  push(@ports,$1) if($path=~m{/(HDMI-A-\d+)/edid_override$});
 }
 return @ports;
}

# {active=>[ports], message=>last pgen_test_edid result} for the WebUI.
sub test_edid_status {
 my $msg="";
 if(open(my $fh,"<",$status_file)) {
  local $/;
  $msg=<$fh>;
  close($fh);
  $msg="" if(!defined($msg));
  $msg=~s/\s+$//;
 }
 return {active=>[&test_edid_active()],message=>$msg};
}

1;
