/*
 * Copyright (c) 2017-2021 Biasiotto Riccardo
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.

 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.

 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * See the File README and COPYING for more detail about License
 *
*/

#pragma once
#include <boost/algorithm/string.hpp>
#include <boost/lexical_cast.hpp>
#include <boost/date_time/posix_time/posix_time.hpp>

/* Start Include RPI p4 header file */
#include "ofxRPI4Window.h"
#include "dovi_metadata.h"
#include "picture_cache.h"
#define GL_RGB10 0x8052
#define GL_RGB10_A2 0x8059
#define GL_RGBA16F  0x881A
#define GL_RGBA8    0x8058
/* End Include RPI p4 header file */

#include "ofMain.h"

class ofApp : public ofBaseApp{
 public:
  char path[100]="/var/lib/PGenerator/operations.txt";
  char DOLOG[100]="/var/log/PGenerator/DOLOG";
  char save_frame_file[100]="/var/lib/PGenerator/save";
  char pid_file[100]="/var/run/PGenerator/PGeneratord.pid";
  char tmp_dir[100]="/var/lib/PGenerator/";
  char text_font[100]="/var/lib/PGenerator/fonts/PGenerator.ttf";
  ofTrueTypeFont myfont;
  ofImage img;
  /* Start Patch For RPI 4 */
  ofFloatImage float_img;
  ofShortImage short_img;
  ofFbo fbo8;
  ofFbo fbo10;
  ofFbo fbo_dovi;
  /* BITS of the pattern: 8 or 10 (the update() parse loop takes no other).
     8 until a pattern says otherwise: 0 made the YCbCr shifts
     (128 << (bits - 8), rgb2ycbcr.h) undefined. */
  int bits=8;
  int source_max=255;
  int source_range=0;
  int dv_source_red=0;
  int dv_source_green=0;
  int dv_source_blue=0;
  int dv_source_max=255;
  int dv_source_range=0; // SOURCE_RANGE of the draw: 1 limited, 2 full codes, 0 unset
  std::string previous_draw_type;
  PictureCache picture; // the picture image() holds as a texture
  bool picture_fresh=false; // a pattern was read since image() last drew
  /* End Patch For RPI 4 */

  string image_save;
  bool save_checked=false;
  std::string save_checked_name;
  uint64_t save_checked_at=0;
  string movie_name;
  int sleep_time=0;
  int first_done=0;
  std::string draw_type;
  std::string p_name;
  std::string name;
  std::string m_name;
  std::string text_to_write;
  std::string img_file;
  int save_images=0;
  int position_x=0;
  int img_rotate=0;
  int entered=0;
  int open_file=1;
  int i=0;
  int def_r=0;
  int def_g=0;
  int def_b=0;
  int n_frame=0;
  unsigned long long last_frame_time=0;
  int to_draw=0;
  int position_y=0;
  int dim1=0;
  int dim2=0;
  int width=0;
  int height=0;
  int resolution=0;
  int red=0;
  int green=0;
  int blue=0;
  int redb=0;
  int greenb=0;
  int blueb=0;
  int duration=0;
  int frame=0;
  int frame_to_draw=0;
  /* A parsed pattern: frames of draw commands, sized to what the file
     holds and capped at max_frames x max_draws. */
  struct DrawOp {
   int draw=0, red=0, green=0, blue=0, redbg=0, greenbg=0, bluebg=0;
   int dim1=0, dim2=0, posx=0, posy=0, resolution=0, rotate=0;
   int bits=0, source_max=0, source_range=0;
   std::string text, image;
  };
  struct PatternFrame {
   std::string name;
   unsigned long long time=0, duration=0;
   std::vector<DrawOp> ops;
  };
  static const int max_frames=2048;
  static const int max_draws=2048;
  std::vector<PatternFrame> frames;
  DrawOp no_op;
  DrawOp& cur_op();
  int frame_draws(int f);
  ofVideoPlayer myPlayer;
  void setup();
  void update();
  void draw();
  void rectangle();
  void circle();
  void triangle();
  void text();
  void image();
  void set_values();
  void log(std::string);
  /* Pattern file numbers: false (value kept, line logged) instead of an
     exception out of update() on a malformed value. */
  bool parseIntValue(const std::string &key, const std::string &text, int &out);
  bool parseIntList(const std::string &key, const std::string &text, size_t count, int *out);
  /* Start Patch For RPI 4 */
  void setColor(int red, int green, int blue);
  void setBackground(int redbg, int greenbg, int bluebg);
  int normalizeSourceValue(int value, int source_range_mode);
  int scaleSourceToBitDepth(int value);
  int sourceToOutputCode(int value);
  void normalizeImageSourcePixels(int source_range_mode);
  int imageNormalization(int source_range_mode);
  bool usesFloatImage();
  void setDoViBackground(int redbg, int greenbg, int bluebg);
  void shader_begin(int is_image);
  void shader_end(int is_image);
  void YCbCr2RGB();
  void grabFrameForSave();
  static int dv_map_mode;
  static int dv_minpq;
  static int dv_maxpq;
  static int dv_diagonal;
  static int dv_full;
  /* The packet's form (dovi_metadata.h, conf dv_packet, main.cpp):
     dovi::form_calman in a Calman session, form_pitpg for a PiTPG client,
     else PGenerator 1.6's form (form_pg16). */
  static int dv_packet_form;
  static int doviSourceFull(int source_range);
  void dovi_rpu_inject();
  void dovi_metadata_mux();
  void dovi_metadata_create();
  /* Standard Dolby Vision metadata (dovi_metadata.h): the packet as 32
     MSB-first words, for 1.6's metadata pixels (dovi_fixed_pixels_draw) or,
     in a PiTPG session, the embedding shader, which sets each tunnel
     pixel's parity to one packet bit (pitpgd dv_embed). */
  void dovi_packet_set(int run_mode);
  /* PGenerator 1.6's metadata pixels (ofxRPI4Window::dv_tunnel_pg16): the
     packet bits as pixels of the packed bytes 128, 16, 16/0 (Y 256,
     C 2049/2048; dovi_tunnel.h) in fbo_dovi,
     drawn over the frame by dovi_metadata_mux. */
  void dovi_fixed_pixels_draw();
  /* The draw colour of 1.6's tunnel (globalColor, ofxRPI4Window
     pg16_dovi_pattern_frag). */
  void doviSetPg16Color(int red, int green, int blue);
  ofShader dovi_embed;
  int dv_packet_words[32] = {0};
  /* Start sequence of PiTPG's form after a mode set (pitpgd
     dv_show@0x40d2c0; dovi::startSequence): the packet
     goes out without the run-mode block first and gets it after
     dv_start_wait_ms from the first frame; dv_start_pending holds the run
     mode still to send. */
  int dv_start_pending=0;
  int dv_start_wait_ms=0;
  uint64_t dv_start_t0=0;
  void dovi_dump();
  void fbo_allocate();
  /* End Patch For RPI 4 */
};
