#!/usr/bin/perl
#
# Copyright (c) 2017-2018 Biasiotto Riccardo
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
# 
# See the File README and COPYING for more detail about License
#
# Program: PGenerator_cmd.pl            
# Version: 1.0                         
#########################################
#                Modules                #
#########################################
use Cwd;
use Config;
use Time::HiRes qw(usleep);
use IO::Socket::INET;
use IO::Select;
use Getopt::Long;
use File::Copy;
use File::Basename;
use threads;
use threads::shared;
use MIME::Base64;
use IPC::Open2;
use File::Path;
use Digest::MD5;
use List::Util qw(sum);
use POSIX qw(setsid WNOHANG);
use Fcntl qw(:flock);

#########################################
#              Shared Dir               #
#########################################
BEGIN { use lib $shared_dir="/usr/share/PGenerator"; }
chdir($shared_dir);

#########################################
#                 My pm                 #
#########################################
do "version.pm"       || die "Error";
do "command.pm"       || die "Error";
do "variables.pm"     || die "Error";
do "conf.pm"          || die "Error";
do "info.pm"          || die "Error";
do "file.pm"          || die "Error";
do "log.pm"           || die "Error";
do "pattern.pm"       || die "Error";
do "daemon.pm"        || die "Error";
do "client.pm"        || die "Error";
do "discovery.pm"     || die "Error";

#########################################
#               Variables               #
#########################################
$i=0;
for(split(" ",$ENV{$pg_cmd_env})) { $ARGV[$i++]=decode_base64($_); }
$action=$ARGV[0];
$0=basename($0)." $action";

#
# main
#
&reboot()                 if($action eq "REBOOT");
&halt()                   if($action eq "HALT");
&set_gpu_memory()         if($action eq "SET_GPU_MEMORY");
&set_cma_memory()         if($action eq "SET_CMA_MEMORY");
&set_boot_memory()        if($action eq "SET_BOOT_MEMORY");
&set_dtoverlay()          if($action eq "SET_DTOVERLAY");
&set_boot_config()        if($action eq "SET_BOOT_CONFIG");
&set_refresh()            if($action eq "SET_REFRESH");
&set_cea_dmt()            if($action eq "SET_CEA_DMT");
&set_hostname()           if($action eq "SET_HOSTNAME");
&set_net_to_use()         if($action eq "SET_NET_TO_USE");
&set_output_range()       if($action eq "SET_OUTPUT_RANGE");
&set_scaling_governor()   if($action eq "SET_SCALING_GOVERNOR");
&set_discoverable()       if($action eq "SET_DISCOVERABLE");
&wifi_status()            if($action eq "GET_WIFI_STATUS");
&wifi_scan()              if($action eq "WIFI_SCAN");
&wifi_set_country()       if($action eq "WIFI_SET_COUNTRY");
&wifi_apply_conf()        if($action eq "WIFI_APPLYCONF");
&wifi_disconnect()        if($action eq "WIFI_DISCONNECT");
&wifi_forget()            if($action eq "WIFI_FORGET");
&wifi_ap_apply_conf()     if($action eq "WIFI_AP_APPLYCONF");
&wifi_ap_status()         if($action eq "WIFI_AP_STATUS");
&wifi_ap_enable()         if($action eq "WIFI_AP_ENABLE");
&wifi_ap_disable()        if($action eq "WIFI_AP_DISABLE");
&wifi_radio()             if($action eq "WIFI_RADIO");
&wifi_radio_status()      if($action eq "WIFI_RADIO_STATUS");
&open_iptables_for_ls()   if($action eq "OPEN_IPTABLES_FOR_LS");
&set_pgenerator_conf()    if($action eq "SET_PGENERATOR_CONF");
&set_pgenerator_conf_multi() if($action eq "SET_PGENERATOR_CONF_MULTI");
&set_plugin()             if($action eq "SET_PLUGIN");
&bash_cmd()               if($action eq "BASH_CMD");
&check_video_source_root() if($action eq "CHECK_VIDEO_SOURCE");
&play_video_root()        if($action eq "PLAY_VIDEO");
&stop_video_root()        if($action eq "STOP_VIDEO");
&bt_status()              if($action eq "BT_STATUS");
&bt_set_discoverable()    if($action eq "BT_SET_DISCOVERABLE");
&bt_set_powered()         if($action eq "BT_SET_POWERED");
&bt_set_name()            if($action eq "BT_SET_NAME");
&bt_set_pan_ip()          if($action eq "BT_SET_PAN_IP");
&bt_restart_pan()         if($action eq "BT_RESTART_PAN");
&bt_remove_device()       if($action eq "BT_REMOVE_DEVICE");
&bt_set_agent()           if($action eq "BT_SET_AGENT");
&scanout_probe()          if($action eq "SCANOUT_PROBE");
&hdmi_packet_probe()      if($action eq "HDMI_PACKET");


#
# functions 
#

# Signal self-test: read back the scanned-out framebuffer (root only, GETFB2
# hides the buffer handle from other users). Arguments are a region x y w h.
sub scanout_probe(@) {
 my @region=@ARGV[1..4];
 for(@region) {
  if(!defined($_) || $_!~/^\d{1,5}$/) { print "ERR bad region\n"; exit 1; }
 }
 my $probe="/usr/bin/pgen_scanout";
 if(!-x $probe) { print "ERR $probe missing\n"; exit 1; }
 system($probe,@region);
 exit(0);
}

