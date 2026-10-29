package PGEdidCaps;

# What a display declares it can take, read from its raw EDID (base block +
# CTA-861 extensions): colour formats, deep colour, the highest TMDS rate,
# SCDC, HDR transfer functions and Dolby Vision. Bit layout as in CTA-861-H
# and HDMI 1.4b / 2.1 (and edid-decode's parse-cta-block.cpp). Used by the
# signal check (PGSignalCheck.pm) and /api/capabilities, so the WebUI and the
# daemon decide from the same reading.

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK=qw(edid_caps_from_raw edid_caps_unknown);

# Caps for "no EDID read": every display-side check is skipped, the board
# limits still apply.
sub edid_caps_unknown {
 return {known=>0};
}

# Raw EDID bytes -> hashref. {known=>0} when there is no usable base block.
sub edid_caps_from_raw {
 my ($edid)=@_;
 return edid_caps_unknown() if(!defined $edid || length($edid) < 128);
 my @b=unpack("C*",$edid);
 # Base block header 00 FF FF FF FF FF FF 00
 return edid_caps_unknown() if(join(",",@b[0..7]) ne "0,255,255,255,255,255,255,0");
 my %c=(
  known=>1,
  digital=>($b[20] & 0x80) ? 1 : 0,
  hdmi=>0,                 # HDMI 1.4 VSDB present (else DVI: RGB 8-bit only)
  has_ycbcr444=>0, has_ycbcr422=>0,
  dc_30bit=>0, dc_36bit=>0, dc_48bit=>0, dc_y444=>0,
  dc_420_30bit=>0, dc_420_36bit=>0, dc_420_48bit=>0,
  max_tmds_mhz=>0,         # 0 = not declared
  hf_vsdb=>0, scdc=>0,
  has_hdr_sdr=>0, has_hdr_st2084=>0, has_hdr_hlg=>0,
  # HDR static metadata block, optional luminance bytes in cd/m2 (0 = not
  # declared): CV -> 50 * 2^(CV/32), min = max * (CV/255)^2 / 100, as
  # edid-decode (edid-decode.c, cta_hdr_static_metadata_block) decodes them.
  hdr_max_nits=>0, hdr_max_fall_nits=>0, hdr_min_nits=>0,
  has_dv=>0,
  bt2020_rgb=>0, bt2020_ycc=>0,
  quant_rgb_selectable=>0, quant_ycc_selectable=>0,
 );
 my $hdmi_tmds=0;
 my $hf_tmds=0;
 for(my $ext=128;$ext+128<=@b;$ext+=128) {
  next if($b[$ext] != 0x02);          # CTA-861 extension
  my $rev=$b[$ext+1];
  if($rev >= 2) {
   $c{has_ycbcr444}=1 if($b[$ext+3] & 0x20);
   $c{has_ycbcr422}=1 if($b[$ext+3] & 0x10);
  }
  my $dtd=$b[$ext+2];
  next if($dtd < 4 || $dtd > 127);
  my $i=$ext+4;
  while($i < $ext+$dtd) {
   my $tag=$b[$i] >> 5;
   my $len=$b[$i] & 0x1f;
   last if($i+$len >= $ext+$dtd);
   my @p=@b[$i+1 .. $i+$len];          # payload after the header byte
   if($tag == 3 && $len >= 3) {
    my $oui=sprintf("%02X%02X%02X",$p[2],$p[1],$p[0]);
    if($oui eq "000C03") {               # HDMI 1.4 VSDB
     $c{hdmi}=1;
     if($len >= 6) {
      $c{dc_48bit}=1 if($p[5] & 0x40);
      $c{dc_36bit}=1 if($p[5] & 0x20);
      $c{dc_30bit}=1 if($p[5] & 0x10);
      $c{dc_y444}=1  if($p[5] & 0x08);
     }
     $hdmi_tmds=$p[6]*5 if($len >= 7 && $p[6]);
    } elsif($oui eq "C45DD8" && $len >= 7) {   # HDMI Forum VSDB
     _hf_fields(\%c,\$hf_tmds,@p[3..$#p]);
    }
   } elsif($tag == 7 && $len >= 1) {
    my $ext_tag=$p[0];
    if($ext_tag == 0x79 && $len >= 7) {        # HF-SCDB (HDMI 2.1)
     _hf_fields(\%c,\$hf_tmds,@p[3..$#p]);
    } elsif($ext_tag == 0x06 && $len >= 2) {    # HDR static metadata
     $c{has_hdr_sdr}=1    if($p[1] & 0x01);
     $c{has_hdr_st2084}=1 if($p[1] & 0x04);
     $c{has_hdr_hlg}=1    if($p[1] & 0x08);
     $c{hdr_max_nits}=50*2**($p[3]/32) if($len >= 4 && $p[3]);
     $c{hdr_max_fall_nits}=50*2**($p[4]/32) if($len >= 5 && $p[4]);
     $c{hdr_min_nits}=$c{hdr_max_nits}*($p[5]/255)**2/100 if($len >= 6 && $c{hdr_max_nits});
    } elsif($ext_tag == 0x05 && $len >= 2) {    # Colorimetry
     $c{bt2020_rgb}=1 if($p[1] & 0x80);
     $c{bt2020_ycc}=1 if($p[1] & 0x40);
    } elsif($ext_tag == 0x00 && $len >= 2) {    # Video capability
     $c{quant_rgb_selectable}=1 if($p[1] & 0x40);
     $c{quant_ycc_selectable}=1 if($p[1] & 0x80);
    } elsif($ext_tag == 0x01 && $len >= 4 &&
            $p[1] == 0x46 && $p[2] == 0xd0 && $p[3] == 0x00) {   # Dolby VSVDB
     $c{has_dv}=1;
    }
   }
   $i+=$len+1;
  }
 }
 my $tmds=$hdmi_tmds;
 $tmds=$hf_tmds if($hf_tmds > $tmds);
 $c{max_tmds_mhz}=$tmds;
 return \%c;
}

# HF-VSDB / HF-SCDB fields from the version byte on.
sub _hf_fields {
 my ($c,$tmds,@q)=@_;
 $c->{hf_vsdb}=1;
 $$tmds=$q[1]*5 if(defined $q[1] && $q[1]);
 $c->{scdc}=1 if(defined $q[2] && ($q[2] & 0x80));
 if(defined $q[3]) {
  $c->{dc_420_48bit}=1 if($q[3] & 0x04);
  $c->{dc_420_36bit}=1 if($q[3] & 0x02);
  $c->{dc_420_30bit}=1 if($q[3] & 0x01);
 }
}

1;
