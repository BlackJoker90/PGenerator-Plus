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
#            Write File Function              #
###############################################
# Returns 1 when the content reached $file, 0 when opening, writing,
# closing or the rename failed: a caller that reports what it wrote
# (PGenerator.conf) must not report a lost write as done.
sub write_file(@) {
 my $file_tmp = shift;
 my $file = shift;
 my $content = shift;
 my $do_sync = shift;
 my $ok = 0;
 if(open(FILE,">$file_tmp")) {
  $ok = (print FILE $content) ? 1 : 0;
  $ok = 0 if(!close(FILE));
 }
 $ok = (rename("$file_tmp","$file") ? 1 : 0) if($ok && $file_tmp ne $file);
 &sync() if($do_sync);
 return $ok;
}

###############################################
#         Read From File File Function        #
###############################################
sub read_from_file(@) {
 my $file = shift;
 my $content="";
 open(FILE,"$file");
 while(<FILE>) {
  $content.=$_;
 }
 return $content;
}

###############################################
#             Upload File Function            #
###############################################
# Appends one base64 chunk to $tmp_name (created if missing). Returns 1
# when it was written, 0 when the file could not be opened, written or
# closed: the caller must not store an upload with a hole in it.
sub upload_file(@) {
 my $name = shift;
 my $tmp_name = shift;
 my $data=shift;
 open(my $fh,">>",$tmp_name) or return 0;
 binmode($fh);
 my $ok = (print $fh decode_base64($data)) ? 1 : 0;
 $ok = 0 if(!close($fh));
 return $ok;
}

# A new, empty temp file for one upload; "" when none can be made. Two
# uploads at once each get their own: the name carries a counter, and
# O_EXCL never opens a file that is already there.
my $upload_tmp_seq = 0;
sub upload_tmp_create(@) {
 require Fcntl;
 for(1..20) {
  my $name = "$upload_tmp_dir/UPLOAD_FILE.".time().".$$.".(++$upload_tmp_seq);
  if(sysopen(my $fh,$name,Fcntl::O_WRONLY()|Fcntl::O_CREAT()|Fcntl::O_EXCL(),0666)) {
   close($fh);
   return $name;
  }
 }
 return "";
}

###############################################
#       Get File Destination Function         #
###############################################
# A target named by a pattern port client: IMAGES, PLUGINS, VIDEO, or one
# existing folder directly in $var_dir. Anything else ("../x", "a/b", a
# missing folder) returns "" and the caller refuses the request.
sub get_destination(@) {
 my $where = shift;
 return "" if(!defined $where);
 return $pattern_images  if($where eq "IMAGES");
 return $pattern_plugins if($where eq "PLUGINS");
 return $pattern_video   if($where eq "VIDEO");
 return "" if($where !~/^[A-Za-z0-9][A-Za-z0-9._-]*$/);
 return "" if(-l "$var_dir/$where" || !-d "$var_dir/$where");
 return "$var_dir/$where";
}

###############################################
#           Client Path Functions             #
###############################################
# A file name sent by a client: one plain name, never a path. Returns the
# name, or "" for an empty name, ".", "..", a slash, a backslash or NUL.
sub safe_file_name(@) {
 my $name = shift;
 return "" if(!defined $name || $name eq "" || $name eq "." || $name eq "..");
 return "" if($name =~/[\/\\\x00]/);
 return $name;
}

# $path (relative, already URL-decoded) inside $base: no ".." segment and,
# with every symlink followed, still inside the real $base. Returns the
# real path of an existing entry, or "".
sub path_inside(@) {
 my ($base,$path) = @_;
 return "" if(!defined $base || !defined $path || $path =~/\x00/);
 return "" if(grep { $_ eq ".." } split(/\/+/,$path));
 require Cwd;
 my $real_base = Cwd::abs_path($base);
 return "" if(!defined $real_base || !-e "$base/$path");
 my $real = Cwd::abs_path("$base/$path");
 return "" if(!defined $real);
 return $real if($real eq $real_base || index($real,"$real_base/") == 0);
 return "";
}

# A ZIP upload: unpacked into a private folder first, then only plain
# files and folders are moved into $dest. An entry can neither leave $dest
# ("../", absolute names) nor plant a symlink there. Returns 1 when every
# entry arrived.
sub upload_extract_zip(@) {
 my ($zip,$dest) = @_;
 require File::Path;
 my $stage = "$upload_tmp_dir/UPLOAD_ZIP.".time().".$$";
 return 0 if(!mkdir($stage,0700));
 # unzip exits 1 for warnings (e.g. a skipped "../" component).
 my $rc = system($unzip,"-qq","-o","-d",$stage,$zip);
 my $ok = ($rc != -1 && ($? >> 8) <= 1) ? 1 : 0;
 $ok = 0 if($ok && !&upload_move_tree($stage,$dest));
 File::Path::remove_tree($stage);
 return $ok;
}

sub upload_move_tree(@) {
 my ($from,$to) = @_;
 require File::Copy;
 my $dh;
 return 0 if(!opendir($dh,$from));
 my @names = grep { $_ ne "." && $_ ne ".." } readdir($dh);
 closedir($dh);
 my $ok = 1;
 foreach my $name (@names) {
  my ($src,$dst) = ("$from/$name","$to/$name");
  if(-l $src) {
   $ok = 0;
  } elsif(-d $src) {
   if(-l $dst || (-e $dst && !-d $dst)) { $ok = 0; next; }
   if(!-d $dst && !mkdir($dst)) { $ok = 0; next; }
   $ok = 0 if(!&upload_move_tree($src,$dst));
  } elsif(-f $src) {
   # Never write through a symlink already in the target.
   unlink($dst) if(-l $dst);
   $ok = 0 if(!File::Copy::move($src,$dst));
  }
 }
 return $ok;
}

###############################################
#              Remove Files Function          #
###############################################
sub remove_files(@) {
 $where = shift;
 $pattern_what = shift;
 if(-d "$where") {
  opendir(DIR,$where);
  @dir=readdir(DIR);
  for(@dir) {
   next if(!-f "$where/$_");
   next if(!/$pattern_what/);
   unlink("$where/$_");
  }
 }
}
return 1;