# Signal self-test: the infoframes in the HDMI packet RAM (root only,
# /dev/mem). Arguments are packet slots.
sub hdmi_packet_probe(@) {
 my @slots=@ARGV[1..$#ARGV];
 for(@slots) {
  if($_!~/^\d{1,2}$/) { print "ERR bad slot\n"; exit 1; }
 }
 my $probe="/usr/bin/pgen_hdmi_packet";
 if(!-x $probe) { print "ERR $probe missing\n"; exit 1; }
 # The caller's environment arrives through sudo -E (SETENV): the read
 # goes to the real device tree and /dev/mem, never to a test's stand-ins.
 delete @ENV{qw(PGEN_DEVICE_TREE PGEN_DEV_MEM)};
 system($probe,@slots);
 exit(0);
}

sub pgen_cmd_exists(@) {
 my $cmd=shift;
 return (defined $cmd && $cmd ne "" && -x $cmd) ? 1 : 0;
}

sub pgen_capture(@) {
 my @cmd=@_;
 return "" if(!@cmd || !&pgen_cmd_exists($cmd[0]));
 my $response="";
 if(open(my $fh,"-|",@cmd)) {
  while(<$fh>) { $response.=$_; }
  close($fh);
 }
 return $response;
}

sub pgen_system_quiet(@) {
 my @cmd=@_;
 return 127 if(!@cmd || !&pgen_cmd_exists($cmd[0]));
 my $pid=fork();
 return system(@cmd) if(!defined $pid);
 if($pid==0) {
  open(STDOUT,">","/dev/null");
  open(STDERR,">","/dev/null");
  exec @cmd;
  exit 127;
 }
 waitpid($pid,0);
 return $? >> 8;
}

sub pgen_service_action(@) {
 my ($init,$service,$verb)=@_;
 if(defined $init && $init ne "" && -x $init) {
  return &pgen_system_quiet($init,$verb);
 }
 if(defined $systemctl && &pgen_cmd_exists($systemctl) && defined $service && $service ne "") {
  return &pgen_system_quiet($systemctl,$verb,$service);
 }
 if(defined $service_cmd && &pgen_cmd_exists($service_cmd) && defined $service && $service ne "") {
  return &pgen_system_quiet($service_cmd,$service,$verb);
 }
 return 127;
}

# Is a process with the given exact name (comm) currently running? Used to
# verify a service stop actually killed the daemon (the hostapd init script
# silently no-ops when its pidfile is stale/missing). Uses pgrep -x so it
# matches the process comm exactly, not a substring. Resolve pgrep to a full
# path because pgen_capture->pgen_cmd_exists uses -x on the literal arg, so a
# bare "pgrep" (relative) is treated as not-found.
sub pgen_process_alive(@) {
 my ($name)=@_;
 return 0 if(!defined $name || $name eq "");
 my $pgrep="/usr/bin/pgrep";
 $pgrep="/bin/pgrep" unless(-x $pgrep);
 return 0 unless(-x $pgrep);
 my $out=&pgen_capture($pgrep,"-x",$name);
 return ($out=~/^\s*\d+/m) ? 1 : 0;
}

sub pgen_service_active(@) {
 my ($process,$service)=@_;
 if(defined $systemctl && &pgen_cmd_exists($systemctl) && defined $service && $service ne "") {
  my $active=&pgen_capture($systemctl,"is-active",$service);
  chomp($active);
  return 1 if($active eq "active");
 }
 # Fall back to an exact-comm process check (pgrep -x). The old "ps aux" +
 # /\bname\b/ regex falsely matched ANY process whose command line mentioned
 # the service name -- including this very PGenerator_cmd.pl invocation (its
 # args contain "hostapd"), so AP_ACTIVE read 1 even after hostapd was killed
 # and the WebUI toggle stayed "on" after a disable. pgrep -x matches the
 # process comm (15-char kernel name), not the argument list.
 return &pgen_process_alive($process);
}

sub pgen_service_exists(@) {
 my $service=shift;
 return 0 if(!defined $service || $service eq "");
 my $unit=($service=~/\.service$/) ? $service : "$service.service";
 my $init=$service;
 $init=~s/\.service$//;
 return 1 if(-e "/etc/systemd/system/$unit" || -e "/lib/systemd/system/$unit");
 return 1 if(-x "/etc/init.d/$init");
 return 0;
}

sub ensure_wifi_conf(@) {
 my $dir=dirname($wifi_conf);
 mkpath($dir) if(!-d $dir);
 if(!-f $wifi_conf) {
  my $content="ctrl_interface=DIR=$dir_wpa GROUP=pgenerator\nupdate_config=1\ncountry=US\n";
  &write_wifi_conf($content);
  return;
 }
 my $content=&read_from_file($wifi_conf);
 if($content!~/^ctrl_interface=/m) {
  $content="ctrl_interface=DIR=$dir_wpa GROUP=pgenerator\n".$content;
 } else {
  $content=~s|^ctrl_interface=.*|ctrl_interface=DIR=$dir_wpa GROUP=pgenerator|m;
 }
 if($content!~/^update_config=/m) {
  $content.="\n" if($content!~/\n$/);
  $content.="update_config=1\n";
 }
 &write_wifi_conf($content);
}

# wpa_supplicant.conf holds the network's PSK: owner only, also the temp
# file it is written through (umask 077 while it is created).
sub write_wifi_conf(@) {
 my $content=shift;
 my $old_umask=umask(077);
 my $ok=&write_file("$wifi_conf.tmp",$wifi_conf,$content);
 umask($old_umask);
 chmod 0600, $wifi_conf if(-f $wifi_conf);
 return $ok;
}

# Read the persisted WiFi-radio intent from /etc/PGenerator/PGenerator.conf.
# The WebUI status poll (wifi_status -> ensure_wlan_client_ready) used to run
# `rfkill unblock wifi` unconditionally, so a user who toggled the radio off
# (wifi_radio=0, rfkill soft-blocked) would see it silently re-enabled a moment
# later -- the toggle then reads the live rfkill state and snaps back to "on".
# Callers that need the radio for an explicit user action (e.g. bringing the AP
# up) must force the unblock themselves.
sub wifi_radio_user_disabled () {
 return 0 if(!-f $pattern_conf);
 my $val="";
 if(open(my $fh,"<",$pattern_conf)) {
  while(<$fh>) {
   next unless(/^\s*wifi_radio\s*=\s*(\S+)/);
   $val=$1;
   last;
  }
  close($fh);
 }
 return (defined $val && $val eq "0") ? 1 : 0;
}

sub ensure_wlan_client_ready(@) {
 my $interface=shift;
 &ensure_wifi_conf();
 # Honor the persisted radio-off intent: do NOT unblock here. This runs on every
 # status poll and would otherwise clobber a user's wifi_radio=0 toggle.
 &pgen_system_quiet($rfkill,"unblock","wifi") if(defined $rfkill && &pgen_cmd_exists($rfkill) && !&wifi_radio_user_disabled());
 &pgen_system_quiet($ip,"link","set",$interface,"up") if(defined $ip && &pgen_cmd_exists($ip));
 &pgen_service_action("","wpa_supplicant","start");
 if(defined $wpa_supplicant && &pgen_cmd_exists($wpa_supplicant) && !-S "$dir_wpa/$interface") {
  &pgen_system_quiet($wpa_supplicant,"-B","-i",$interface,"-c",$wifi_conf);
 }
}

sub wifi_ipv4(@) {
 my $interface=shift;
 return "" if(!defined $interface || $interface eq "");
 if(defined $ip && &pgen_cmd_exists($ip)) {
  my $addr=&pgen_capture($ip,"-o","-4","addr","show","dev",$interface,"scope","global");
  foreach my $line (split(/\n/,$addr)) {
   return $1 if($line=~/\sinet\s+(\d+\.\d+\.\d+\.\d+)\/\d+/);
  }
 } elsif(defined $ifconfig && &pgen_cmd_exists($ifconfig)) {
  my $addr=&pgen_capture($ifconfig,$interface);
  return $1 if($addr=~/inet\s+(?:addr:)?(\d+\.\d+\.\d+\.\d+)/);
 }
 return "";
}

sub wifi_dhcp_process_running(@) {
 my $interface=shift;
 return 0 if(!defined $interface || $interface eq "");
 my $ps=`ps aux 2>/dev/null`;
 return ($ps=~/\bdhclient\b[^\n]*\b\Q$interface\E\b/ || $ps=~/\bdhcpcd\b[^\n]*\b\Q$interface\E\b/ || $ps=~/\budhcpc\b[^\n]*\b\Q$interface\E\b/) ? 1 : 0;
}

sub wifi_set_route_metric(@) {
 my ($interface,$metric)=@_;
 return if(!defined $interface || $interface eq "" || !defined $metric || $metric eq "");
 return if(!defined $ip || !&pgen_cmd_exists($ip));
 my $routes=&pgen_capture($ip,"-o","route","show","default","dev",$interface);
 foreach my $line (split(/\n/,$routes)) {
  next if($line !~ /\bvia\s+(\d+\.\d+\.\d+\.\d+)/);
  my $gateway=$1;
  &pgen_system_quiet($ip,"route","del","default","via",$gateway,"dev",$interface);
  &pgen_system_quiet($ip,"route","replace","default","via",$gateway,"dev",$interface,"metric",$metric);
 }
}

sub wifi_start_dhcp(@) {
 my ($interface,$wait_seconds)=@_;
 $wait_seconds=0 if(!defined $wait_seconds);
 my $addr=&wifi_ipv4($interface);
 if($addr ne "") {
  &wifi_set_route_metric($interface,600) if($interface ne $eth_interface);
  return $addr;
 }
 return "" if(!defined $interface || $interface eq "");

 if(defined $dhclient && &pgen_cmd_exists($dhclient)) {
  if($wait_seconds > 0 && defined $timeout && &pgen_cmd_exists($timeout)) {
   &pgen_system_quiet($timeout,"$wait_seconds",$dhclient,"-1","-q",$interface);
  } elsif(!&wifi_dhcp_process_running($interface)) {
   &pgen_system_quiet($dhclient,"-nw",$interface);
  }
 } elsif(defined $dhcpcd && &pgen_cmd_exists($dhcpcd)) {
  if($wait_seconds > 0 && defined $timeout && &pgen_cmd_exists($timeout)) {
   &pgen_system_quiet($timeout,"$wait_seconds",$dhcpcd,"-n",$interface);
  } elsif(!&wifi_dhcp_process_running($interface)) {
   &pgen_system_quiet($dhcpcd,"-n",$interface);
  }
 } elsif(defined $udhcpc && &pgen_cmd_exists($udhcpc)) {
  if($wait_seconds > 0 && defined $timeout && &pgen_cmd_exists($timeout)) {
   &pgen_system_quiet($timeout,"$wait_seconds",$udhcpc,"-i",$interface,"-q");
  } elsif(!&wifi_dhcp_process_running($interface)) {
   &pgen_system_quiet($udhcpc,"-i",$interface,"-q","-b");
  }
 }

 $addr=&wifi_ipv4($interface);
 &wifi_set_route_metric($interface,600) if($addr ne "" && $interface ne $eth_interface);
 return $addr;
}

sub wifi_release_dhcp(@) {
 my $interface=shift;
 return if(!defined $interface || $interface eq "");
 &pgen_system_quiet($dhclient,"-r",$interface) if(defined $dhclient && &pgen_cmd_exists($dhclient));
 &pgen_system_quiet($dhcpcd,"-k",$interface) if(defined $dhcpcd && &pgen_cmd_exists($dhcpcd));
 &pgen_system_quiet($ip,"addr","flush","dev",$interface,"scope","global") if(defined $ip && &pgen_cmd_exists($ip));
}

sub wifi_wait_completed(@) {
 my ($interface,$ssid,$seconds)=@_;
 $seconds=15 if(!defined $seconds || $seconds <= 0);
 my $tries=$seconds*2;
 for(my $i=0;$i<$tries;$i++) {
  my $status=&pgen_capture($wpa_cli,"-i",$interface,"status");
  my $state="";
  my $connected_ssid="";
  $state=$1 if($status=~/^wpa_state=(.*)$/m);
  $connected_ssid=$1 if($status=~/^ssid=(.*)$/m);
  return 1 if($state eq "COMPLETED" && (!defined $ssid || $ssid eq "" || $connected_ssid eq $ssid));
  usleep(500000);
 }
 return 0;
}

###############################################
#             Wifi Scan function              #
###############################################
sub wifi_status (@) {
 my $response = "";
 $interface=$ARGV[1];
 # validation
 $interface=~s/ //g;
 return if($interface eq "");
 if(!&pgen_cmd_exists($wpa_cli)) {
  print "PGEN_ERROR=wpa_cli not found\n";
  return;
 }
 &ensure_wlan_client_ready($interface);
 $response=&pgen_capture($wpa_cli,"-i",$interface,"status");
 chomp($response);
 my $has_ip=($response=~/^ip_address=/m) ? 1 : 0;
 my $state="";
 $state=$1 if($response=~/^wpa_state=(.*)$/m);
 if($state eq "COMPLETED" && $has_ip) {
  &wifi_set_route_metric($interface,600) if($interface ne $eth_interface);
 } elsif($state eq "COMPLETED" && !$has_ip) {
  my $addr=&wifi_ipv4($interface);
  $addr=&wifi_start_dhcp($interface,5) if($addr eq "");
  $addr=&wifi_start_dhcp($interface,0) if($addr eq "");
  if($addr ne "") {
   $response.="\n" if($response ne "" && $response!~/\n$/);
   $response.="ip_address=$addr";
  }
 }
 print $response;
}

###############################################
#             Wifi Scan function              #
###############################################
sub wifi_scan (@) {
 my $response = "";
 $interface=$ARGV[1];
 # validation
 $interface=~s/ //g;
 return if($interface eq "");
 if(!&pgen_cmd_exists($wpa_cli)) {
  print "PGEN_ERROR=wpa_cli not found\n";
  return;
 }
 &ensure_wlan_client_ready($interface);
 # Auto-set regulatory domain from wpa_supplicant.conf for 5GHz support
 if(-f $wifi_conf) {
  my $content=&read_from_file($wifi_conf);
  if($content=~/^country=([A-Za-z]{2})/m) {
   my $cc=uc($1);
   &pgen_system_quiet($iw,"reg","set",$cc) if(defined $iw && &pgen_cmd_exists($iw));
  }
 }
 &pgen_system_quiet($wpa_cli,"-i",$interface,"scan");
 sleep(3);
 $response=&pgen_capture($wpa_cli,"-i",$interface,"scan_results");
 if($response=~/^FAIL/m || $response eq "") {
  print "PGEN_ERROR=WiFi scan failed\n$response";
  return;
 }
 print $response;
}

###############################################
#        Wifi Set Country function            #
###############################################
sub wifi_set_country (@) {
 $interface=$ARGV[1];
 my $country=$ARGV[2];
 $interface=~s/ //g;
 $country=~s/[^A-Za-z]//g;
 $country=uc($country);
 return if($interface eq "" || length($country) != 2);
 return print "ERR" if(!&pgen_cmd_exists($wpa_cli));
 &ensure_wlan_client_ready($interface);
 &pgen_system_quiet($wpa_cli,"-i",$interface,"set","country",$country);
 &pgen_system_quiet($wpa_cli,"-i",$interface,"save_config");
 &pgen_system_quiet($iw,"reg","set",$country) if(defined $iw && &pgen_cmd_exists($iw));
 # Also persist in wpa_supplicant.conf
 if(-f $wifi_conf) {
  my $content=&read_from_file($wifi_conf);
  if($content=~/^country=/m) {
   $content=~s/^country=.*/country=$country/m;
  } else {
   $content=~s/(ctrl_interface=.*\n)/$1country=$country\n/;
  }
  &write_wifi_conf($content);
 }
 &pgen_system_quiet($wpa_cli,"-i",$interface,"disconnect");
 sleep(1);
 &pgen_system_quiet($wpa_cli,"-i",$interface,"reconnect");
 print "OK";
}

###############################################
#          Wifi AP Password function          #
###############################################
sub normalize_hostapd_ap_security (@) {
 my ($content)=@_;
 $content="" if(!defined $content);
 my %wanted=(
  auth_algs=>"1",
  wpa=>"2",
  wpa_key_mgmt=>"WPA-PSK",
  wpa_pairwise=>"CCMP",
  rsn_pairwise=>"CCMP",
  ignore_broadcast_ssid=>"0"
 );
 foreach my $key (qw(auth_algs wpa wpa_key_mgmt wpa_pairwise rsn_pairwise ignore_broadcast_ssid)) {
  if($content=~/^$key=/m) {
   $content=~s/^$key=.*/$key=$wanted{$key}/m;
  } else {
   $content.="\n" if($content ne "" && $content!~/\n$/);
   $content.="$key=$wanted{$key}\n";
  }
 }
 return $content;
}

sub pgen_ap_net(@) {
 my $ap_net="10.10.10";
 if(-f $rcPGenerator_default_file) {
  my $content=&read_from_file($rcPGenerator_default_file);
  if($content=~/^AP_NET="?([0-9]+\.[0-9]+\.[0-9]+)"?/m) {
   $ap_net=$1;
  }
 }
 return $ap_net;
}

sub hostapd_conf_value(@) {
 my ($key,$default)=@_;
 return $default if(!-f $hostapd_conf);
 my $content=&read_from_file($hostapd_conf);
 return $1 if($content=~/^\Q$key\E=(.*)$/m);
 return $default;
}

sub update_hostapd_conf(@) {
 my ($ssid,$password,$interface)=@_;
 my $content=&read_from_file($hostapd_conf);
 $content="interface=$interface\ndriver=nl80211\nhw_mode=g\nchannel=11\nssid=$ssid\nwpa_passphrase=$password\n" if($content eq "");
 $content=~s/^interface=.*/interface=$interface/m if(defined $interface && $interface ne "");
 $content=~s/^ssid=.*/ssid=$ssid/m if(defined $ssid && $ssid ne "");
 $content=~s/^wpa_passphrase=.*/wpa_passphrase=$password/m if(defined $password && $password ne "");
 $content=&normalize_hostapd_ap_security($content);
 mkpath(dirname($hostapd_conf)) if(!-d dirname($hostapd_conf));
 &write_file("$hostapd_conf.tmp",$hostapd_conf,$content);
}

sub configure_dnsmasq_ap(@) {
 my ($interface,$ap_net)=@_;
 return 1 if(!defined $dnsmasq_bin || !&pgen_cmd_exists($dnsmasq_bin));
 my $dir="/etc/dnsmasq.d";
 mkpath($dir) if(!-d $dir);
 my $conf="$dir/pgenerator-ap.conf";
 my $content="interface=$interface\nbind-dynamic\ndhcp-range=$ap_net.50,$ap_net.150,255.255.255.0,12h\ndhcp-option=3,$ap_net.1\ndhcp-option=6,$ap_net.1\n";
 if(open(my $fh,">",$conf)) {
  print $fh $content;
  close($fh);
 }
 &pgen_service_action("","dnsmasq","restart");
 return 1;
}

sub wifi_ap_gateway_ready(@) {
 my ($interface,$ap_net)=@_;
 return 0 if(!defined $interface || $interface eq "" || !defined $ap_net || $ap_net eq "");
 if(defined $ip && &pgen_cmd_exists($ip)) {
  my $addr=&pgen_capture($ip,"-o","-4","addr","show","dev",$interface);
  return 1 if($addr=~/\b\Q$ap_net\E\.1\/24\b/);
 } elsif(defined $ifconfig && &pgen_cmd_exists($ifconfig)) {
  my $addr=&pgen_capture($ifconfig,$interface);
  return 1 if($addr=~/\b\Q$ap_net\E\.1\b/);
 }
 return 0;
}

sub wifi_ap_ensure_gateway(@) {
 my ($interface,$ap_net)=@_;
 return 0 if(!defined $interface || $interface eq "" || !defined $ap_net || $ap_net eq "");
 &pgen_system_quiet($ip,"link","set",$interface,"up") if(defined $ip && &pgen_cmd_exists($ip));
 if(!&wifi_ap_gateway_ready($interface,$ap_net)) {
  if(defined $ip && &pgen_cmd_exists($ip)) {
   &pgen_system_quiet($ip,"addr","add","$ap_net.1/24","dev",$interface);
  } elsif(defined $ifconfig && &pgen_cmd_exists($ifconfig)) {
   &pgen_system_quiet($ifconfig,$interface,"$ap_net.1","netmask","255.255.255.0","up");
  }
 }
 return &wifi_ap_gateway_ready($interface,$ap_net);
}

sub wifi_ap_prepare_interface(@) {
 my $base_interface=shift || "wlan0";
 my $ap_interface="ap0";
 my $ap_net=&pgen_ap_net();
 &pgen_system_quiet($rfkill,"unblock","wifi") if(defined $rfkill && &pgen_cmd_exists($rfkill));
 if(defined $iw && &pgen_cmd_exists($iw)) {
  my $base_info=&pgen_capture($iw,"dev",$base_interface,"info");
  if($base_info=~/\btype\s+AP\b/) {
   &pgen_service_action($hostapd_init,"hostapd","stop");
   &pgen_system_quiet($ip,"link","set",$base_interface,"down") if(defined $ip && &pgen_cmd_exists($ip));
   &pgen_system_quiet($iw,"dev",$base_interface,"set","type","managed");
   &pgen_system_quiet($ip,"link","set",$base_interface,"up") if(defined $ip && &pgen_cmd_exists($ip));
  }
  my $ap_info=&pgen_capture($iw,"dev","ap0","info");
  if($ap_info eq "") {
   &pgen_system_quiet($iw,"dev",$base_interface,"interface","add","ap0","type","__ap");
   $ap_info=&pgen_capture($iw,"dev","ap0","info");
  }
  $ap_interface="ap0" if($ap_info ne "");
 }
 $ap_interface=$base_interface if($ap_interface eq "");
 &pgen_system_quiet($ip,"link","set",$ap_interface,"up") if(defined $ip && &pgen_cmd_exists($ip));
 if(defined $ip && &pgen_cmd_exists($ip)) {
  &pgen_system_quiet($ip,"addr","flush","dev",$ap_interface);
  &pgen_system_quiet($ip,"addr","add","$ap_net.1/24","dev",$ap_interface);
 } elsif(defined $ifconfig && &pgen_cmd_exists($ifconfig)) {
  &pgen_system_quiet($ifconfig,$ap_interface,"$ap_net.1","netmask","255.255.255.0","up");
 }
 return ($ap_interface,$ap_net);
}

sub wifi_ap_apply_conf (@) {
 $ssid=$ARGV[1];
 $password=$ARGV[2];
 return print "ERR:SSID required" if($ssid eq "");
 return print "ERR:Password must be at least 8 characters" if(length($password)<8);
 return print "ERR:hostapd not installed" if(!&pgen_cmd_exists($hostapd_bin) && !&pgen_service_exists("hostapd.service"));
 my $interface=&hostapd_conf_value("interface","wlan0");
 &update_hostapd_conf($ssid,$password,$interface);
 my $restart=&wifi_ap_enable_impl("wlan0");
 if($restart !~ /^OK/) {
  print $restart;
 } else {
  print "OK";
 }
}

sub wifi_ap_status (@) {
 my $interface=&hostapd_conf_value("interface","wlan0");
 my $ap_net=&pgen_ap_net();
 my $hostapd_available=(&pgen_cmd_exists($hostapd_bin) || -x $hostapd_init || &pgen_cmd_exists($systemctl) || &pgen_cmd_exists($service_cmd)) ? 1 : 0;
 my $dnsmasq_available=&pgen_cmd_exists($dnsmasq_bin) ? 1 : 0;
 my $active=&pgen_service_active("hostapd","hostapd");
 my $dnsmasq_active=&pgen_service_active("dnsmasq","dnsmasq");
 my $gateway_ready=0;
 if($active) {
  $gateway_ready=&wifi_ap_ensure_gateway($interface,$ap_net);
  &configure_dnsmasq_ap($interface,$ap_net) if($gateway_ready && !$dnsmasq_active);
  $dnsmasq_active=&pgen_service_active("dnsmasq","dnsmasq");
 }
 $active=0 if($active && !$gateway_ready);
 print "AP_AVAILABLE=$hostapd_available\n";
 print "AP_ACTIVE=$active\n";
 print "AP_INTERFACE=$interface\n";
 print "AP_NET=$ap_net\n";
 print "AP_ADDRESS=$ap_net.1\n";
 print "AP_GATEWAY_READY=$gateway_ready\n";
 print "DNSMASQ_AVAILABLE=$dnsmasq_available\n";
 print "DNSMASQ_ACTIVE=$dnsmasq_active\n";
}

sub wifi_ap_enable_impl (@) {
 # The caller names the interface: under WIFI_AP_APPLYCONF $ARGV[1] is the SSID.
 my $base_interface=$_[0] || "wlan0";
 my $ssid=&hostapd_conf_value("ssid","PGenerator");
 my $password=&hostapd_conf_value("wpa_passphrase","PGenerator");
 return "ERR:hostapd not installed" if(!&pgen_cmd_exists($hostapd_bin) && !&pgen_service_exists("hostapd.service"));
 return "ERR:AP password must be at least 8 characters" if(length($password)<8);
 my ($ap_interface,$ap_net)=&wifi_ap_prepare_interface($base_interface);
 &update_hostapd_conf($ssid,$password,$ap_interface);
 &configure_dnsmasq_ap($ap_interface,$ap_net);
 my $start=&pgen_service_action($hostapd_init,"hostapd","restart");
 &wifi_ap_ensure_gateway($ap_interface,$ap_net);
 if($start!=0) {
  return "ERR:hostapd failed to start";
 } else {
  return "OK";
 }
}

sub wifi_ap_enable (@) {
 print &wifi_ap_enable_impl($ARGV[1] || "wlan0");
}

sub wifi_ap_disable (@) {
 my $stop=&pgen_service_action($hostapd_init,"hostapd","stop");
 if(-f "/etc/dnsmasq.d/pgenerator-ap.conf") {
  unlink("/etc/dnsmasq.d/pgenerator-ap.conf");
  &pgen_service_action("","dnsmasq","restart");
 }
 if($stop==127) {
  print "ERR:hostapd service not available";
  return;
 }
 # The init script's stop reads /var/run/hostapd/hostapd.pid and SIGTERMs that
 # PID. The pidfile is wiped on stop, so after any kill/crash/restart cycle that
 # bypassed the init script the pidfile is missing and `stop` silently no-ops
 # (returns 0, prints "done", hostapd keeps running) -- the WebUI then reports
 # success while the AP stays up. Verify the process is actually gone and fall
 # back to pkill (-TERM then -KILL) if it survived.
 if(&pgen_process_alive("hostapd")) {
  system("/usr/bin/pkill","-TERM","-x","hostapd");
  my $wait; for($wait=0;$wait<5;$wait++){ last unless(&pgen_process_alive("hostapd")); select(undef,undef,undef,0.3); }
  if(&pgen_process_alive("hostapd")) {
   system("/usr/bin/pkill","-KILL","-x","hostapd");
   select(undef,undef,undef,0.5);
  }
 }
 print &pgen_process_alive("hostapd") ? "ERR:hostapd could not be stopped" : "OK";
}

###############################################
#            Apply Conf function              #
###############################################
sub wifi_apply_conf (@) {
 my ($response,$psk_pass) = "";
 $interface=$ARGV[1];
 $ssid=$ARGV[2];
 $password=$ARGV[3];
 return if($interface eq "");
 return print "ERR:wpa_cli not found" if(!&pgen_cmd_exists($wpa_cli));
 &ensure_wlan_client_ready($interface);
 if(defined $password && $password ne "") {
  return print "ERR:wpa_passphrase not found" if(!&pgen_cmd_exists($wpa_passphrase));
  $pid = open2($CMD_READ, $CMD_WRITE, $wpa_passphrase, $ssid);
  print $CMD_WRITE "$password\n";
  close($CMD_WRITE);
  while(<$CMD_READ>) {
   chomp($_);
   next if(!/psk/ || /#/);
   /psk=(.*)/;
   $psk_pass=$1;
  }
  close($CMD_READ);
  waitpid($pid,0);
  return print "ERR:Unable to generate WiFi PSK" if($psk_pass eq "");
 }
 &pgen_system_quiet($wpa_cli,"-i",$interface,"remove_network","all");
 &pgen_system_quiet($wpa_cli,"-i",$interface,"flush");
 my $netid=&pgen_capture($wpa_cli,"-i",$interface,"add_network");
 chomp($netid);
 $netid=0 if($netid!~/^\d+$/);
 &pgen_system_quiet($wpa_cli,"-i",$interface,"set_network",$netid,"ssid","\"$ssid\"");
 if(defined $password && $password ne "") {
  &pgen_system_quiet($wpa_cli,"-i",$interface,"set_network",$netid,"psk",$psk_pass);
 } else {
  &pgen_system_quiet($wpa_cli,"-i",$interface,"set_network",$netid,"key_mgmt","NONE");
 }
 &pgen_system_quiet($wpa_cli,"-i",$interface,"enable_network",$netid);
 &pgen_system_quiet($wpa_cli,"-i",$interface,"select_network",$netid);
 &pgen_system_quiet($wpa_cli,"-i",$interface,"save_config");
 &wifi_release_dhcp($interface);
 &pgen_system_quiet($wpa_cli,"-i",$interface,"reconfigure");
 &pgen_system_quiet($wpa_cli,"-i",$interface,"reconnect");
 if(!&wifi_wait_completed($interface,$ssid,20)) {
  print "ERR:WiFi association timed out";
  return;
 }
 my $addr=&wifi_start_dhcp($interface,18);
 if($addr ne "") {
  print "OK\nip_address=$addr";
 } else {
  print "OK\nwarning=Associated but no IPv4 lease yet";
 }
}

###############################################
#           Wifi Disconnect function          #
###############################################
sub wifi_disconnect (@) {
 my $response = "";
 $interface=$ARGV[1];
 $interface=~s/ //g;
 return if($interface eq "");
 return print "ERR:wpa_cli not found" if(!&pgen_cmd_exists($wpa_cli));
 &pgen_system_quiet($wpa_cli,"-i",$interface,"disconnect");
 &wifi_release_dhcp($interface);
 print "OK";
}

sub wifi_forget (@) {
 $interface=$ARGV[1];
 $interface=~s/ //g;
 return if($interface eq "");
 return print "ERR:wpa_cli not found" if(!&pgen_cmd_exists($wpa_cli));
 &pgen_system_quiet($wpa_cli,"-i",$interface,"remove_network","all");
 &pgen_system_quiet($wpa_cli,"-i",$interface,"save_config");
 &pgen_system_quiet($wpa_cli,"-i",$interface,"disconnect");
 &wifi_release_dhcp($interface);
 print "OK";
}

sub wifi_rfkill_sysfs_node (@) {
 # Locate the kernel rfkill sysfs node of type "wlan". The rfkill userspace
 # binary is not present on every image, but /sys/class/rfkill is, so this is
 # the portable control path. Returns the node dir (e.g. /sys/class/rfkill/rfkill2) or "".
 my $base="/sys/class/rfkill";
 return "" if(!-d $base);
 opendir(my $dh,$base) or return "";
 my @nodes=sort grep { /^rfkill\d+$/ } readdir($dh);
 closedir($dh);
 foreach my $n (@nodes) {
  my $type=&read_from_file("$base/$n/type");
  chomp($type);
  return "$base/$n" if($type eq "wlan");
 }
 return "";
}

sub wifi_radio (@) {
 my $val=$ARGV[1];
 return print $error_response if($val ne "on" && $val ne "off");
 my $did=0;
 if(defined $rfkill && &pgen_cmd_exists($rfkill)) {
  if($val eq "on") { &pgen_system_quiet($rfkill,"unblock","wifi"); }
  else { &pgen_system_quiet($rfkill,"block","wifi"); }
  $did=1;
 } else {
  my $node=&wifi_rfkill_sysfs_node();
  if($node ne "" && open(my $fh,">","$node/soft")) {
   print $fh ($val eq "on" ? "0" : "1")."\n";
   close($fh);
   $did=1;
  }
 }
 return print "ERR:no rfkill control available" if(!$did);
 &pgen_system_quiet($ip,"link","set","wlan0","up") if($val eq "on" && defined $ip && &pgen_cmd_exists($ip));
 print $ok_response;
}

sub wifi_radio_status (@) {
 my $available=0;
 my $blocked=0;
 if(defined $rfkill && &pgen_cmd_exists($rfkill)) {
  $available=1;
  my $out=&pgen_capture($rfkill,"list","wifi");
  $blocked=1 if($out=~/soft\s+blocked:\s*yes/i);
 } else {
  my $node=&wifi_rfkill_sysfs_node();
  if($node ne "") {
   $available=1;
   my $soft=&read_from_file("$node/soft");
   chomp($soft);
   $blocked=1 if($soft eq "1");
  }
 }
 print "WIFI_RADIO_AVAILABLE=$available\n";
 print "WIFI_BLOCKED=$blocked\n";
}

###############################################
#              Apply Bootloader               #
###############################################
sub apply_bootloader () {
 my $no_reboot = shift;
 $ENV{COPY_ONLY_FILES}=$bootloader_config_file;
 system("$boot_loader_bin");
 return if($no_reboot);
 &reboot();
}

###############################################
#               Reboot function               #
###############################################
sub reboot(@) {
 &boot_time_mark("shutdown: reboot requested");
 &persist_meter_settings_legacy();
 &process_pid("$pattern_generator.pl","kill");
 &stop_renderer_for_shutdown();
 &boot_time_mark("shutdown: renderer stopped");
 &reset_hdmi_output();
 &boot_time_mark("shutdown: HDMI output reset");
 # Animated restart screen on the console framebuffer (plain RGB now) until
 # sendsigs ends it; the next boot shows its own progress.
 system("/usr/sbin/pgen_bootscreen reboot --daemon >/dev/null 2>&1") if(-x "/usr/sbin/pgen_bootscreen");
 system("$reboot");
}

###############################################
#   Stop renderer and meter before shutdown   #
###############################################
sub stop_renderer_for_shutdown(@) {
 # The renderer holds DRM master and an in-flight spotread holds the
 # meter's USB claim. Leaving them for init's blanket sendsigs lets a
 # process stuck in an uninterruptible DRM/USB ioctl wedge the late
 # shutdown (observed as a WebUI reboot that never completes, with the
 # console showing the stale boot splash once fbcon takes the
 # framebuffer back). There is no K-script on this image, so tear them
 # down here the way the init script's stop) case does.
 # TERM first: on exit the renderer puts the connector back to RGB and
 # takes its planes off in one commit, so the console framebuffer is never
 # shown with YCbCr signalling (black read as YCbCr is green). -9 only when
 # it is still there after 3 s.
 my @pids=&renderer_pids();
 if(@pids) {
  kill('TERM',@pids);
  for(my $i=0;$i<30 && &renderer_pids();$i++) {
   select(undef,undef,undef,0.1);
  }
 }
 # The pattern "PGeneratord" also matches PGeneratord.dv and its sh wrapper
 # but not this process or PGenerator_serial.pl.
 system("/usr/bin/pkill -9 -f PGeneratord 2>/dev/null");
 system("/usr/bin/pkill -9 -f spotread 2>/dev/null");
}

# The renderer runs as PGeneratord, or PGeneratord.dv for Dolby Vision.
sub renderer_pids(@) {
 my @pids;
 foreach my $dir (glob("/proc/[0-9]*")) {
  open(my $fh,"<","$dir/comm") or next;
  my $comm=<$fh>;
  close($fh);
  next if(!defined $comm);
  chomp($comm);
  push(@pids,(split(m{/},$dir))[-1]) if($comm eq "PGeneratord" || $comm eq "PGeneratord.dv");
 }
 return @pids;
}

###############################################
#   Reset HDMI output before reboot/halt      #
###############################################
sub reset_hdmi_output(@) {
 # The renderer's connector properties outlive it in the kernel. With a
 # YCbCr output format left set, the sink keeps decoding YCbCr while the
 # shutdown and the firmware restart briefly send all-zero pixels, which
 # a YCbCr decoder shows as a green screen. Put the link back to 8 bpc
 # RGB SDR so those zeros arrive as black. The renderer does the same on
 # TERM (ResetConnectorOnExit): only what is still set otherwise is
 # written, read from the same listing that finds the connector. A
 # property whose value cannot be read is written.
 my ($connector_id,$props)=&hdmi_connector_props();
 return if($connector_id eq "");
 my $colour=exists($props->{"Colorimetry"}) ? "Colorimetry" : (exists($props->{"Colorspace"}) ? "Colorspace" : "");
 $colour=&kms_connector_has_property("Colorimetry") ? "Colorimetry" : "Colorspace" if($colour eq "");
 my @writes;
 foreach my $w (["output format",0],["max bpc",8],["HDR_OUTPUT_METADATA",0],[$colour,0]) {
  my $v=$props->{$w->[0]};
  push(@writes,$w) if(!defined($v) || $v ne "$w->[1]");
 }
 return if(!@writes);
 local $is_kms=1;
 &wait_for_drm_master_unowned(2);
 &modetest_connector_write($connector_id,@$_) foreach(@writes);
}

# The connected HDMI connector's id and its property values from one
# "modetest -c": enum and range as the number, a blob as 0 when empty and
# "set" otherwise. ("",{}) when there is none.
sub hdmi_connector_props(@) {
 my ($connector_id,%props,$name);
 $connector_id="";
 open(MT,"timeout 3 $modetest -c 2>/dev/null|") or return ("",{});
 while(<MT>) {
  if(/^(\d+)\s+\d+\s+(\S+)\s+(\S+)/) {
   my ($id,$status,$conn)=($1,$2,$3);
   last if($connector_id ne "");
   $connector_id=$id if($status eq "connected" && $conn=~/^HDMI/);
   next;
  }
  next if($connector_id eq "");
  if(/^\t\d+ (.+):$/) { $name=$1; next; }
  next if(!defined $name);
  if(/^\t\tvalue:\s*(\S*)\s*$/) {
   $props{$name}=$1 eq "" ? 0 : $1;
   next;
  }
  # A blob's value is the hex dump on the lines after "value:".
  $props{$name}="set" if(/^\t\t\t[0-9a-f]+\s*$/ && exists($props{$name}));
 }
 close(MT);
 return ($connector_id,\%props);
}

###############################################
#                Halt function                #
###############################################
sub halt(@) {
 &persist_meter_settings_legacy();
 # Same teardown as reboot(): see stop_renderer_for_shutdown().
 &process_pid("$pattern_generator.pl","kill");
 &stop_renderer_for_shutdown();
 &reset_hdmi_output();
 system("$halt");
}

sub persist_meter_settings_legacy(@) {
 my $src="/var/lib/PGenerator/meter_settings.json";
 my $dst="/usr/share/PGenerator/meter_settings.json";
 return if(!-f $src);
 my $json=&read_from_file($src);
 return if($json eq "" || $json!~/^\{/);
 my $tmp="$dst.tmp";
 if(open(my $fh,">",$tmp)) {
  print $fh $json;
  close($fh);
  chmod 0644, $tmp;
  if(rename($tmp,$dst)) {
   system("timeout 3 $sync >/dev/null 2>&1");
   return;
  }
  unlink($tmp) if(-f $tmp);
 }
}

###############################################
#       Set Discovery Status function         #
###############################################
sub set_discoverable(@) {
 $status=$ARGV[1];
 &write_file($discoverable_disabled_file,"","DISABLED")  if(!$status); 
 unlink($discoverable_disabled_file)                      if($status);
}

###############################################
#          Set dtoverlay function             #
###############################################
sub set_dtoverlay(@) {
 my ($dtoverlay,$enabled)=split(":",$ARGV[1]);
 # No name would match, and drop, every overlay line.
 return if(!defined($dtoverlay) || $dtoverlay eq "");
 my $content="";
 $content="dtoverlay=$dtoverlay\n" if($enabled);
 my @row=split("\n",&read_from_file($bootloader_file));
 for(@row) {
  # The name is text, not a pattern.
  next if(/dtoverlay=\Q$dtoverlay\E/);
  $content.="$_\n";
 }
 &write_file("$bootloader_file.tmp",$bootloader_file,$content);
 &apply_bootloader();
}

###############################################
#          Set boot config function           #
###############################################
sub set_boot_config(@) {
 my @boot_config=split("\\\\n",$ARGV[1]);
 my @row=split("\n",&read_from_file($bootloader_file));
 my $content="";
 for(@boot_config) { 
  my ($field,$value)=split("=",$_,2);
  next if($value eq "");
  $content.="$_\n";
 }
 foreach my $row (@row) {
  my $find=0;
  for(@boot_config) { 
   my ($field,$value)=split("=",$_,2);
   if($row=~/^\Q$field\E=/) {
    $find=1;
    last;
   }
  }
  next if($find);
  $content.="$row\n";
 }
 &write_file("$bootloader_file.tmp",$bootloader_file,$content);
 &apply_bootloader();
}

###############################################
#         Set GPU Memory function             #
###############################################
sub set_gpu_memory(@) {
 $g_mem=$ARGV[1];
 # validation
 if($g_mem =~/^64$|^128$|^192$|^256$/) {
  my $content=&read_from_file($bootloader_file);
  $content=~s/\ngpu_mem=.*/\ngpu_mem=$g_mem/;
  &write_file("$bootloader_file.tmp",$bootloader_file,$content);
  &apply_bootloader();
 }
}

###############################################
#         Set CMA Memory function             #
#  Pi 5 / Bookworm: the VideoCore firmware    #
#  split (gpu_mem) is ignored; scanout and 3D #
#  buffers come from the kernel CMA pool that #
#  the vc4-kms-v3d overlay sizes (cma-NNN).   #
###############################################
# Values the vc4-kms-v3d overlay accepts (MB); "default" drops the parameter
# (64 MB on Raspberry Pi OS). Kept in a sub: the action dispatch at the top
# of this file runs before any top-level assignment placed down here.
sub cma_memory_values(@) {
 return ("default",64,96,128,192,256,320,384,448,512);
}
sub cma_memory_value_ok(@) {
 my $v=shift; $v="" if(!defined $v);
 for(&cma_memory_values()) { return 1 if("$_" eq "$v"); }
 return 0;
}
# Rewrite the first vc4-kms-v3d overlay line of a config.txt so its cma-
# parameter matches $val, keeping every other parameter on that line. The
# overlay name is anchored so vc4-kms-v3d-pi4 style variants are not touched.
sub cma_rewrite_boot_config(@) {
 my ($content,$val)=@_;
 return $content if(!&cma_memory_value_ok($val));
 my $param=($val eq "default") ? "" : ",cma-$val";
 if($content=~/^(dtoverlay=vc4-kms-v3d)((?:,[^\n]*)?)$/m) {
  my ($name,$params)=($1,$2);
  my @keep=grep { $_ ne "" && $_ !~ /^cma-/ } split(/,/,$params);
  my $line=$name.(@keep ? ",".join(",",@keep) : "").$param;
  $content=~s/^dtoverlay=vc4-kms-v3d(?:,[^\n]*)?$/$line/m;
 } elsif($param ne "") {
  $content.="\n" if($content ne "" && $content!~/\n\z/);
  $content.="dtoverlay=vc4-kms-v3d$param\n";
 }
 return $content;
}
sub set_cma_memory(@) {
 my $cma_val=$ARGV[1];
 if(&cma_memory_value_ok($cma_val)) {
  my $content=&read_from_file($bootloader_file);
  $content=&cma_rewrite_boot_config($content,$cma_val);
  &write_file("$bootloader_file.tmp",$bootloader_file,$content);
  &apply_bootloader();
 }
}

###############################################
#       Set Boot Memory function              #
#  Sets gpu_mem and CMA in one operation      #
###############################################
sub set_boot_memory(@) {
 my $gpu_val=$ARGV[1];
 my $cma_val=$ARGV[2];
 my $changed=0;
 my $content=&read_from_file($bootloader_file);
 # Set gpu_mem
 if($gpu_val =~/^64$|^128$|^192$|^256$/) {
  $content=~s/\ngpu_mem=.*/\ngpu_mem=$gpu_val/;
  $changed=1;
 }
 # Set CMA overlay parameter
 if(&cma_memory_value_ok($cma_val)) {
  $content=&cma_rewrite_boot_config($content,$cma_val);
  $changed=1;
 }
 if($changed) {
  &write_file("$bootloader_file.tmp",$bootloader_file,$content);
  &apply_bootloader();
 }
}

###############################################
#            Set CEA DMT function             #
###############################################
sub set_cea_dmt(@) {
 my $group_mode=$ARGV[1];
 &set_refresh($group_mode);
 &reboot();
}

###############################################
#            Set Refresh function             #
###############################################
sub set_refresh(@) {
 my ($group,$mode)=split(" ",$ARGV[1]);
 my $group_n="1";
 $group_n="2" if($group eq "DMT");
 # validation
 if($group =~/^CEA$|^DMT$/) {
  my $content=&read_from_file($bootloader_file);
  $content=~s/\nhdmi_group=.*/\nhdmi_group=$group_n/g;
  $content=~s/\nhdmi_mode=.*/\nhdmi_mode=$mode/g;
  &write_file("$bootloader_file.tmp",$bootloader_file,$content);
  &apply_bootloader(1);
 }
}

###############################################
#           Set Hostname  function           #
###############################################
sub set_hostname(@) {
 $host_name=$ARGV[1];
 # validation
 if($host_name ne "") {
  open(CMD_HOSTNAME,"|$pkg --set_hostname");
  print CMD_HOSTNAME $host_name;
  close(CMD_HOSTNAME);
 }
}

###############################################
#          Set Output Range Function          #
###############################################
sub set_output_range(@) {
 $o_range=$ARGV[1];
 # validation
 if($o_range =~/^0$|^1$|^2$|^3$|^4$/) {
  my $content=&read_from_file($bootloader_file);
  $content=~s/\nhdmi_pixel_encoding=.*/\nhdmi_pixel_encoding=$o_range/g;
  &write_file("$bootloader_file.tmp",$bootloader_file,$content);
  &apply_bootloader();
 }
}

###############################################
#          Set Output Range Function          #
###############################################
sub set_scaling_governor(@) {
 %found_scal=();
 $scal=$ARGV[1];
 $all_scal=&read_from_file("$scaling_available_file");
 chomp($all_scal);
 @el_scal=split(" ",$all_scal);
 for(@el_scal) {
  $found_scal{$_}=1;
 }
 # validation
 if($found_scal{$scal}) {
  ($scaling_file_perl=$scaling_file)=~s/\//\//g;
  my $content=&read_from_file($rcPGenerator_default_file);
  $content=~s/.*SCALING_GOVERNOR.*/SCALING_GOVERNOR=\"$scal\"/;
  $content="SCALING_GOVERNOR=\"$scal\"" if($content !~/.*SCALING_GOVERNOR.*/);
  &write_file("$rcPGenerator_default_file.tmp",$rcPGenerator_default_file,$content);
  &write_file($scaling_file,$scaling_file,$scal);
 }
}

###############################################
#            Set Net To Use Function          #
###############################################
sub set_net_to_use(@) {
 my $net_start=$ARGV[1];
 my $net_subclass=$ARGV[2];
 my $net_to_use=$ARGV[3];
 my @subclass=split(",",$net_subclass);
 # change pand default file
 open(DEFAULT_PAND_FILE,">$pand_default_file");
 print DEFAULT_PAND_FILE "PAND_NET=\"$net_start.$net_to_use.$subclass[1]\"";
 close(DEFAULT_PAND_FILE);
 # change rcPGenerator config file
 my $content=&read_from_file($rcPGenerator_default_file);
 $content=~s/.*AP_NET=.*/AP_NET=\"$net_start.$net_to_use.$subclass[0]\"/;
 $content=~s/.*PAND_NET=.*/PAND_NET=\"$net_start.$net_to_use.$subclass[1]\"/;
 $content=~s/.*USB_NET=.*/USB_NET=\"$net_start.$net_to_use.$subclass[2]\"/;
 $content=~s/.*DIRECT_NET=.*/DIRECT_NET=\"$net_start.$net_to_use.$subclass[3]\"/ if($subclass[3] ne "");
 &write_file("$rcPGenerator_default_file.tmp",$rcPGenerator_default_file,$content);
 # reboot
 &reboot();
}

###############################################
#       Open iptables For LS Function         #
###############################################
sub open_iptables_for_ls(@) {
 my $ip_ls=$ARGV[1];
 my $port_ls=$ARGV[2];
 my ($found,$ip_is_not_local) = (0,0);
 # validation: both go into shell commands run as root, and come from a
 # LightSpace discovery packet (discovery.pm).
 return "" if($ip_ls eq "" || $port_ls eq "");
 return "" if($ip_ls!~/\A\d{1,3}(?:\.\d{1,3}){3}\z/ || grep { $_>255 } split(/\./,$ip_ls));
 return "" if($port_ls!~/\A\d{1,5}\z/ || $port_ls<1 || $port_ls>65535);
 open(IP,"$ip route get $ip_ls|");
 while(<IP>) {
  if(/ via /) {
   $ip_is_not_local=1;
   last;
  }
 }
 close(IP);
 return "" if($ip_is_not_local);
 system("$iptables -C OUTPUT -p tcp -d $ip_ls --dport $port_ls -j ACCEPT 2>/dev/null");
 return if(!$?);
 system("$iptables -I OUTPUT -p tcp -d $ip_ls/32 --dport $port_ls -j ACCEPT");
}

###############################################
#       Set PGenerator Conf Function          #
###############################################
# Apply one key=value to the conf text (lines without trailing newline).
# dv_metadata and dv_map_mode are written as a pair.
sub pgenerator_conf_set_pair (@) {
 my ($content,$var_to_set,$value)=@_;
 my $paired_var = "";
 my $paired_value = "";
 return $content if($var_to_set =~/^(ip_pattern|^port_pattern)$/ || $var_to_set !~/^\w+$/);
 # One line per key: a line break in a value would add keys of its own.
 return $content if(defined $value && $value =~/[\x00-\x1f\x7f]/);
 if($var_to_set eq "dv_metadata") {
  $paired_var = "dv_map_mode";
  $paired_value = "0" if($value eq "2");
  $paired_value = "1" if($value eq "3");
  $paired_value = "2" if($value eq "4");
 } elsif($var_to_set eq "dv_map_mode") {
  $paired_var = "dv_metadata";
  $paired_value = "3" if($value eq "1");
  $paired_value = "4" if($value eq "2");
  # Deleting the map mode leaves dv_metadata as it is.
  $paired_value = "2" if($paired_value eq "" && ($value // "") ne "");
 }
 # dv_metadata=0 (Dolby Vision off) has no map mode: keep the stored
 # dv_map_mode for the next DV session instead of deleting it.
 $paired_var = "" if($paired_value eq "");
 my $out = "";
 for(split(/\n/,$content)) {
  next if(/^$var_to_set=/);
  next if($paired_var ne "" && /^$paired_var=/);
  $out.="$_\n";
 }
 chomp($out);
 $out.="\n$var_to_set=$value" if($value ne "");
 $out.="\n$paired_var=$paired_value" if($paired_var ne "" && $paired_value ne "");
 return $out;
}

sub pgenerator_conf_value_ok (@) {
 my $value = shift;
 return (defined $value && $value !~/[\x00-\x1f\x7f]/) ? 1 : 0;
}

# The conf text, or undef when the file exists but cannot be read: writing
# from an empty text then would drop every other key.
sub read_pgenerator_conf_text (@) {
 my $content = "";
 if(!open(CONF,"<",$pattern_conf)) {
  return undef if(-e $pattern_conf);
  return "";
 }
 while(<CONF>) { $content.=$_; }
 close(CONF);
 chomp($content);
 return $content;
}

# Read, change and write PGenerator.conf as one step. Every writer is its
# own sudo process (daemon, WebUI workers, Calman, TV remote): without the
# lock two of them read the same file and the later write drops the
# other's key. The per-process temp file keeps one writer from renaming
# another's half-written file into place.
# Returns 1 once the new text is on disk and reads back the same; the
# callers answer OK only then, so the daemon never takes a lost write for
# the applied settings. A text that does not read back is replaced by the
# old one again, but only under the lock: without it the text may be
# another writer's confirmed one. Only when the restore fails or cannot be
# made does a 0 leave the unverified text behind; the WebUI reads the file
# back for that case.
sub pgenerator_conf_update (@) {
 my $change = shift;
 my $lock;
 my $locked = 0;
 if(open($lock,">>","$pattern_conf.lock")) {
  $locked = flock($lock,LOCK_EX) ? 1 : 0;
 } else {
  undef $lock;
 }
 my $ok = 0;
 my $existed = -e $pattern_conf;
 my $before = &read_pgenerator_conf_text();
 if(defined $before) {
  my $content = $change->($before);
  if(&write_file("$pattern_conf.tmp.$$","$pattern_conf","$content\n")) {
   my $after = &read_pgenerator_conf_text();
   $ok = (defined $after && $after eq $content) ? 1 : 0;
   if(!$ok && $locked && !$existed) {
    unlink($pattern_conf);
   } elsif(!$ok && $locked && !&write_file("$pattern_conf.tmp.$$","$pattern_conf",($before eq "") ? "" : "$before\n")) {
    unlink("$pattern_conf.tmp.$$");
   }
  } else {
   unlink("$pattern_conf.tmp.$$");
  }
 }
 close($lock) if($lock);
 return $ok;
}

sub set_pgenerator_conf (@) {
 return print $error_response if($ARGV[1] =~/^(ip_pattern|^port_pattern)$/);
 return print $error_response if($ARGV[1] !~/^\w+$/ || !&pgenerator_conf_value_ok($ARGV[2] // ""));
 return print $error_response if(!&pgenerator_conf_update(sub { return &pgenerator_conf_set_pair($_[0],$ARGV[1],$ARGV[2] // ""); }));
 print $ok_response;
}

# SET_PGENERATOR_CONF_MULTI key1 value1 key2 value2 ...: one read and one
# atomic write for a whole WebUI apply instead of a sudo spawn per key.
sub set_pgenerator_conf_multi (@) {
 for(my $i=1; $i+1 <= $#ARGV; $i+=2) {
  return print $error_response if($ARGV[$i] !~/^\w+$/ || !&pgenerator_conf_value_ok($ARGV[$i+1]));
 }
 return print $error_response if(!&pgenerator_conf_update(sub {
  my $content = shift;
  for(my $i=1; $i+1 <= $#ARGV; $i+=2) {
   $content = &pgenerator_conf_set_pair($content,$ARGV[$i],$ARGV[$i+1]);
  }
  return $content;
 }));
 print $ok_response;
}

###############################################
#             Set Plugin Function             #
###############################################
sub set_plugin (@) {
 my $f_tmp_name = $ARGV[1];
 my $f_name = $ARGV[2];
 my $f_where = $ARGV[3];
 my $script = $ARGV[4];
 my $ctx = Digest::MD5->new;
 open(PLUGIN,"<:raw",$f_tmp_name);
 $ctx->addfile(*PLUGIN);
 close(PLUGIN);
 my $digest = $ctx->hexdigest;
 return print $error_response if(!$plugin_permitted{$digest});
 return print $error_response if($f_name !~/$plugin_archive_file/);
 system("$tar zxf $f_tmp_name -C $upload_tmp_dir 2>/dev/null");
 return print $error_response if($? != 0);
 chdir("$plugin_dir") || return print $error_response;
 open(CONF,"$plugin_conf_file");
 while(<CONF>) {
  chomp($_);
  $_=~s/\r//g;
  $do_reboot=1        if(/^reboot=yes/);
  $do_bootloader=1    if(/^bootloader=yes/);
  $plugin_name=$1 if(/^name=(.*)/);
 }
 close(CONF);
 if(-f "$script") {
  system("./$script &>/dev/null");
  return print $error_response if($? != 0);
 }
 chdir($shared_dir);
 rmtree($plugin_dir) || return print $error_response;
 rename($f_tmp_name,&get_destination($f_where)."/$plugin_name") if($script eq "install.sh");
 unlink("$f_tmp_name")                                          if($script eq "uninstall.sh");
 &apply_bootloader(1)  if($do_bootloader);
 &reboot()             if($do_reboot);
 print $ok_response;
}

###############################################
#             Pkg Update Function             #
###############################################
sub bash_cmd(@) {
 my $cmd = $ARGV[1];
 my $argument = $ARGV[2];
 my $ris_cmd = "";
 if($cmd eq "PKG_UPDATE") {
  if (`$pkg --check_for_update=all --no_restart 2>/dev/stderr` =~/need to be updated/) {
   system("$setsid $pkg --check_for_update=all --update -force_answer=n --skip_installed_from_check 1>/dev/stderr");
   print STDERR "The device will reboot, press enter to continue...";
   <STDIN>;
   print "REBOOT";
   &reboot();
  } else {
   print STDERR "No packages to update\n\n";
  }
 }
 if($cmd eq "PGPLUS_CHECK") {
  my $fresh=(defined($argument) && $argument eq "fresh") ? " --fresh" : "";
  my $out=`/usr/sbin/pgenerator-update check$fresh 2>/dev/null`;
  chomp($out);
  print $out;
 }
 if($cmd eq "PGPLUS_LIST") {
  my $out=`/usr/sbin/pgenerator-update list 2>/dev/null`;
  chomp($out);
  print $out;
 }
 if($cmd eq "PGPLUS_APPLY") {
  # Optional release version (older release or reinstall); validated again
  # by pgenerator-update.
  my $version=(defined($argument) && $argument=~/^\d+(?:\.\d+)+$/) ? $argument : "";
  my $out=`/usr/sbin/pgenerator-update apply $version 2>/dev/null`;
  chomp($out);
  print $out;
 }
 if($cmd eq "SAVE_METER_SETTINGS") {
  my $path="/usr/share/PGenerator/meter_settings.json";
  my $tmp="$path.tmp";
  if(open(my $fh,">",$tmp)) {
   print $fh $argument;
   close($fh);
   chmod 0644, $tmp;
   if(rename($tmp,$path)) {
    system("timeout 3 $sync >/dev/null 2>&1");
    print "OK";
   } else {
    unlink($tmp) if(-f $tmp);
    print "ERR";
   }
  } else {
   unlink($tmp) if(-f $tmp);
   print "ERR";
  }
 }
 system("$passwd $argument 1>/dev/stderr")                             if($cmd eq "CHANGE_PASSWORD");
 system("$perl -p -i -e \"s/$distro_name.*/$argument/\" $distro_conf") if($cmd eq "PKG_SUBSCRIBE");
}

###############################################
#             Root Video Functions            #
###############################################
# Members of a verified live POSIX session are owned even before exec().
# If its leader has ended, inherited exec-time tagging identifies orphans;
# a recycled session/PID without that tag is never selected.
sub root_video_session_members (@) {
 my $session=shift;my $cache=shift;my $legacy=$session =~ /^[1-9]\d*\z/;
 my($leader)=$session =~ /^([1-9]\d*)(?::\d+)?\z/;
 return undef if(!defined($leader));
 my($leader_id,$leader_state)=&video_process_identity($leader);
 return undef if($leader_state eq "unknown");
 my $anchored=!$legacy && $leader_state eq "alive" && $leader_id eq $session;
 # A legacy record has no birth identity. A live PID anchors it only when it
 # is the old repeat helper itself ($0 "PGenerator_cmd.pl PLAY_VIDEO", comm
 # cut to 15 bytes); any other live process owns that SID now: nothing of it
 # is ours. With the PID gone, only player programs are eligible.
 # The caller's passes share one verdict: a helper that ends after TERM in
 # pass 0 keeps its just-forked timeout/helper children eligible.
 my $legacy_leader=0;
 if($legacy && ref($cache) eq "HASH" && defined($cache->{legacy_leader})) {
  return [] if($cache->{legacy_leader}<0);
  $legacy_leader=$cache->{legacy_leader};
 } elsif($legacy && $leader_state eq "alive") {
  my($comm,$cmdline)=("","");
  if(open(my $fh,"<","/proc/$leader/comm")) { $comm=<$fh> // "";close($fh); }
  if(open(my $fh,"<","/proc/$leader/cmdline")) { local $/;$cmdline=<$fh> // "";close($fh); }
  chomp($comm);$cmdline=~s/\0/ /g;
  if($comm eq "" || ($comm eq "PGenerator_cmd." && $cmdline eq "")) {
   # Unreadable, or the old helper exiting (cmdline is empty after
   # exit_mm): no verdict. Gone by now: players only, decided again next
   # pass; else not yet. Any other readable name (a kernel thread has an
   # empty cmdline too) is not ours.
   my(undef,$now)=&video_process_identity($leader);
   return undef if($now ne "gone");
  } else {
   my $ours=$comm eq "PGenerator_cmd." && $cmdline =~ /^\S*PGenerator_cmd\.pl PLAY_VIDEO\b/;
   $cache->{legacy_leader}=$ours ? 1 : -1 if(ref($cache) eq "HASH");
   return [] if(!$ours);
   $legacy_leader=1;
  }
 } elsif($legacy && ref($cache) eq "HASH") {
  $cache->{legacy_leader}=0;
 }
 # Never this helper or its callers (the daemon's sudo chain shares a session).
 my %self;
 for(my($p,$n)=($$,0);$p>1 && $n<64;$n++) {
  $self{$p}=1;
  open(my $fh,"<","/proc/$p/stat") or last;my $st=<$fh>;close($fh);
  ($p)=defined($st) ? $st=~/\) \S+ (\d+)/ : (0);$p//=0;
 }
 opendir(my $proc,"/proc") or return undef;
 my @pid=grep {/^[1-9]\d*\z/}readdir($proc);closedir($proc);
 my @owned;
 for my $pid (@pid) {
  my $fh;
  if(!open($fh,"<","/proc/$pid/stat")) {
   my $error=0+$!;require Errno;
   next if($error==Errno::ENOENT() || $error==Errno::ESRCH());
   return undef;
  }
  my $line;{local $/;$line=<$fh>;}my $closed=close($fh);
  if(!$closed || !defined($line) || $line eq "") {
   my(undef,$state)=&video_process_identity($pid);
   next if($state eq "gone");
   return undef;
  }
  my($comm,$tail)=$line=~/^\Q$pid\E \((.*)\) (.*)$/s;
  return undef if(!defined($tail));
  my @field=split(/\s+/,$tail);
  return undef if(@field<20 || $field[3]!~/^\d+\z/ || $field[19]!~/^\d+\z/);
  next if($field[3]!=$leader || $field[0]=~/^[ZXx]\z/ || $self{$pid});
  my $identity="$pid:$field[19]";
  # Legacy members: known player comm values in SID=recorded PID; the old
  # helper and its timeout wrappers only below the verified old helper
  # (fb_player was the old framebuffer path).
  next if($legacy && $comm !~ /^(?:pg_diag_video_p|ffmpeg|ffprobe|drm_player|fb_player|pg_v4l2_player|omxplayer(?:\.bin)?)\z/ &&
   !($legacy_leader && $comm =~ /^(?:PGenerator_cmd\.|timeout)\z/));
  next if(!$legacy && $pid==$leader && !$anchored);
  if(!$legacy && !$anchored) {
   if(!open($fh,"<","/proc/$pid/environ")) {
    my $error=0+$!;require Errno;
    next if($error==Errno::ENOENT() || $error==Errno::ESRCH());
    return undef;
   }
   my $env;{local $/;$env=<$fh>;}my $ok=close($fh);
   if(!$ok || !defined($env)) {
    my(undef,$state)=&video_process_identity($pid);
    next if($state eq "gone");
    return undef;
   }
   next if($env!~/(?:^|\0)PGEN_VIDEO_SESSION=\Q$session\E(?:\0|\z)/);
  }
  my($current,$state)=&video_process_identity($pid);
  return undef if($state eq "unknown");
  push(@owned,[$pid,$identity]) if($state eq "alive" && $current eq $identity);
 }
 return \@owned;
}

# The record lives in a directory only root can write (below /run): no other
# user can plant, swap, link or block it. Written via temp file + rename, so
# a reader sees the old or the new record. Returns 1 when written.
sub root_video_record_write (@) {
 my $content=shift;
 my($dir)=$root_video_pid_file =~ m{^(.+)/[^/]+\z};
 return 0 if(!defined($dir));
 # Modes are set explicitly: the daemon user must read both whatever
 # umask root runs with (sudo, init).
 chmod(0755,$dir) if(!-e $dir && !-l $dir && mkdir($dir,0755));
 my @st=lstat($dir);
 return 0 if(!@st || !-d _ || ($st[4]!=0 && $st[4]!=$>) || ($st[2] & 022));
 my $tmp="$root_video_pid_file.$$";
 unlink($tmp) if(-e $tmp || -l $tmp);
 open(my $pf,">",$tmp) or return 0;
 my $ok=print $pf $content;
 $ok=0 if(!close($pf));
 $ok=0 if($ok && !chmod(0644,$tmp));
 $ok=0 if($ok && !rename($tmp,$root_video_pid_file));
 unlink($tmp) if(!$ok);
 return $ok ? 1 : 0;
}

sub stop_video_root_process (@) {
 my($program,$expected,$direct,$again,$only_ended)=@_;my $session="";
 # Asked to stop only an ended session: a read failing before any verdict is
 # "unknown" (no verdict), not a failed cleanup of an ended one.
 my $unread=$only_ended ? "unknown" : 0;
 # Every successful non-direct return goes through $done: a hard link at
 # the old path to a record this request removed has one link afterwards
 # and counts as an old record, so take it over in this same request
 # (once); the daemon then finds no record after a clean stop.
 my $done=sub {
  return 1 if($direct || $again || -e $root_video_pid_file || -l $root_video_pid_file || !defined($legacy_video_pid_file));
  my @st=lstat($legacy_video_pid_file);
  return (@st && -f _ && $st[3]==1 && ($st[4]==0 || $st[4]==$>)) ? &stop_video_root_process($program,undef,0,1) : 1;
 };
 if($direct) {
  # The freshly acknowledged child is trusted independently of a failed,
  # empty or partial record write. Never re-read that file as its identity.
  $session=$expected // "";
 } else {
  # A record of versions up to 2.13.51 (bare PID in world-writable /tmp;
  # a pid:start there is anchored like a current record) is theirs only as
  # a plain file of root's with one link (in sticky /tmp no other user can
  # swap it); read without following links
  # or blocking, checked to be the file just looked at, and taken over into
  # the root-only record by the next STOP_VIDEO (daemon start, poll, Stop,
  # pattern) or PLAY_VIDEO. Anything else there is no record of ours.
  if(!-e $root_video_pid_file && !-l $root_video_pid_file && defined($legacy_video_pid_file)) {
   my @st=lstat($legacy_video_pid_file);
   if(@st && -f _ && $st[3]==1 && ($st[4]==0 || $st[4]==$>)) {
    require Fcntl;my $old;
    if(sysopen(my $lf,$legacy_video_pid_file,Fcntl::O_RDONLY()|Fcntl::O_NOFOLLOW()|Fcntl::O_NONBLOCK())) {
     my @fs=stat($lf);
     if(@fs && $fs[0]==$st[0] && $fs[1]==$st[1]) { local $/;$old=<$lf>;$old="" if(!defined($old)); }
     close($lf);
    }
    return $unread if(!defined($old));
    $old=~s/\n\z//;
    return $unread if($old =~ /^[1-9]\d*(?::\d+)?\z/ && !&root_video_record_write($old));
    unlink($legacy_video_pid_file) or return $unread;
   }
  }
  return $done->() if(!-e $root_video_pid_file && !-l $root_video_pid_file);
  # Only root writes in the record's directory; still read only a plain file.
  my @st=lstat($root_video_pid_file);
  return $unread if(!@st);
  return unlink($root_video_pid_file) ? $done->() : 0 if(!-f _);
  open(my $fh,"<",$root_video_pid_file) or return $unread;
  {local $/;$session=<$fh>;}my $closed=close($fh);
  return $unread if(!$closed);$session="" if(!defined($session));
  $session=~s/\n\z//;
 }
 return 0 if($direct && $session !~ /^[1-9]\d*:\d+\z/);
 my $legacy=$session =~ /^[1-9]\d*\z/;
 if(!$legacy && $session !~ /^[1-9]\d*:\d+\z/) {
  return $done->() if(!-e $root_video_pid_file);
  return unlink($root_video_pid_file) ? $done->() : 0;
 }
 return 0 if(!$direct && !$legacy && defined($expected) && $expected ne "" && $session ne $expected);
 my($leader)=$session =~ /^([1-9]\d*)/;
 my($identity,$state)=$legacy ? ("","gone") : &video_process_identity($leader);
 my $frozen=$state eq "alive" && $identity eq $session;
 # A stale or reused leader cannot anchor ownership or signals: the sweep
 # below then selects only processes carrying this session's exec-time tag
 # (orphans of an ended session), and the record goes only once none is left.
 # Asked to stop only an ended session (stop_video_root "ended"), say which:
 # no verdict ("unknown") or a playing video ("live": a leader alive with
 # this record's identity); nothing signalled, record kept.
 return $unread if(!$legacy && !$frozen && $state eq "unknown");
 return "live" if($only_ended && $frozen);
 # Freeze repeat/fork activity while collecting all timeout groups in this
 # session. The separate CHECK_VIDEO_SOURCE session is never name-matched.
 kill("STOP",$leader) if($frozen);
 my %term;my $ok=0;my $quiet=0;my %legacy_verdict;
 for my $pass (0..24) {
  my $members=&root_video_session_members($session,\%legacy_verdict);last if(!defined($members));
  # A legacy leader (old repeat loop) is stopped with its children.
  my @children=grep {$legacy || $_->[0]!=$leader}@$members;
  # A child can appear after the previous /proc directory snapshot while
  # its parent exits. Require two quiet snapshots with the leader frozen.
  if(!@children){if(++$quiet>=2){$ok=1;last;}usleep(50000);next;}
  $quiet=0;
  for my $member (@children) {
   my($current,$alive)=&video_process_identity($member->[0]);
   next if($alive ne "alive" || $current ne $member->[1]);
   kill($pass>=20 ? "KILL" : "TERM",$member->[0]) if($pass>=20 || !$term{$current}++);
  }
  usleep(50000);
 }
 if($ok && $frozen) {
  my($current,$alive)=&video_process_identity($leader);
  kill("KILL",$leader) if($alive eq "alive" && $current eq $session);
 }
 if(!$ok) {
  my($current,$alive)=&video_process_identity($leader);
  kill("CONT",$leader) if($frozen && $alive eq "alive" && $current eq $session);
  return 0;
 }
 # Remove only our still-current record; a caller holding the renderer lock
 # serializes normal play/stop requests. Expected identity guards stale work.
 if(-e $root_video_pid_file) {
  open(my $fh,"<",$root_video_pid_file) or return 0;
  my $current=<$fh>;my $closed=close($fh);chomp($current) if(defined($current));
  return 0 if(!$closed);
  $current="" if(!defined($current));
  unlink($root_video_pid_file) or return 0 if($current eq $session ||
   ($direct && $current !~ /^[1-9]\d*:\d+\z/));
 }
 return $done->();
}

sub root_video_error_message (@) {
 my $log_file="/tmp/omxplayer.log";
 my $log_content="";
 return "Video playback failed to start" if(!-f $log_file);
 $log_content=&read_from_file($log_file);
 return "Video playback backend unavailable on this image (OpenMAX init failed)" if($log_content =~ /OMXCore failed to init|OMX\.broadcom\.clock/i);
 return $1 if($log_content =~ /([^\r\n]+)\s*$/ && $1 !~ /^have a nice day/i);
 return "Video playback failed to start";
}

# GNU timeout returns 124 on a normal duration expiry. Every other
# diagnostic-player completion (stop, signal, fatal error) is final: never
# turn a failed decode into an endless modeset/restore loop.
sub root_video_should_repeat (@) {
 my ($program,$status,$repeat)=@_;
 return 0 if(!$repeat || ($status & 127) || (($status >> 8) == 143));
 return (($status >> 8) == 124) ? 1 : 0 if($program eq "pg_diag_video_player");
 return 1;
}

# Read-only metadata admission while the renderer still owns DRM. The wrapper
# repeats this check at launch, so replacing a file cannot bypass admission.
sub check_video_source_root (@) {
 local $ENV{PGEN_VIDEO_SESSION};delete $ENV{PGEN_VIDEO_SESSION};
 my $video=$ARGV[1];my $player="/usr/sbin/pg_diag_video_player";
 return print "ERR:Video request refused" if(!defined($video) || $video eq "" ||
  $video =~ /(^\/|\.\.|[\r\n\0])/ || $video !~ /^[A-Za-z0-9 _.\-\/()]+\z/);
 my $path="$video_dir/$video";
 return print "ERR:Diagnostic video source check unavailable" if(!-f $path || !-x $player);
 # "rate" as the next argument: the answer may name the clip's frame rate
 # (OK:24000/1001). Without it the answer is OK, as before.
 my $want_rate=(defined($ARGV[2]) && $ARGV[2] eq "rate") ? 1 : 0;
 my $pid=open(my $check,"-|",$timeout,"-k","2s","8s",$player,($want_rate ? "--check-source-rate" : "--check-source"),$path);
 return print "ERR:Diagnostic video source check failed" if(!defined($pid));
 my $response=<$check>;
 my $closed=close($check);
 chomp($response) if(defined($response));
 return print $response if($closed && defined($response) && ($response eq "OK" ||
  ($want_rate && $response =~ /^OK:[1-9]\d{0,6}\/[1-9]\d{0,6}\z/)));
 $response="ERR:Diagnostic video source check failed" if(!defined($response) || $response !~ /^ERR:.+/);
 $response =~ s/[\r\n]/ /g;
 print $response;
}

sub play_video_root (@) {
 my $program_name=basename($ARGV[1] || "");
 my $video=$ARGV[2];
 my $duration=$ARGV[3];
 my $repeat=$ARGV[4];
 my $program_path="/usr/bin/$program_name";
 my $log_file="/tmp/omxplayer.log";
 my $video_path="";
 my $pid=0;
 my $status="";
 my ($status_read,$status_write);
 return print "ERR:Video playback failed to start" if($program_name !~ /^(?:omxplayer(?:\.bin)?|pg_diag_video_player)$/);
 if($program_name eq "pg_diag_video_player") {
  $program_path="/usr/sbin/pg_diag_video_player";
 } else {
  $program_path="/usr/bin/omxplayer" if(-x "/usr/bin/omxplayer");
 }
 return print "ERR:Video playback failed to start" if(!-x $program_path);
 return print "ERR:Video playback failed to start" if(!defined $video || $video eq "");
 return print "ERR:Video playback failed to start" if($video =~ /(^\/|\.\.|[\r\n\0])/);
 return print "ERR:Video playback failed to start" if($video !~ /^[A-Za-z0-9 _\.\-\/()]+$/);
 return print "ERR:Video playback failed to start" if(!defined $duration || $duration !~ /^\d+[smhd]?$/);
 $repeat=0 if(!defined $repeat || $repeat ne "1");
 $video_path="$video_dir/$video";
 return print "ERR:Video playback failed to start" if(!-f $video_path);
 return print "ERR:Video playback failed to start" if(!pipe($status_read,$status_write));
 return print "ERR:Previous video cleanup failed" if(!&stop_video_root_process($program_name));
 unlink($log_file);
 $pid=fork();
 return print "ERR:Video playback failed to start" if(!defined $pid);
 if($pid == 0) {
  my $status_sent=0;
  my $finished=0;
  my($session,$session_state)=&video_process_identity($$);
  my $play_pid=0;
  my $wait_pid=0;
  close($status_read);
  my $sid=eval { setsid(); };
  $SIG{"TERM"}=sub { exit 0; };
  if(!defined($sid) || $sid<0 || $session_state ne "alive") {
   print $status_write "ERR:Video session identity unavailable\n";close($status_write);exit 1;
  }
  $ENV{PGEN_VIDEO_SESSION}=$session;
  open(STDIN,"</dev/null");
    open(STDOUT,">>$log_file");
    open(STDERR,">&STDOUT");
  while(1) {
   $play_pid=fork();
   if(!defined $play_pid) {
    print $status_write "ERR:Video playback failed to start\n" if(!$status_sent);
    close($status_write) if(!$status_sent);
    exit 1;
   }
   if($play_pid == 0) {
    if($program_name eq "pg_diag_video_player") {
     my $width=$ARGV[5] || "";
     my $height=$ARGV[6] || "";
     my $refresh=$ARGV[7] || "0";
     exit 2 if($refresh !~ /^(?:\d+(?:\.\d{1,6})?|\d+\/\d+)\z/);
     my $timing=$ARGV[8] || "-";
     exit 2 if($timing ne "-" && $timing !~ /^\d+(?::\d+){11}\z/);
     exec($timeout,"-k","$duration","$duration","$program_path","$video_path","$width","$height","0","$refresh","$timing");
    }
    exec($timeout,"-k","$duration","$duration","$program_path","$video_path");
    exit 127;
   }
   usleep(2500000);
   $wait_pid=waitpid($play_pid,WNOHANG);
   if($wait_pid == 0) {
    if(!$status_sent) {
     print $status_write ($program_name eq "pg_diag_video_player" ? "OK:$session\n" : "OK\n");
     close($status_write);
     $status_sent=1;
    }
    waitpid($play_pid,0);
   } else {
    if(!$status_sent) {
     print $status_write "ERR:".&root_video_error_message()."\n";
     close($status_write);
    }
    exit 1 if(!$status_sent);
   }
   $finished=$?;
   last if(!&root_video_should_repeat($program_name,$finished,$repeat));
  }
  close($status_write) if(!$status_sent);
  exit(($finished & 127) ? 128+($finished & 127) : ($finished >> 8));
 }
 close($status_write);
 my($record_id)=&video_process_identity($pid);
 my $recorded=($record_id =~ /^\Q$pid\E:\d+\z/) ? &root_video_record_write($record_id) : 0;

 eval {
  local $SIG{ALRM}=sub { die "status timeout\n"; };
  alarm(5);
  $status=<$status_read>;
  alarm(0);
 };
 alarm(0);
 close($status_read);
 chomp($status) if(defined $status);
 if(!defined $status || $status eq "" || $status !~ /^OK(?::[1-9]\d*:\d+)?$/) {
  &stop_video_root_process($program_name,$record_id,1) if($record_id =~ /^[1-9]\d*:\d+\z/);
  $status=~s/^ERR:// if(defined $status);
  $status="Video playback failed to start" if(!defined $status || $status eq "");
  return print "ERR:$status";
 }
 if(!$recorded) {
  # Never acknowledge an unrecorded live session: a daemon restart would
  # lose it. The child's acknowledgement supplies an identity even when
  # the parent's initial /proc read failed.
  my($ack_id)=$status =~ /^OK:([1-9]\d*:\d+)\z/;
  &stop_video_root_process($program_name,$ack_id || $record_id,1);
  return print "ERR:Video session record unavailable";
 }
 print $status;
}

sub stop_video_root (@) {
 # A fourth argument "ended" (the daemon's poll after it could not read the
 # session itself): stop it only if root sees it ended; a live session
 # answers LIVE and keeps playing, one root cannot read either answers
 # "state unknown" (apart from an ended one whose cleanup failed).
 my $only_ended=defined($ARGV[3]) && $ARGV[3] eq "ended";
 my $result=&stop_video_root_process($ARGV[1],$ARGV[2],0,0,$only_ended);
 print($result eq "live" ? "LIVE" : $result eq "unknown" ? "ERR:Video session state unknown" : $result ? "OK" : "ERR:Video session cleanup failed");
}

###############################################
#           Bluetooth PAN Functions           #
###############################################
sub bt_status (@) {
 my $hci="";
 my $adapter="";
 my $devices="";
 my $pan_ip="";
 $hci=&pgen_capture($hciconfig,$hci_interface) if(defined $hciconfig && &pgen_cmd_exists($hciconfig));
 if($hci eq "" && defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl)) {
  $hci=&pgen_capture($bluetoothctl,"show");
 }
 if(-x "/usr/bin/bluez-test-adapter") {
  $adapter=`/usr/bin/bluez-test-adapter list 2>/dev/null`;
 } elsif(defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl)) {
  $adapter=&pgen_capture($bluetoothctl,"show");
 }
 if(-x "/usr/bin/bluez-test-device") {
  $devices=`/usr/bin/bluez-test-device list 2>/dev/null`;
 } elsif(defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl)) {
  $devices=&pgen_capture($bluetoothctl,"devices");
 }
 if(defined $ifconfig && &pgen_cmd_exists($ifconfig)) {
  $pan_ip=&pgen_capture($ifconfig,"pan0");
  $pan_ip.=&pgen_capture($ifconfig,$bt_interface);
  $pan_ip.=&pgen_capture($ifconfig,"bnep0") if($bt_interface ne "bnep0");
 } elsif(defined $ip && &pgen_cmd_exists($ip)) {
  $pan_ip=&pgen_capture($ip,"addr","show","dev","pan0");
  $pan_ip.=&pgen_capture($ip,"addr","show","dev",$bt_interface);
  $pan_ip.=&pgen_capture($ip,"addr","show","dev","bnep0") if($bt_interface ne "bnep0");
 }
 my $pan_net="";
 if(-f $pand_default_file) {
  my $pf=&read_from_file($pand_default_file);
  ($pan_net)=$pf=~/PAND_NET="([^"]*)"/;
 }
 $pan_net="10.10.11" if($pan_net eq "");
 my $agent_running=`ps aux 2>/dev/null | grep pgenerator-bt-agent | grep -v grep`;
 chomp($agent_running);
 my $agent_status=($agent_running ne "")?"1":"0";
 my $nap_running=(`pgrep -f 'bt-network.*-s nap' 2>/dev/null` ne "")?"1":"0";
 my $pand_available=(-x "/etc/init.d/pand") ? 1 : 0;
 my $bt_network_available=(-x "/usr/bin/bt-network" || -x "/usr/sbin/bt-network") ? 1 : 0;
 my $bluez_modern=(defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl)) ? 1 : 0;
 print "HCI_BEGIN\n$hci\nHCI_END\n";
 print "ADAPTER_BEGIN\n$adapter\nADAPTER_END\n";
 print "DEVICES_BEGIN\n$devices\nDEVICES_END\n";
 print "PAN_BEGIN\n$pan_ip\nPAN_END\n";
 print "PAND_NET=$pan_net\n";
 print "PAND_AVAILABLE=$pand_available\n";
 print "BT_NETWORK_AVAILABLE=$bt_network_available\n";
 print "NAP_RUNNING=$nap_running\n";
 print "BLUETOOTHCTL_AVAILABLE=$bluez_modern\n";
 print "AGENT=$agent_status\n";
 my $bt_soft_blocked=0;
 if(defined $rfkill && &pgen_cmd_exists($rfkill)) {
  my $rf=&pgen_capture($rfkill,"list","bluetooth");
  $bt_soft_blocked=1 if($rf=~/soft\s+blocked:\s*yes/i);
 }
 print "SOFT_BLOCKED=$bt_soft_blocked\n";
}

sub bt_set_discoverable (@) {
 my $val=$ARGV[1];
 if($val eq "on" || $val eq "off") {
  if(-x "/usr/bin/bluez-test-adapter") {
   system("/usr/bin/bluez-test-adapter discoverable $val");
   print $ok_response;
  } elsif(defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl)) {
   &pgen_system_quiet($bluetoothctl,"discoverable",$val);
   &pgen_system_quiet($bluetoothctl,"pairable",$val);
   print $ok_response;
  } else {
   print "$error_response:bluetoothctl not found";
  }
 } else {
  print $error_response;
 }
}

# Stop the Bluetooth PAN/NAP side (bt-network nap or legacy pand). Does not
# print a response — callers print OK/ERR themselves.
sub bt_stop_pan (@) {
 if(-x "/etc/init.d/pand") {
  &pgen_system_quiet("/etc/init.d/pand","stop");
 }
 # Kill modern BlueZ NAP helper left running after the radio is powered down.
 system("pkill -f '[b]t-network.*-s nap' >/dev/null 2>&1");
 system("pkill -f '[b]t-network.*nap' >/dev/null 2>&1");
}

sub bt_set_powered (@) {
 my $val=$ARGV[1];
 if($val eq "on" || $val eq "off") {
  if($val eq "on") {
   &pgen_system_quiet($rfkill,"unblock","bluetooth") if(defined $rfkill && &pgen_cmd_exists($rfkill));
   &pgen_system_quiet($hciconfig,$hci_interface,"up") if(defined $hciconfig && &pgen_cmd_exists($hciconfig));
   if(-x "/usr/bin/bluez-test-adapter") {
    system("/usr/bin/bluez-test-adapter powered on");
   } elsif(defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl)) {
    &pgen_system_quiet($bluetoothctl,"power","on");
   }
   # Radio is back — restore PAN so the power toggle is a full on/off for the
   # Bluetooth PAN card (NAP was stopped on power-off). Quiet so the power
   # response stays a single OK; Restart PAN remains available if NAP fails.
   &bt_restart_pan(1);
  } else {
   # Tear down PAN before killing the radio so status doesn't stay "PAN
   # Running" while Power shows Off (orphaned bt-network / pan0 bridge).
   &bt_stop_pan();
   if(-x "/usr/bin/bluez-test-adapter") {
    system("/usr/bin/bluez-test-adapter powered off");
   } elsif(defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl)) {
    &pgen_system_quiet($bluetoothctl,"power","off");
   }
   &pgen_system_quiet($hciconfig,$hci_interface,"down") if(defined $hciconfig && &pgen_cmd_exists($hciconfig));
   &pgen_system_quiet($rfkill,"block","bluetooth") if(defined $rfkill && &pgen_cmd_exists($rfkill));
  }
  print $ok_response;
 } else {
  print $error_response;
 }
}

sub bt_set_name (@) {
 my $name=$ARGV[1];
 $name=~s/[^a-zA-Z0-9_ -]//g;
 if($name ne "") {
  &pgen_system_quiet($hciconfig,$hci_interface,"name",$name) if(defined $hciconfig && &pgen_cmd_exists($hciconfig));
  &pgen_system_quiet($bluetoothctl,"system-alias",$name) if(defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl));
  print $ok_response;
 } else {
  print $error_response;
 }
}

sub bt_set_pan_ip (@) {
 my $net=$ARGV[1];
 if($net=~/^\d{1,3}\.\d{1,3}\.\d{1,3}$/) {
  mkpath(dirname($pand_default_file)) if(!-d dirname($pand_default_file));
  open(DEFAULT_PAND_FILE,">$pand_default_file");
  print DEFAULT_PAND_FILE "PAND_NET=\"$net\"\n";
  close(DEFAULT_PAND_FILE);
  &bt_restart_pan();
 } else {
  print $error_response;
 }
}

# Restart Bluetooth PAN/NAP. Optional quiet flag (truthy) suppresses the OK/ERR
# line so nested callers (e.g. power-on) can own the response.
sub bt_restart_pan (@) {
 my ($quiet)=@_;
 $quiet=0 if(!defined $quiet);
 my $say=sub {
  my ($msg)=@_;
  print $msg if(!$quiet);
 };
 if(-x "/etc/init.d/pand") {
  &pgen_system_quiet("/etc/init.d/pand","restart");
  $say->($ok_response);
  return 1;
 }
 if(-x "/usr/bin/bt-network" || -x "/usr/sbin/bt-network") {
  my $bt_network=(-x "/usr/bin/bt-network") ? "/usr/bin/bt-network" : "/usr/sbin/bt-network";
  my $pan_net="10.10.11";
  if(-f $pand_default_file) {
   my $pf=&read_from_file($pand_default_file);
   ($pan_net)=$pf=~/PAND_NET="([^"]*)"/;
  }
  $pan_net="10.10.11" if($pan_net eq "");
  if(defined $ip && &pgen_cmd_exists($ip)) {
   &pgen_system_quiet($ip,"link","add","pan0","type","bridge");
   &pgen_system_quiet($ip,"addr","flush","dev","pan0");
   &pgen_system_quiet($ip,"addr","add","$pan_net.1/24","dev","pan0");
   &pgen_system_quiet($ip,"link","set","pan0","up");
  } elsif(defined $ifconfig && &pgen_cmd_exists($ifconfig)) {
   &pgen_system_quiet($ifconfig,"pan0","$pan_net.1","netmask","255.255.255.0","up");
  }
  if(defined $dnsmasq_bin && &pgen_cmd_exists($dnsmasq_bin)) {
   my $dir="/etc/dnsmasq.d";
   mkpath($dir) if(!-d $dir);
   if(open(my $fh,">","$dir/pgenerator-bt-pan.conf")) {
    print $fh "interface=pan0\nbind-dynamic\ndhcp-range=$pan_net.50,$pan_net.150,255.255.255.0,12h\ndhcp-option=3,$pan_net.1\ndhcp-option=6,$pan_net.1\n";
    close($fh);
   }
   &pgen_service_action("","dnsmasq","restart");
  }
  mkpath("/var/log/PGenerator") if(!-d "/var/log/PGenerator");
  system("pkill -f '[b]t-network.*-s nap' >/dev/null 2>&1");
  system("setsid $bt_network -d -s nap pan0 >/var/log/PGenerator/bt-network.log 2>&1 </dev/null &");
  sleep(1);
  if(`pgrep -f 'bt-network.*-s nap' 2>/dev/null` ne "") {
   $say->($ok_response);
   return 1;
  }
  $say->("$error_response:bt-network failed to start");
  return 0;
 }
 $say->("$error_response:Bluetooth PAN service not available");
 return 0;
}

