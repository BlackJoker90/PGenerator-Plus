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

###############################################
#       Create Pattern File Function          #
###############################################
sub pattern_patch_request_log_path (@) {
 my $path=$calman_patch_log || "/var/log/PGenerator/calman-patches.log";
 my $dir=$path;
 $dir=~s|/[^/]+$||;
 $dir="/var/log/PGenerator" if($dir eq "");
 if($dir ne "" && ! -d $dir) {
  mkdir $dir;
 }
 return (-d $dir) ? "$dir/patch-requests.log" : "/tmp/patch-requests.log";
}

sub pattern_patch_log_clean (@) {
 my $value=shift;
 my $limit=int(shift || 0);
 $value="" if(!defined $value);
 $value=~s/[\r\n]+/|/g;
 $value=~s/[\t]/ /g;
 $value=~s/\s+/ /g;
 $value=~s/\s*\|\s*/|/g;
 $value=~s/^\s+|\s+$//g;
 $value=substr($value,0,$limit) if($limit > 0 && length($value) > $limit);
 return $value;
}

sub pattern_log_patch_request (@) {
 my %f=@_;
 my $path=&pattern_patch_request_log_path();
 my $ts=eval { require Time::HiRes; Time::HiRes::time(); };
 $ts=time() if(!$ts);
 my $local=scalar(localtime());
 my $range="source_range=".($f{source_range}//"");
 my @fields=(
  sprintf("%.6f",$ts),
  "local=".&pattern_patch_log_clean($local,80),
  "source=".&pattern_patch_log_clean($f{source},80),
  "handler=create_pattern_file",
  "raw=".&pattern_patch_log_clean($f{raw},80),
  "scaled=".&pattern_patch_log_clean($f{scaled},80),
  "input_max=".&pattern_patch_log_clean($f{input_max},40),
  "bits=".&pattern_patch_log_clean($f{bits},40),
  "range=".&pattern_patch_log_clean($range,120),
  "win=".&pattern_patch_log_clean($f{win},80),
  "size=",
  "bg=".&pattern_patch_log_clean($f{bg},80),
  "meta=".&pattern_patch_log_clean($f{meta},700),
  "pattern=".&pattern_patch_log_clean($f{pattern},1800)
 );
 if(open(my $fh,">>",$path)) {
  print $fh join("\t",@fields)."\n";
  close($fh);
 }
}

sub create_pattern_file (@) {
 my $draw=shift;
 my $dim=shift;
 my $resolution=shift;
 my $rgb=shift;
 my $bg=shift;
 my $position=shift;
 my $text=shift;
 my $return_str=shift;
 my $simple=shift;
 my $requested_by=(($requested_by=shift) eq "") ? $requested_by_default : $requested_by;
 my $source_range=shift;
 my $source_max=int(shift || 0);
 my $scaling_disabled=($requested_by eq "RGB") ? 1 : 0;
 my ($min_rgb,$max_rgb)=(0,255);
 my @el_rgb=split(",",$rgb);
 my $bits="";
 my $draw_type="";
 my $new_rgb="";
 my $pattern_string="";
 return if($#el_rgb != 2);
 # HCFR, DeviceControl Simple Template,reference flow
 if($simple) {
  ($draw_type,$bits)=$draw=~/([A-Z]+)(\d+)bit/;
  $draw=$draw_type             if($draw_type ne "");
  ($min_rgb,$max_rgb)=(0,1023) if($bits == 10);
 }
 $bits=$bits_default if($bits eq "");
 $max_rgb=(1 << $bits) - 1 if($bits > 8);
 $source_max=0 if($source_max != 255 && $source_max != 1023 && $source_max != 4095);
 $max_rgb=$source_max if($source_max > 0);
 for(@el_rgb) {
  return if($_ < $min_rgb || $_ > $max_rgb);
  $new_rgb.=int($_).",";
 }
 $bg=$bg_default if($bg eq "");
 # The renderer reads BG as three integers.
 return &error() if($bg!~/^-?\d+,-?\d+,-?\d+$/);
 $position=$position_default if($position eq "");
 $new_rgb=~s/,$//;
 $options="TEXT";
 $options="IMAGE" if($draw eq "IMAGE");
 $dim=&round_val((split(",",$dim))[0]*($w_s/$max_x)).",".&round_val((split(",",$dim))[1]*($h_s/$max_y)) if(!$scaling_disabled);
 # calculate and check the position
 $position=&get_position($dim,$draw,$position,$scaling_disabled);
 @num_sep=split(",",$position);
 for(@num_sep) { return &error() if(/[^0-9-]/); }
 $scaling_done=1 if(!$scaling_disabled);
 # create the pattern file
 $pattern_string.="PATTERN_NAME=$pname_file\n" if($pname_file ne "");
 $pattern_string.="MOVIE_NAME=TestPattern\nBITS=$bits\n" if($simple);
 $pattern_string.="SOURCE_MAX=$source_max\n" if($source_max > 0);
 $pattern_string.="DRAW=$draw\nDIM=$dim\nRESOLUTION=$resolution\nRGB=$new_rgb\nBG=$bg\nPOSITION=$position\n";
 $source_range=&pattern_default_source_range($source_range);
 $pattern_string.="SOURCE_RANGE=$source_range\n" if($source_range ne "");
 $pattern_string.="$options=$text\nEND=1\n";
 $pattern_string.="FRAME_NAME=TestPattern\nFRAME=$frame_default\n" if($simple);
 return $pattern_string if($return_str);
 &pattern_log_patch_request(source=>$requested_by,
                            raw=>$rgb,
                            scaled=>$new_rgb,
                            input_max=>$max_rgb,
                            bits=>$bits,
                            source_range=>$source_range,
                            win=>$dim,
                            bg=>$bg,
                            meta=>"draw=$draw;position=$position;simple=$simple;resolution=$resolution",
                            pattern=>$pattern_string);
 my $locked=&output_pattern_begin($requested_by);
 if(!&pattern_file_write($pattern_string)) { &output_pattern_end($locked);return 0; }
 &load_new_pattern_file("$requested_by");
 &output_pattern_end($locked);
 &stats("patterns",1);
}

# A name from a port 85 client (GETCONF, SETCONF, TESTTEMPLATE, SAVEIMAGES)
# is a file name in its directory: no "/", not "." or "..", no control
# characters (a newline ended the name early in a "$" match). These names
# went into two-argument opens ("x|" ran as a shell command) and into paths
# ("../" left the directory). The opens take three arguments now, so other
# characters (spaces, as the two-argument open allowed) stay usable.
# Returns 1 if it is one.
sub pattern_template_name_ok (@) {
 my $name=shift // "";
 return 1 if($name ne "" && $name ne "." && $name ne ".." && $name!~/[\/\x00-\x1f\x7f]/);
 &log("Pattern: name \"".(substr($name,0,60)=~s/[\x00-\x1f\x7f]/?/gr)."\" refused (not a file name)");
 return 0;
}

# Writes the renderer's pattern file ($command_file) through a temp file of
# this process and thread (the daemon thread and the WebUI workers write it
# at once), checking every step: a failed write (running/ is a 20 MB tmpfs)
# leaves the previous pattern, is logged and returns 0, and the caller must
# not reload the old file as if it were the new one. The result of the last
# write of this thread is kept in $pattern_write_failed (per thread, not
# shared): send_key_to_client answers Calman with NAK after a failed write.
sub pattern_file_write (@) {
 my ($str)=@_;
 my $tid=eval { threads->tid() } // 0;
 my $tmp="$command_file.$$.$tid.tmp";
 my $err="";
 if(open(my $fh,">",$tmp)) {
  $err="write: $!" if(!print $fh $str);
  $err="close: $!" if(!close($fh) && $err eq "");
  $err="rename: $!" if($err eq "" && !rename($tmp,$command_file));
 } else {
  $err="open: $!";
 }
 if($err ne "") {
  unlink($tmp);
  &log("Pattern: $command_file not written ($err); the previous pattern stays");
  $pattern_write_failed=1;
  return 0;
 }
 $pattern_write_failed=0;
 return 1;
}

###############################################
#          Functions Pattern Function         #
###############################################
sub execute_functions (@) {
 my $draw=shift;
 my $dim=shift;
 my $res=shift;
 my $functions=shift;
 # The name comes from a port 85 client and the file's lines are run as
 # Perl: only a plain name of a file in the daemon's directory (a two-
 # argument open ran "|cmd" as a shell command).
 # Returns "" or the reason it was refused.
 if($functions !~/^\w+\.server\z/) {
  &log("Pattern: FUNCTIONS name \"".substr($functions,0,60)."\" refused (not a plain name)");
  return "not a plain name";
 }
 open(my $fh,"<",$functions) or return "";
 while(<$fh>) {
  eval $_;
 }
 close($fh);
 return "";
}

###############################################
#           Output Request Generation         #
###############################################
# Each client request for the output (a pattern, a stop, a video) takes the
# next number. A video start runs its checks before renderer_lock; when a
# later request took a number meanwhile, the newer request wins (also when
# it is then refused: the start gives up and the output stays as it was).
# The number orders video starts only: a pattern still being rendered when
# a newer video has started ends that video once it is written, as any
# pattern ends a playing video.
sub output_request_claim () { lock($output_request_generation); return ++$output_request_generation; }
sub output_request_latest () { lock($output_request_generation); return $output_request_generation; }
# The daemon's own pattern loads do not count: restarts, the boot plate, the
# renderer's start pattern, the Range Check redrawn after a signal change
# (also from a forked apply worker, where a lock on the shared counter could
# wait forever), a video start's own steps. Code running such a
# step on behalf of the daemon sets "local $output_request_internal=1".
sub output_request_counts (@) {
 my $requested_by=shift // "";
 return 0 if(!defined(&output_request_claim) || $output_request_internal);
 return ($requested_by=~/^(?:play_video|pattern_generator_start|video failed|video ended|hdmi port change|hdmi hotplug|webui apply|Dolby Vision container|range check)\z/) ? 0 : 1;
}
# A client puts a pattern on the output: begin before writing the pattern
# file, end after loading it. Its number is taken first, so a video start
# still in its checks gives up. While a video starts or plays, or the
# renderer is down, the write waits for renderer_lock: a start's clean_files
# and placeholder would replace a file written meanwhile, and the renderer
# that load_new_pattern_file starts must draw this pattern. A start writes
# its mark before it checks for a newer number, so a client numbered after
# that check sees the mark here. Returns whether the lock is held.
sub output_pattern_begin (@) {
 my $requested_by=shift;
 return 0 if(!&output_request_counts($requested_by));
 &output_request_claim();
 return 0 if(!-e $root_video_pid_file && !-e $video_starting_file && &pattern_generator_is_running());
 &renderer_lock();
 return 1;
}
sub output_pattern_end (@) { &renderer_unlock() if(shift); }

###############################################
#            Pattern Video Function           #
###############################################
sub play_video(@) {
 my $program = shift;
 my $video = shift;
 my ($duration,$repeat) = split("-",shift);
 my $width = int(shift || 0);
 my $height = int(shift || 0);
 # Optional: the caller's step that can restart the renderer (the WebUI
 # range), run only for an accepted clip, before the session takes over.
 my $before_stop = shift;
 my $response="OK";
 $repeat=(defined($repeat) && $repeat eq "1") ? 1 : 0;
 # Player, file and duration come from a port 85 client. Only the players
 # the root helper starts (PGenerator_cmd.pl play_video_root), with its
 # rules for the file and the duration: any other program ran here through
 # a shell line, which started any program, an uploaded file included.
 if(($program // "")!~/^(?:[\w.\/-]*\/)?(?:omxplayer(?:\.bin)?|pg_diag_video_player)\z/
    || ($video // "") eq "" || $video=~/(^\/|\.\.|[\r\n\0])/ || $video!~/^[A-Za-z0-9 _.\-\/()]+\z/
    || ($duration // "")!~/^\d+[smhd]?\z/) {
  &log("Video: request refused (player, file or duration not accepted)");
  return "Video request refused";
 }
 # Its number, taken once the request is valid: a later request wins.
 my $generation = defined(&output_request_claim) ? &output_request_claim() : undef;
 my $superseded = sub { return defined($generation) && &output_request_latest()!=$generation; };
 # Capture the configured mode's refresh before stopping the renderer.
 # Exit resets colour properties and fbdev may restore a different timing.
 # Keep the configured size/refresh together, including a port-85 VIDEO call.
 my $video_refresh=0;my $video_timing="-";
 if($program =~ /(?:^|\/)pg_diag_video_player\z/ && ($width<=0 || $height<=0)) {
  ($width,$height)=(int($w_s || 0),int($h_s || 0));
 }
 if($program =~ /(?:^|\/)pg_diag_video_player\z/ && defined(&signal_mode_info)) {
  my $mode=&signal_mode_info($pgenerator_conf{"mode_idx"});
  my $hz=defined($mode->{video_refresh}) ? $mode->{video_refresh} : $mode->{refresh};
  $video_refresh=0+sprintf("%.6f",$hz) if(defined($hz) && $hz =~ /^\d+(?:\.\d+)?\z/);
  return "Configured video timing is unavailable" if(!defined($mode->{timing}));
  $video_timing=$mode->{timing};
 }
 # Reject unsupported source colour metadata before releasing the renderer.
 # Connector/timing checks require DRM master and run in the player later.
 if($program =~ /(?:^|\/)pg_diag_video_player\z/) {
  my $check=&sudo("CHECK_VIDEO_SOURCE",$video);
  chomp($check) if(defined($check));
  if(!defined($check) || $check ne "OK") {
   $check="Video source check failed" if(!defined($check) || $check eq "");
   $check=~s/^ERR://;
   $check="Video source check failed" if($check eq "OK");
   return $check;
  }
 }
 # A later pattern or stop request (answered while the checks ran) wins.
 if($superseded->()) { &log("Video: start superseded by a later pattern request");return "Video start superseded by a later pattern request"; }
 if(ref($before_stop) eq "CODE") { local $output_request_internal=1;$before_stop->(); }
 &renderer_lock();
 # The start mark, before the check: a client numbered after the check
 # sees it (output_pattern_begin, video_program_stop) and waits for the
 # lock; the main loop does not wait for the lock while it exists.
 if(open(my $starting,">",$video_starting_file)) { close($starting); }
 if($superseded->()) { unlink($video_starting_file);&renderer_unlock();&log("Video: start superseded by a later pattern request");return "Video start superseded by a later pattern request"; }
 if(!&video_program_stop()) { unlink($video_starting_file);&renderer_unlock();return "Previous video cleanup failed"; }
 &pattern_generator_stop();
 # Its clean_files removed every file in $var_dir, the mark too.
 if(open(my $starting,">",$video_starting_file)) { close($starting); }
 &create_pattern_file("$draw_default","$w_s,$h_s",$res_default,"$rgb_default","$bg_default","$position_default","","","","play_video");
 my @video_args=("PLAY_VIDEO",$program,$video,$duration,$repeat,$width,$height);
 push(@video_args,$video_refresh,$video_timing) if($program =~ /(?:^|\/)pg_diag_video_player\z/);
 $response=&sudo(@video_args);
 chomp($response) if(defined($response));
 if($program =~ /(?:^|\/)pg_diag_video_player\z/ && defined($response)) {
  if($response =~ /^OK:([1-9]\d*:\d+)\z/) {
   $response="OK";
  } elsif($response eq "OK") {
   $response="Video session identity is missing";
  }
 }
 if(!defined($response) || $response ne "OK") {
  # Stop any partially started child before the renderer takes DRM again.
  &video_program_stop();
  &load_new_pattern_file("video failed") if(!-e $root_video_pid_file);
  $response="Video playback failed to start" if(!defined($response) || $response eq "");
  $response=~s/^ERR://;
  $response="Video playback failed to start" if($response eq "OK");
 }
 unlink($video_starting_file);
 &renderer_unlock();
 return $response;
}

###############################################
#            Pattern Conversion               # 
###############################################
sub pc_to_video (@) {
 my $val = shift;
 $val=((219/255)*$val)+16;
 return &round_val($val);
}

###############################################
#              File Get List                 # 
###############################################
sub get_file_list (@) {
 my $dir = shift;
 my $str = "";
 opendir(DIR,"$dir");
 @dir=sort(readdir(DIR));
 closedir(DIR);
 for(@dir) {
  next if(! -f "$dir/$_");
  $str.="$_\n";
 }
 chomp($str);
 return $str;
}

###############################################
#             Pattern Get Image               #  
###############################################
sub get_pattern_image (@) {
 my $dir = shift;
 my $pattern = shift;
 my $img_content="";
 my $response="";
 my %frame = ();
 my $n_frames = 0;
 my $count = 0;
 open(FILE,"$pattern_frames/pattern.info");
 $pname_file=<FILE>;
 close(FILE);
 chomp($pname_file);
 return $none if($pname_file ne $pattern);
 opendir(DIR,"$dir");
 @dir=readdir(DIR);
 closedir(DIR);
 for(@dir) {
  @el=split("-",$_);
  $frame{$el[0]}=$_;
  $n_frames++ if (/\.png/);
 }
 # remove old preview frames
 foreach my $key (sort {$a <=> $b} keys %frame) {
  $_=$frame{$key};
  next if (!/\.png/);
  last if($count == ($n_frames-1));
  ($preview="preview-".$_)=~s/\.png$/.jpg/;
  $preview=~s/\%//g;
  unlink("$var_dir/running/$preview");
  $count++;
 }
 # convert last frame preview
 foreach my $key (sort {$b <=> $a} keys %frame) {
  $_=$frame{$key};
  next if (!/\.png/);
  ($preview="preview-".$_)=~s/\.png$/.jpg/;
  $preview=~s/\%//g;
  $size_str=$img_width."x".$img_height;
  # No shell: the frame name carries the template's FRAME_NAME.
  system($convert,"-resize",$size_str,"$pattern_frames/$_","$var_dir/running/$preview") if(!-f "$var_dir/running/$preview");
  return "<img src=http://\$ip_device:\$port_device/running/$preview-".time().">";
 }
 return $ok_response;
}

###############################################
#         Pattern Images Get List             # 
###############################################
sub get_patternimages_list (@) {
 my $pname = shift;
 my $str = "";
 my @arr=();
 my %img=();
 my $last="";
 my $index="";
 my $cnt=0;
 open(FILE,"$pattern_frames/pattern.info");
 $pname_file=<FILE>;
 close(FILE);
 chomp($pname_file);
 return "" if($pname ne $pname_file);
 opendir(DIR,"$pattern_frames/");
 @dir=readdir(DIR);
 closedir(DIR);
 for(@dir){
  next if($_ eq "." ||  $_ eq ".." || -d "$pattern_frames/$_");
  @el=split("-",$_);
  $index=$el[0];
  $pname=$duration=$el[1];
  $pname=~s/$split_images_string.*//;
  $duration=~s/.*$split_images_string//;
  $duration=~s/\.png//;
  $key=$index;
  next if($key eq "pattern.info");
  $key=$last="-1" if($_ =~/done$/);
  $index="Done" if($index eq "done");
  $pattern_info="$index";
  $pattern_info.=")" if($index ne "Done");
  $duration=($duration/1000000)."s" if($key ne "-1");
  $pattern_info.=" $pname $duration";
  $img{$key}=$pattern_info;
  $cnt++;
 }
 $str="Ready" if($cnt == 0 && $pname_file ne "");
 if($last ne "-1") {
  foreach $key (sort {$b<=>$a} keys %img) {
   $str.=$img{$key}."\n";
  }
 } else {
  foreach $key (sort {$a<=>$b} keys %img) {
   $str.=$img{$key}."\n";
  }
 }
 chomp($str);
 return $str;
}

###############################################
#           Pattern SaveImages                #
###############################################
sub save_images_pattern (@) {
 my $file = shift;
 my $images = shift;
 return 0 if(!&pattern_template_name_ok($file));
 open(FILE,">$pattern_frames/pattern.info");
 print FILE $file;
 close(FILE);
 open(FILE,">","$var_dir/running/$file.save");
 close(FILE);
 &create_return_file();
 return 1;
}

###############################################
#             Reload Pattern File             #
###############################################
sub load_new_pattern_file (@) {
 my $requested_by = shift;
 if($requested_by eq "play_video") {
  &create_return_file() if($requested_by ne $last_pattern_requested_by || $requested_by eq "");
  $last_pattern_requested_by=$requested_by;
  return;
 }
 # A client's pattern counts as a request for the output (writers that do
 # not use output_pattern_begin take their number here).
 &output_request_claim() if(&output_request_counts($requested_by));
 # Take renderer_lock only when a video record exists or the renderer is
 # down: a running renderer must keep drawing Calman patches while an apply
 # worker holds the lock across a restart's readiness waits. A video start
 # in progress counts as a record: its mark covers the window until the
 # renderer has stopped, a stopped renderer the rest.
 my $locked=0;
 if(-e $root_video_pid_file || -e $video_starting_file || !&pattern_generator_is_running()) {
  &renderer_lock();$locked=1;
  # A video that cannot be ended keeps the renderer stopped: the pattern
  # just written is not drawn, so the command that wrote it is answered as
  # a failed write (send_key_to_client: NAK to Calman).
  if(!&video_program_stop()) { $pattern_write_failed=1;$pattern_load_video_not_ended=1;&renderer_unlock();return 0; }
 }
 # Ensure the renderer is alive. pattern_generator_start can fail
 # transiently due to the documented DRM-master race (a helper
 # such as pgsethdr holds DRM master while the renderer calls
 # drmSetMaster, so the renderer exits immediately). Retry up to
 # three more times with increasing delays so the next pattern
 # request doesn't silently fail to appear on the TV. This covers
 # the reference GCI flow where a CONF_HDR / apply sequence followed
 # by a SPECIALTY pattern hits the race repeatedly. Each retry
 # also calls pattern_generator_stop first to clear any stale
 # DRM-master holder before re-starting. We also wait briefly
 # after each start before checking is_running, because the
 # background system() in pattern_generator_start returns before
 # the renderer process has fully initialized. The final retry
 # uses a 3s delay to let any lingering pgsethdr/drm_override
 # DRM-master holder fully release before the renderer tries to
 # acquire master.
 if(!&pattern_generator_is_running() && !&hdmi_sink_connected()) {
  # No display: the start is deferred (see hdmi_sink_connected) and the
  # retry ladder below would only burn ~10s per request. The daemon's main
  # loop starts the renderer once a display is plugged in.
  &pattern_generator_start(1);
 } elsif(!&pattern_generator_is_running()) {
  &pattern_generator_start(1);
  select(undef,undef,undef,0.6);
  if(!&pattern_generator_is_running()) {
   &log("load_new_pattern_file: renderer not running after first start, retrying (DRM master race)");
   select(undef,undef,undef,0.4);
   &pattern_generator_stop();
   &pattern_generator_start(1);
   select(undef,undef,undef,0.6);
  }
  if(!&pattern_generator_is_running()) {
   &log("load_new_pattern_file: renderer still not running after second start, final retry");
   select(undef,undef,undef,1.0);
   &pattern_generator_stop();
   &pattern_generator_start(1);
   select(undef,undef,undef,0.6);
  }
  if(!&pattern_generator_is_running()) {
   &log("load_new_pattern_file: renderer failed after 3 starts, waiting 3s for DRM master to settle");
   select(undef,undef,undef,3.0);
   &pattern_generator_stop();
   &pattern_generator_start(1);
   select(undef,undef,undef,0.8);
  }
  if(!&pattern_generator_is_running()) {
   &log("load_new_pattern_file: renderer failed to start after all retries — pattern will not appear on TV; a service restart will recover it");
  }
 }
 &create_return_file();
 $last_pattern_requested_by=$requested_by;
 &renderer_unlock() if($locked);return 1;
}


###############################################
#             Create Return File              #
###############################################
sub create_return_file (@) {
 my $rf="$var_dir/running/return";
 if(open(my $rfh,">",$rf)) {
  close($rfh);
 } else {
  &log("ERROR: cannot create return file $rf: $!");
 }
}

###############################################
#               Pattern Get                   #
###############################################
# YCbCr is always Limited on the wire: the renderer turns a Full range
# into Limited. A calibration client (Calman, LightSpace, Resolve) that set
# Full still sends full-range codes; SOURCE_RANGE=FULL makes the renderer
# compress them to studio range instead of putting code 0 below black.
sub pattern_default_source_range (@) {
 my $source_range=shift // "";
 return $source_range if($source_range ne "");
 return "FULL" if($external_rgb_quant_range_active &&
                  ($pgenerator_conf{"color_format"} || "0") =~/^[12]$/ &&
                  ($pgenerator_conf{"rgb_quant_range"} || "") eq "2");
 return "";
}

sub get_pattern (@) {
 my $type = shift;
 my $pattern = shift;
 my $rgb = shift;
 my $requested_by = shift;
 my $source_range = shift;
 my $source_max = int(shift || 0);
 $source_max=0 if($source_max != 255 && $source_max != 1023 && $source_max != 4095);
 my ($str,$bg,$dim,$draw_type,$pos,$res,$frame,$str_other,$image,$bits,$rules) = "";
 my %var=();
 my $pattern_dir = $pattern_templates;
 my $scaling_disabled=0;
 #
 # For HCFR or LS
 #
 if($rgb=~/;/) {
  my @el=split(";",$rgb);
  $rgb=$el[0];
  $bg=$el[1];
  $draw_type=$el[2];
  $dim=$el[3];
  $pos=$el[4];
  $res=$el[5];
  $frame=$el[6];
  $str_other=$el[7];
  $bits=$el[8] if($el[8] ne "");
  $scaling_disabled=1;
 }
 #
 # Read Pattern
 #
 $pattern_dir = "$var_dir/running/tmp" if($type eq "$test_template_ramdisk_command");
 return &error() if(!&pattern_template_name_ok($pattern));
 my $file_pattern="$pattern_dir/$pattern";
 return &error() if(!-f $file_pattern);
 open(my $pfh,"<",$file_pattern) or return &error();
 $first_row=<$pfh> // "";
 $first_row=<$pfh> // "" if($first_row =~/^PERMANENT=/);
 chomp($first_row);
 #
 # EVAL Pattern: disabled, as EVAL= lines below. Its rows ran as Perl in
 # the daemon, and a port 85 client can write any template (SETCONF
 # TEMPLATE). No template that ships uses it.
 #
 if($first_row eq "EVALPATTERN=") {
  close($pfh);
  &log("Pattern: template $pattern refused (EVALPATTERN is disabled)");
  return &error("$error_response:Refused: eval denied");
 }
 #
 # Classic Pattern
 #
 close($pfh);
 open($pfh,"<",$file_pattern) or return &error();
 while(<$pfh>) {
  $scaling_disabled=1 if(/^# SCALING=DISABLED/ || $scaling_done);
  next if($_=~/^(#|\n|\r)/);
  if($_=~/^VAR=(.*)=(.*)/) {
   $var{"$1"}=&replace_string($2,$rgb);
   next;
  }
  foreach $key (keys %var) {
   # The key is a regex, as it always was; one that does not compile (a
   # template's "VAR=(=x" from a port 85 client) died here and ended the
   # daemon with its WebUI threads.
   my $re=eval { qr/$key/ };
   if(!defined $re) {
    &log("Pattern: VAR \"".(substr($key,0,60)=~s/[\x00-\x1f\x7f]/?/gr)."\" ignored (not a valid pattern)");
    delete $var{$key};
    next;
   }
   $_=~s/$re/$var{$key}/g;
  }
  #
  # FRAME
  #
  if($_=~/^FRAME=DYNAMIC/) {
   $frame=$1             if($frame eq "" && /^FRAME=DYNAMIC\|\|(.*)/);
   $frame=$frame_default if($frame eq "");
   $str.="FRAME=$frame\n";
   next;
  }
  #
  # IMAGE
  #
  if($_=~/^IMAGE=DYNAMIC/) {
   $str_other=$1                if($str_other eq "" && /^IMAGE=DYNAMIC\|\|(.*)/);
   $_="IMAGE=$str_other\n";
  }
  if($_=~/^IMAGE=(.*)/) {
   $image=$1;
   $str.="IMAGE=$1\n";
   next;
  }
  #
  # TEXT
  #
  if($_=~/^TEXT=DYNAMIC/) {
   $str_other=$1            if($str_other eq "" && /^TEXT=DYNAMIC\|\|(.*)/);
   $str_other=$text_default if($str_other eq "");
   $_="TEXT=$str_other\n";
  } 
  if($_=~/^TEXT=(.*)/) {
   $str_other=&replace_string($1,$rgb);
   $str.="TEXT=$str_other\n";
   next;
  }
  #
  # DRAW
  #
  if($_=~/^DRAW=DYNAMIC/) {
   $draw_type=$1            if($draw_type eq "" && /^DRAW=DYNAMIC\|\|(.*)/);
   $draw_type=$draw_default if($draw_type eq "");
   $_="DRAW=$draw_type\n";
  } 
  if($_=~/^DRAW=(.*)/) {
   $draw_type=$1;
   return &error() if($draw_type !~/^RECTANGLE$|^CIRCLE$|^TRIANGLE$|^TEXT$|^IMAGE$/);
   $str.=$_;
   next;
  }
  #
  # DIM
  #
  if($_=~/^DIM=DYNAMIC/) {
   $dim=$1           if($dim eq "" && /^DIM=DYNAMIC\|\|(.*)/);
   $dim=$dim_default if($dim eq "");
   $_="DIM=$dim\n";
  } 
  if($_=~/^DIM=NATIVE/) {
   if($draw_type eq "IMAGE") {
    # No shell, and the name only as an existing file with a path: the
    # name comes from the template, and identify reads "|cmd" and "coder:"
    # names as commands and formats.
    my $image_path=(($image // "")=~m{^/}) ? $image : "./".($image // "");
    if(-f $image_path && open(my $id,"-|","identify","-ping","-format","%w %h",$image_path)) {
     $dim=((<$id>) // "")=~s/ /,/r;
     close($id);
    }
    $_="DIM=$dim\n" if($dim ne "");
   }
  }
  if($_=~/^DIM=(.*)\%/) {
   $sqrt=sqrt($1/100);
   $dim=&round_val($sqrt*$w_s).",".&round_val($sqrt*$h_s);
   $_="DIM=$dim\n";
  } 
  if($_=~/^DIM=(.*)/) {
   $dim=$1;
   if(!$scaling_disabled) {
    $dim=&round_val((split(",",$dim))[0]*($w_s/$max_x)).",".&round_val((split(",",$dim))[1]*($h_s/$max_y));
   }
   $_="DIM=$dim\n";
   @num_dim=split(",",$dim);
   for(@num_dim) { return &error() if(/[^0-9]/); }
   return &error() if($num_dim[0] > $w_s || $num_dim[1] > $h_s);
   $str.=$_;
   next;
  }
  #
  # MACRO
  #
    if($_=~/^MACRO=(.*)/) {
     &get_pattern($type,$1,$rgb,"MACRO",$source_range,$source_max);
   next;
  }
  #
  # EVAL DISABLED for security reason
  #
  return &error("$error_response:Refused: eval denied") if($_=~/^EVAL=(.*)/);
  # 
  # POSITION
  #
  if($_=~/^POSITION=DYNAMIC/) {
   $pos=$1                if($pos eq "" && /^POSITION=DYNAMIC\|\|(.*)/);
   $pos=$position_default if($pos eq "");
   $_="POSITION=$pos\n";
  }
  if($_=~/^POSITION=(.*)/) {
   $pos=&get_position($dim,$draw_type,$1,$scaling_disabled);
   @num_sep=split(",",$1);
   for(@num_sep) { return &error() if(/[^0-9-]/); }
   @num_sep=split(",",$pos);
   for(@num_sep) { return &error() if(/[^0-9-]/); }
   $str.="POSITION=$pos\n";
   next;
  }
  #
  # BG
  #
  if($_=~/^BG=DYNAMIC/) {
   $bg=$1          if($bg eq "" && /^BG=DYNAMIC\|\|(.*)/);
   $bg=$bg_default if($bg eq "");
   return &error() if($bg!~/^-?\d+,-?\d+,-?\d+$/);
   $str.="BG=$bg\n";
   next;
  }
  #
  # RESOLUTION
  #
  if($_=~/^RESOLUTION=DYNAMIC/) {
   $res=$1           if($res eq "" && /^RESOLUTION=DYNAMIC\|\|(.*)/);
   $res=$res_default if($res eq "");
   $str.="RESOLUTION=$res\n";
   next;
  }
  #
  # BITS
  #
  if($_=~/^BITS=DYNAMIC/) {
   $bits=$1             if($bits eq "" && /^BITS=DYNAMIC\|\|(.*)/);
   $bits=$bits_default  if($bits eq "");
   $_="BITS=$bits\n";
  }
  #
  # RGB
  #
  if($_=~/^RGB=DYNAMIC/) {
   $rgb=$1             if($rgb eq "" && /^RGB=DYNAMIC\|\|(.*)/);
   $rgb=$rgb_default   if($rgb eq "");
   $_="RGB=$rgb\n";
  } 
  if($_=~/^RGB=(.*)/) {
   $rgb=$rgb_default if($rgb eq "");
   @num_lut=split(",",$1);
   for(@num_lut) { return &error() if(/[^0-9]/); }
   $lut=&lut($1);
   @num_lut=split(",",$lut);
   for(@num_lut) { return &error() if(/[^0-9]/); }
   $str.="RGB=$lut\n";
   next;
  }
  #
  # DEFAULT
  #
  $str.=$_;
 }
 #
 # Write definitive pattern
 #
 $bits=$bits_default if($bits eq "");
 $str=~s/^END=(.*)$/SOURCE_MAX=$source_max\nEND=$1/mg if($source_max > 0 && $str !~/^SOURCE_MAX=/m);
 $source_range=&pattern_default_source_range($source_range) if($str !~/^SOURCE_RANGE=/m);
 $str=~s/^END=(.*)$/SOURCE_RANGE=$source_range\nEND=$1/mg if($source_range ne "");
 $str.="FRAME=$frame_default\n"  if($str !~/\n^FRAME=/m);
 my $head="";
 $head.="PATTERN_NAME=$pattern\n" if($str !~/^PATTERN_NAME=/m);
 $head.="BITS=$bits\n"   if($str !~/\n^BITS=/m);
 my $locked=&output_pattern_begin($requested_by);
 if(!&pattern_file_write($head.$str)) { &output_pattern_end($locked);return &error("pattern not written"); }
 &load_new_pattern_file("$requested_by");
 &output_pattern_end($locked);
 unlink("$var_dir/running/$pattern.tmp") if(-f "$var_dir/running/$pattern.tmp");
 #
 # Stats and Return
 #
 &stats("patterns",1);
 return $ok_response;
}

###############################################
#               Pattern Pos                   #
###############################################
sub get_position (@) {
 my $dim = shift;
 my $type = shift;
 my $pos = shift;
 my $scaling_disabled=shift;
 my ($w,$h)=split(",",$dim);
 my ($x,$y,$d_x,$d_y)=split(",",$pos);
 $d_x=0 if($w == $w_s);
 $d_y=0 if($h == $h_s);
 if($type eq "RECTANGLE") {
  $x=($w_s-$w)/2 if($x == -1);
  $y=($h_s-$h)/2 if($y == -1);
 }
 if($type eq "CIRCLE") {
  $x=$w_s/2 if($x == -1 && $w != $w_s);
  $y=$h_s/2 if($y == -1 && $h != $h_s);
 }
 if($type eq "TRIANGLE") {
  $x=$w_s/2 if($x == -1 && $w != $w_s);;
  $y=$h_s/2 if($y == -1 && $h != $h_s);;
 }
 $x=int($x+$d_x);
 $y=int($y+$d_y);
 $x=&round_val($x*($w_s/$max_x)) if(!$scaling_disabled && (split(",",$pos))[0] != "-1");
 $y=&round_val($y*($h_s/$max_y)) if(!$scaling_disabled && (split(",",$pos))[1] != "-1");
 return "$x,$y";
}

###############################################
#              Replace String                 #
###############################################
sub replace_string (@) {
 my $string = shift;
 my $rgb = shift;
 my $date = localtime(time);
 my $eth_interface=&get_ip("$eth_interface");
 $string=~s/\$RGB/$rgb/g;
 $string=~s/\$DATE/$date/g;
 $string=~s/\$ETH_INTERFACE/$eth_interface/g;
 return $string;
}

###############################################
#                    Lut                      #
###############################################
sub lut (@) {
 my $rgb = shift;
 ($r,$g,$b)=split(",",$rgb);
 $file=$lut_file;
 return if($file eq "" || !-f $file);
 open(LUT,$file);
 while(<LUT>) {
  next if($_=~/^#/);
  if($_=~/^($r|ALL),($g|ALL),($b|ALL)=(.*)/ || $_=~/.*ALL.*=(.*)/) {
   ($r_d,$g_d,$b_d)=split(",",$4);
   $r=$r+$r_d;
   $g=$g+$g_d;
   $b=$b+$b_d;
   last;
  }
 }
 close(LUT);
 return "$r,$g,$b";
}

return 1;

###############################################
#             Create File Pattern             #
###############################################
sub create_tmp_file(@) {
 my $pattern_string = shift;
 my $source_range = shift;
 $source_range=&pattern_default_source_range($source_range) if($pattern_string !~/^SOURCE_RANGE=/m);
 $pattern_string=~s/^END=(.*)$/SOURCE_RANGE=$source_range\nEND=$1/mg if($source_range ne "");
 return &pattern_file_write($pattern_string);
}

###############################################
#           Clean Pattern Files               #
###############################################
sub clean_pattern_files (@) {
 &remove_files("$var_dir/tmp","\.jpg\$");
 &remove_files("$var_dir/tmp","\.png\$");
 &remove_files("$var_dir/running","\.jpg\$");
 &remove_files("$var_dir/running","\.png\$");
 &remove_files("$var_dir/running","\.save\$");
 &remove_files("$var_dir/frames",".*");
}

###############################################
#               Round Function                #
###############################################
sub round_val (@) {
 my $value = shift;
 return int($value+0.5);
}

return 1;