sub bt_remove_device (@) {
 my $mac=$ARGV[1];
 if($mac=~/^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) {
  if(-x "/usr/bin/bluez-test-device") {
   system("/usr/bin/bluez-test-device remove $mac");
   print $ok_response;
  } elsif(defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl)) {
   &pgen_system_quiet($bluetoothctl,"remove",$mac);
   print $ok_response;
  } else {
   print "$error_response:bluetoothctl not found";
  }
 } else {
  print $error_response;
 }
}

sub bt_set_agent (@) {
 my $val=$ARGV[1];
 my $agent="/usr/bin/pgenerator-bt-agent";
 if($val eq "on") {
  return print "$error_response:pgenerator-bt-agent not found" if(!-x $agent);
  system("pkill -f '[p]generator-bt-agent' 2>/dev/null");
  sleep(1);
  system("setsid $agent </dev/null >/dev/null 2>&1 &");
  sleep(2);
  my $check=`ps aux 2>/dev/null | grep pgenerator-bt-agent | grep -v grep`;
  chomp($check);
  if($check ne "") {
   print $ok_response;
  } else {
   print $error_response;
  }
 } elsif($val eq "off") {
  system("pkill -f '[p]generator-bt-agent' 2>/dev/null");
  print $ok_response;
 } else {
  print $error_response;
 }
}
