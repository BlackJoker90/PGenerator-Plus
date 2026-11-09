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

#include "ofApp.h"
#include <algorithm>
#include <unistd.h>
#include <sys/stat.h>

/* Start Patch RPI P4 */
#include "rgb2ycbcr.h"
#include "pattern_parse.h"
#include "dovi_tunnel.h"
#include "dovi_metadata.h"
/* End Patch RPI P4 */

namespace {

inline float normalize10bitComponent(int value) {
 float normalized = static_cast<float>(value) / 1023.0f;
 if (normalized < 0.0f) return 0.0f;
 if (normalized > 1.0f) return 1.0f;
 return normalized;
}

// 10 bit codes go to the GPU as code/1023 through the renderer's exact
// colour (src/of-patches/of-exact-color.patch), as in PGenerator 1.6.
// ofSetColor/ofBackground only take 8 bit ofColor: an ofFloatColor was
// truncated to 8 bit there, so e.g. 64 came out as 60 and 513 as 509.
#ifdef OF_PGENERATOR_EXACT_COLOR
inline ofGLProgrammableRenderer *exactColorRenderer() {
 return dynamic_cast<ofGLProgrammableRenderer *>(ofGetCurrentRenderer().get());
}
#else
#warning "openFrameworks without of-exact-color.patch: 10 bit colours are quantised to 8 bit"
inline ofGLProgrammableRenderer *exactColorRenderer() {
 return nullptr;
}
#endif

inline void ofSet10bitColor(int red, int green, int blue, int alpha = 1023) {
 ofGLProgrammableRenderer *renderer = exactColorRenderer();
#ifdef OF_PGENERATOR_EXACT_COLOR
 if(renderer) {
  renderer->setExactColor(normalize10bitComponent(red), normalize10bitComponent(green), normalize10bitComponent(blue), normalize10bitComponent(alpha));
  return;
 }
#endif
 ofSetColor(ofFloatColor(normalize10bitComponent(red), normalize10bitComponent(green), normalize10bitComponent(blue), normalize10bitComponent(alpha)));
}

inline void of10bitBackground(int red, int green, int blue, int alpha = 1023) {
 ofGLProgrammableRenderer *renderer = exactColorRenderer();
#ifdef OF_PGENERATOR_EXACT_COLOR
 if(renderer) {
  renderer->backgroundExact(normalize10bitComponent(red), normalize10bitComponent(green), normalize10bitComponent(blue), normalize10bitComponent(alpha));
  return;
 }
#endif
 ofBackground(ofFloatColor(normalize10bitComponent(red), normalize10bitComponent(green), normalize10bitComponent(blue), normalize10bitComponent(alpha)));
}

inline void ofClear10bit(int red, int green, int blue, int alpha = 1023) {
 of10bitBackground(red, green, blue, alpha);
}

inline bool usesPackedTransportEncoding() {
 return ofxRPI4Window::is_std_DoVi ||
	 (!ofxRPI4Window::isHDR && !ofxRPI4Window::isDoVi && !ofxRPI4Window::is_std_DoVi &&
	  ofxRPI4Window::avi_info.output_format != 0);
}

inline bool usesDolbyVisionTransport() {
 return ofxRPI4Window::isDoVi || ofxRPI4Window::is_std_DoVi;
}

/*
 * An 8-bit pattern on a 10 or 12 bpc link (G1 plates, diagnostic images):
 * an 8-bit plane leaves the 8 -> 10 bit step to the HVS, which replicates
 * the top bits (235 -> 943, 128 -> 514). Draw it in the 10-bit framebuffer
 * instead, with the codes the 8-bit pattern has on an 8 bpc link times 4.
 * This holds for SDR, HDR10/HLG and Low Latency DV (12 bpc wire, 10-bit
 * surface). Standard DV tunnels 8-bit RGB on the 8-bit surface whatever
 * BITS says: its shader takes the 12-bit codes from SOURCE_MAX, and the
 * 10-bit surface fails on the Pi 4 (glTexImage2D RGB10_A2 rejected, FBO
 * incomplete, AB30 241 on the wire), e.g. after a Calman "Bits 10".
 */
inline int effectivePatternBits(int bits) {
 if(ofxRPI4Window::is_std_DoVi)
  return 8;
 if(bits != 8 || ofxRPI4Window::wire_bpc < 10)
  return bits;
 return 10;
}

// 8-bit pattern promoted to the 10-bit framebuffer by effectivePatternBits().
inline bool promotedEightBitPattern(int arr_bits) {
 return arr_bits == 8 && ofxRPI4Window::bit_depth == 10 && !ofxRPI4Window::is_std_DoVi;
}

// Standard DV metadata tunnel: dovi_tunnel.h (pixels 0..3071, ETSI GS CCM
// 001 6.4.1 and 6.4.3).
inline int doviWindowMetadataLines() {
	return doviMetadataLines(ofGetWindowWidth());
}

inline bool usesLowLatencyDoVi422Transport() {
	return false;
}

// ofApp::log() is compiled out; keep per-element sprintf work out of draw().
const bool log_enabled = false;

// Interval at which update() re-checks the running/<pattern>.save marker
// while the pattern itself is unchanged.
const uint64_t save_check_interval_ms = 100;

// YCbCr output needs the RGB->YCbCr conversion shader. Low-latency Dolby
// Vision in RGB is plain RGB (PiTPG 2.0.3): its codes are drawn as they are.
inline bool usesYCbCrConversionShader() {
 return ofxRPI4Window::avi_info.output_format != 0;
}

// Any draw that has to go through ofxRPI4Window::shader (YCbCr conversion
// or the standard Dolby Vision packer).
inline bool usesRendererShader() {
 return usesYCbCrConversionShader() || ofxRPI4Window::is_std_DoVi;
}

// The colorimetry the Y'CbCr encode uses: the AVI one, with No Data
// resolved to the default of the running format (SD BT.601, HD BT.709).
// The window is the mode (currentWindowRect), so its height is Vactive.
inline int encodeColorimetry() {
 return YCbCrMatrixColorimetry(ofxRPI4Window::avi_info.colorimetry, ofGetWindowHeight());
}

inline void setShaderYCbCrCoeffs(int colorimetry) {
 YCbCrCoeffs k = YCbCrCoeffsForColorimetry(colorimetry);
 ofxRPI4Window::shader.setUniform3f("coeffs_num", k.Kr, k.Kg, k.Kb);
 ofxRPI4Window::shader.setUniform3f("coeffs_div", k.d, k.e, 0.5);
}
}

/*
 ##########################################################
 #                           Setup                        #
 ##########################################################
*/
void ofApp::setup(){
 ofSetBackgroundAuto(true); 
 /* Start Patch RPI P4 */
 setBackground(def_r,def_g,def_b);
 /* End Patch RPI P4 */
 ofHideCursor();

 /* Pid Creation */
 std::ofstream pidfile (pid_file);
 pidfile << getpid();
 pidfile.close();
}

/*
 ##########################################################
 #                           Update                       #
 ##########################################################
*/
void ofApp::update(){
 const bool reparsed=open_file;
 std::string str; 

 if(open_file) {
  frame=frame_to_draw=entered=0;
  p_name=m_name="";
  source_max=255;
  frames.assign(1,PatternFrame());
  ofApp::log("\n\n");   
  ofApp::log("***********************************");
  ofApp::log("*             Open File           *");
  ofApp::log("***********************************");
  std::ifstream file(path);
  while (std::getline(file, str)) {
   entered=1;
   open_file=0;
   last_frame_time=0;
   std::string key, value;
   if(!patternSplitLine(str, key, value))
    continue;
   if(key == "DRAW") {
    draw_type=value;
   }
   if(key == "TEXT")
    text_to_write=value;
   if(key == "PATTERN_NAME")
    p_name=value;
   if(key == "MOVIE_NAME")
    m_name=value;
   if(key == "IMAGE") {
    img_file=value; 
   }
   if(key == "ROTATE")
    parseIntValue(key, value, img_rotate);
   if(key == "DIM") {
    int v[2];
    if(parseIntList(key, value, 2, v)) {
     dim1=v[0];
     dim2=v[1];
    }
   }
   if(key == "RESOLUTION")
    parseIntValue(key, value, resolution);
   if(key == "RGB") {
    int v[3];
    if(parseIntList(key, value, 3, v)) {
     red=v[0];
     green=v[1];
     blue=v[2];
    }
   }
   /* Start Patch RPI P4 */
   if(key == "BITS") {
    if(!parseIntValue(key, value, bits))
     continue;
    ofxRPI4Window::bit_depth = effectivePatternBits(bits);
    if (!usesDolbyVisionTransport())
     ofxRPI4Window::avi_info.max_bpc = ofxRPI4Window::bit_depth;
 //   ofxRPI4Window::colorspace_on=1;
   }
   if(key == "SOURCE_MAX") {
    if(!parseIntValue(key, value, source_max))
     source_max=255;
    if(source_max != 255 && source_max != 1023 && source_max != 4095)
     source_max=255;
   }
   /* End Patch RPI P4 */
   if(key == "POSITION") {
    int v[2];
    if(parseIntList(key, value, 2, v)) {
     position_x=v[0];
     position_y=v[1];
    }
   }
   if(key == "BG") {
    int v[3];
    if(parseIntList(key, value, 3, v)) {
     redb=v[0];
     greenb=v[1];
     blueb=v[2];
    }
   }
	if(key == "SOURCE_RANGE") {
	 /* 1 LIMITED: studio-range codes; 2 FULL: full-range codes that a
	    YCbCr link (always Limited) must compress; 0: unspecified. */
	 source_range=(value == "LIMITED") ? 1 : (value == "FULL") ? 2 : 0;
	}
   if(key == "FRAME_NAME") {
    name=value;
    frames[frame].name=name;
   }
   if(key == "FRAME") {
    int seconds=0;
    parseIntValue(key, value, seconds);
    frames[frame].time=seconds*1000;
    if(frame+1 < max_frames) {
     frame++;
     frames.push_back(PatternFrame());
    } else
     ofApp::log("Too many frames: the rest of the pattern is drawn into the last one");
   }
   if(key == "FRAME_DURATION") {
    int seconds=0;
    if(parseIntValue(key, value, seconds))
     frames[frame].duration=seconds*1000;
   }
   if(key == "END") {
    ofApp::set_values();
    dim1=dim2=0;
	source_range=0;
   }
  }
  // A pattern was read: the next completed flip shows it (running/presented).
  if(entered)
   ofxRPI4Window::frame_tag++;
 }
  /* Start Patch RPI P4 */
	if (draw_type == "IMAGE") {
	 ofxRPI4Window::colorspace_on = 0;
	}else {
   ofxRPI4Window::colorspace_on = 1;
   loop_count=0; //reset counter
   previous_image = ""; 
  }
#if 1 
	if (ofxRPI4Window::shader_init && usesYCbCrConversionShader()) {
 //  ofxRPI4Window::rgb2ycbcr_shader();
   ofxRPI4Window::shader_init=0;
  }
  if (ofxRPI4Window::shader_init && ofxRPI4Window::is_std_DoVi) {

//  if (ofxRPI4Window::colorspace_on) ofxRPI4Window::dovi_pattern_shader();
 // else							     ofxRPI4Window::dovi_image_shader();
   ofApp::fbo_allocate(); //allocate framebuffer for DoVi background and patch
   ofApp::dovi_metadata_create(); // create dovi metadata fbo 
   ofxRPI4Window::shader_init=0; 
  }
#endif  
  previous_draw_type = draw_type;
  /* End Patch RPI P4 */
 // Only stat the .save marker after a (re)parse, when the pattern name
 // changed, or every save_check_interval_ms, instead of on every frame.
 uint64_t now_ms=ofGetElapsedTimeMillis();
 if(reparsed || !save_checked || p_name != save_checked_name ||
    now_ms - save_checked_at >= save_check_interval_ms) {
  save_checked=true;
  save_checked_name=p_name;
  save_checked_at=now_ms;
  image_save=tmp_dir+ofToString("running/")+ofToString(p_name)+".save";
  if (access(image_save.c_str(), F_OK) == 0)
   save_images=1;
 }
}

/*
 ##########################################################
 #                           Draw                         #
 ##########################################################
*/
void ofApp::draw(){
 if(entered == 0) {
  /* Idle (no pattern yet): an RGB (0,0,0) framebuffer is decoded by the
     sink as Y=0/Cb=0/Cr=0, i.e. green. Clear to encoded YCbCr black every
     frame; a flip may recreate the renderer, so a one-time background set
     in setup() does not survive. RGB clears to black as well: otherwise the
     openFrameworks default background (light grey) fills the screen, e.g.
     after an HDMI hotplug start. Low-latency Dolby Vision is plain YCbCr
     (metadata in the infoframe) and clears the same way; standard Dolby
     Vision carries metadata in the pixels and stays unchanged. */
  if(ofxRPI4Window::avi_info.output_format != 0 && !ofxRPI4Window::is_std_DoVi) {
   int bits = ofxRPI4Window::bit_depth ? ofxRPI4Window::bit_depth : 8;
   int shift = bits - 8;
   int y = (ofxRPI4Window::avi_info.rgb_quant_range == 2 ? 0 : 16) << shift;
   int c = 128 << shift;
   if(bits == 10) {
    if(ofxRPI4Window::avi_info.output_format == 1) ofClear10bit(c,c,y);  //in YCbCr444, luminance is last channel
    if(ofxRPI4Window::avi_info.output_format == 2) ofClear10bit(y,c,c);  //in YCbCr422
   } else {
    if(ofxRPI4Window::avi_info.output_format == 1) ofClear(c,c,y,255);
    if(ofxRPI4Window::avi_info.output_format == 2) ofClear(y,c,c,255);
   }
  } else if(ofxRPI4Window::rgbLimitedPassthrough()) {
   /* No CSC after the framebuffer: clear to Limited black. */
   if(ofxRPI4Window::bit_depth == 10) ofClear10bit(64,64,64);
   else                               ofClear(16,16,16,255);
  } else if(!ofxRPI4Window::isDoVi && !ofxRPI4Window::is_std_DoVi) {
   ofClear(0,0,0,255);
  }
  return;
 }
 if(i < 0 || i >= (int)frames.size())
  i=0;
 if(frame_draws(i) > 0) {
  string return_file=tmp_dir+ofToString("/running/return");
  const char * return_file_char = return_file.c_str();
  /* A new pattern is parsed by the next update(). This frame still draws
     the current one: returning without drawing put a cleared (black)
     frame on screen for as long as the next pattern took to load (about
     0.3 s for a full-screen image). */
  if (access(return_file_char, F_OK) == 0) {
   i=0;
   open_file=1;
   save_images=0;
   unlink(return_file_char);
  }
 }
 for(to_draw=0;to_draw<frame_draws(i);to_draw++) {
  if(log_enabled) {
   char buffer[255];
   sprintf(buffer,"Doing the frame %d and the Draw %d",i,to_draw);
   ofApp::log(buffer);
   sprintf(buffer,"RGB: %d %d %d",cur_op().red,cur_op().green,cur_op().blue);
   ofApp::log(buffer);
   sprintf(buffer,"Background: %d %d %d",cur_op().redbg,cur_op().greenbg,cur_op().bluebg);
   ofApp::log(buffer);
   sprintf(buffer,"DrawType: %d",cur_op().draw);
   ofApp::log(buffer);
   if(cur_op().draw == 4) {
    sprintf(buffer,"DrawImage: %s",cur_op().text.c_str());
    ofApp::log(buffer);
   }
   if(cur_op().draw == 5) {
    sprintf(buffer,"DrawImage: %s",cur_op().image.c_str());
    ofApp::log(buffer);
   }
   sprintf(buffer,"Dim: %d %d",cur_op().dim1,cur_op().dim2);
   ofApp::log(buffer);
   sprintf(buffer,"Resolution: %d",cur_op().resolution);
   ofApp::log(buffer);
   sprintf(buffer,"Position: %d %d",cur_op().posx,cur_op().posy);
   ofApp::log(buffer);

   sprintf(buffer,"Bits: %d",cur_op().bits);
   ofApp::log(buffer);
  }

  if(cur_op().draw == 0) 
   ::exit(0);
 /* Start Patch RPI P4 */
 //  ofApp::fbo_allocate(); //allocate framebuffer for DoVi background and patch


  
  ofApp::setBackground(cur_op().redbg, cur_op().greenbg, cur_op().bluebg);

  ofApp::setColor(cur_op().red,cur_op().green,cur_op().blue); 

  if(cur_op().draw !=  5) ofApp::shader_begin(0); //set for draw = 0
 /* End Patch RPI P4 */
  if(cur_op().draw ==  1)
   ofApp::rectangle();
  if(cur_op().draw ==  2)
   ofApp::circle();
  if(cur_op().draw ==  3)
   ofApp::triangle();
  if(cur_op().draw ==  4)
   ofApp::text();
  /* Start Patch RPI P4 */
  if(cur_op().draw != 5) ofApp::shader_end(0); //set for draw = 0
   if (cur_op().draw !=  5 && ofxRPI4Window::is_std_DoVi && !ofxRPI4Window::shader_init) ofApp::dovi_metadata_mux(); //draw dovi metadata muxed patch only if shader already initialized
  /* End Patch RPI P4 */
  if(cur_op().draw ==  5)
   ofApp::image();
  /* Start Patch RPI P4 */
  if (cur_op().draw ==  5 && ofxRPI4Window::is_std_DoVi && !ofxRPI4Window::shader_init) ofApp::dovi_metadata_mux(); //draw dovi metadata muxed with patch only if shader already initialized
   /* End Patch RPI P4 */
  if(last_frame_time == 0)
   last_frame_time=ofGetSystemTimeMicros();
 }
 if(save_images && i!=0 && !first_done)
  save_images=0;
 if (save_images) {
  first_done=1;
  //int n_frame=ofGetFrameNum();
  n_frame++;
  if(n_frame != 0 && n_frame > 3) {
   string movie_time=ofToString(frames[i].time);
   if(frames[i].duration)
    movie_time=ofToString(frames[i].duration);
   movie_name=p_name;
   if(!m_name.empty())
    movie_name=m_name;
   //string image_name=tmp_dir+ofToString("/frames/Img_")+ofToString(movie_name)+",,,,"+ofToString(i)+"-"+frames[i].name+",,,,"+movie_time+".png";
   string image_name_tmp=tmp_dir+ofToString("/tmp/")+ofToString(i+1)+"-"+frames[i].name+",,,,"+movie_time+".png";
   string image_name=tmp_dir+ofToString("/frames/")+ofToString(i+1)+"-"+frames[i].name+",,,,"+movie_time+".png";
   const char * c = image_name.c_str();
   ifstream p(c);
   if(!p.good()) {
    img.grabScreen(0,0,ofGetWindowWidth(),ofGetWindowHeight());
	ofApp::YCbCr2RGB();
//	dovi_rpu_inject();
//ofApp::dovi_dump();
//	ofApp::dovi_metadata_inject(ofxRPI4Window::bit_depth);
	if( img.isAllocated() ){
 
	  img.draw(cur_op().posx,cur_op().posy,cur_op().dim1,cur_op().dim2);
	}
	img.save(image_name_tmp);
    rename(image_name_tmp.c_str(),image_name.c_str());
   } else
    p.close();
  }
 }
 if(frames[i].time != 0) {
  unsigned long long diff=ofGetSystemTimeMicros()-last_frame_time;
  if(diff > frames[i].time) {
   i++;
   last_frame_time=0;
   n_frame=0;
  }
 }


 if(i< frame)
  ofApp::log("\n");
 if(i == frame) {
  // Seamless loop: restart from frame 0 using already-parsed draw lists.
  // Setting open_file=1 re-parsed operations.txt every cycle and combined
  // with a trailing empty FRAME produced a visible flash on AVS/diagseq
  // restarts. New patterns still force open_file via the return-file path.
  i=0;
  last_frame_time=0;
  save_images=0;
  if(first_done) {
   unlink(image_save.c_str());
   //string image_done=tmp_dir+ofToString("/frames/Img_")+ofToString(movie_name)+",,,,.done";
   string image_done=tmp_dir+ofToString("/frames/done");
   const char * save_done = image_done.c_str();
   std::ofstream outfile (save_done);
   outfile << movie_name << std::endl;
   outfile.close();
   first_done=0;
  }
 }

}


/*
 ##########################################################
 #                        Set Values                      #
 ##########################################################
*/
void ofApp::set_values () {
 int draw_num=0;
 if(draw_type == "RECTANGLE") draw_num=1;
 if(draw_type == "CIRCLE")    draw_num=2;
 if(draw_type == "TRIANGLE")  draw_num=3;
 if(draw_type == "TEXT")      draw_num=4;
 if(draw_type == "IMAGE")     draw_num=5;
 if((int)frames[frame].ops.size() >= max_draws) {
  ofApp::log("Too many draws in one frame: the rest is ignored");
  return;
 }
 DrawOp op;
 op.text=text_to_write;
 op.red=red;
 op.green=green;
 op.blue=blue;
 op.redbg=redb;
 op.greenbg=greenb;
 op.bluebg=blueb;
 op.draw=draw_num;
 op.dim1=dim1;
 op.dim2=dim2;
 op.posx=position_x;
 op.posy=position_y;
 op.resolution=resolution;
 op.image=img_file;
 op.rotate=img_rotate;
 op.bits=bits;
 op.source_max=source_max;
 op.source_range=source_range;
 frames[frame].ops.push_back(op);
 ofxRPI4Window::bit_depth=effectivePatternBits(bits);
 if (!usesDolbyVisionTransport())
  ofxRPI4Window::avi_info.max_bpc = ofxRPI4Window::bit_depth;
}

/* The draw command being drawn (frame i, command to_draw). Past the end,
   e.g. after the draw loop in the frame-save path: an all-zero command. */
ofApp::DrawOp& ofApp::cur_op() {
 if(i >= 0 && i < (int)frames.size() && to_draw >= 0 && to_draw < (int)frames[i].ops.size())
  return frames[i].ops[to_draw];
 no_op=DrawOp();
 return no_op;
}

int ofApp::frame_draws(int f) {
 if(f < 0 || f >= (int)frames.size())
  return 0;
 return (int)frames[f].ops.size();
}

/*
 ##########################################################
 #                       Rectangle                        #
 ##########################################################
*/
void ofApp::rectangle () {
 if(cur_op().posx == -1) {
  cur_op().posx=(ofGetWindowWidth()-cur_op().dim1)/2;
  cur_op().posy=(ofGetWindowHeight()-cur_op().dim2)/2;
 }
 ofDrawRectangle(cur_op().posx,cur_op().posy,cur_op().dim1,cur_op().dim2);
}
 
/*
 ##########################################################
 #                       Circle                           #
 ##########################################################
*/
void ofApp::circle() {
 ofSetCircleResolution(cur_op().resolution);
 if(cur_op().posx == -1) {
  cur_op().posx=ofGetWindowWidth()/2;
  cur_op().posy=ofGetWindowHeight()/2;
 }
 ofDrawCircle(cur_op().posx,cur_op().posy,cur_op().dim1);
}

/*
 ##########################################################
 #                       Triangle                         #
 ##########################################################
*/
void ofApp::triangle() {
 if(cur_op().posx == -1) {
  cur_op().posx=ofGetWindowWidth()/2;
  cur_op().posy=ofGetWindowHeight()/2;
 }
 ofDrawTriangle(cur_op().posx,cur_op().posy-cur_op().dim1,cur_op().posx-cur_op().dim1,cur_op().posy+cur_op().dim1,cur_op().posx+cur_op().dim1,cur_op().posy+cur_op().dim1);
}

/*
 ##########################################################
 #                         Text                           #
 ##########################################################
*/
void ofApp::text() {
 myfont.load(text_font,cur_op().dim1);
 int width=myfont.stringWidth(cur_op().text);
 //int height=myfont.stringHeight(cur_op().text);
 if(cur_op().posx == -1) {
  cur_op().posx=(ofGetWindowWidth()-width)/2;
  cur_op().posy=ofGetWindowHeight()/2;
 }
 myfont.drawString(cur_op().text,cur_op().posx,cur_op().posy);
}

/*
 ##########################################################
 #                         Image                          #
 ##########################################################
*/
/*
 * Float texture for HDR images and for 10-bit images in SDR (BITS=10: the
 * G1 10-bit plates, 16-bit PNGs whose samples carry 10-bit codes). The
 * 8-bit ofImage would cut those to 8 bits.
 */
bool ofApp::usesFloatImage() {
 /* 8-bit HDR images stay on the 8-bit texture and take the texel * 4
    tint in image(), like SDR. */
 if (ofxRPI4Window::avi_info.max_bpc == 10 && ofxRPI4Window::isHDR && cur_op().bits != 8)
  return true;
 return cur_op().bits == 10 && !usesDolbyVisionTransport();
}

void ofApp::image() {
 if(cur_op().posx == -1) {
  cur_op().posx=(ofGetWindowWidth()-cur_op().dim1)/2;
  cur_op().posy=(ofGetWindowHeight()-cur_op().dim2)/2;
 }
 /* Start Patch RPI P4 */
 if (usesFloatImage()) {
  if (previous_image != cur_op().image || loop_count < 2) { //needs to load each new image twice to allow time to load shader
  float_img.clear();
  float_img.load(cur_op().image);
  float_img.rotate90(cur_op().rotate);
  normalizeImageSourcePixels(cur_op().source_range);

  float_img.getTexture().setTextureMinMagFilter(GL_NEAREST, GL_NEAREST); //set pixel precision
  loop_count++;
  }
  ofSet10bitColor(1023,1023,1023,1023);
//  float_img.update();  //update here no necessary,  occurs in both load and rotate90 routines 
  ofApp::shader_begin(1); //set for image = 1
  float_img.draw(cur_op().posx,cur_op().posy,cur_op().dim1,cur_op().dim2);
  ofApp::shader_end(1); //set for image = 1
 /* End Patch RPI P4 */
 } else {
  if (previous_image != cur_op().image || loop_count < 2) { //needs to load each new image twice to allow time to load shader
    img.clear();
    img.load(cur_op().image);
    img.rotate90(cur_op().rotate);
    normalizeImageSourcePixels(cur_op().source_range);
  //img.update(); //update here no necessary,  occurs in both load and rotate90 routines 
    img.getTexture().setTextureMinMagFilter(GL_NEAREST, GL_NEAREST); //set pixel precision
	loop_count++;
  }
  /* Passthrough puts the texels on the wire as they are, and the YCbCr
     shader encodes them as studio-range codes: an 8-bit texel in the
     10-bit framebuffer must become texel * 4 (white tint gives
     texel * 1023 / 255, 235 -> 943). */
  if (ofxRPI4Window::bit_depth == 10 && !ofxRPI4Window::is_std_DoVi &&
      (ofxRPI4Window::rgbLimitedPassthrough() || ofxRPI4Window::avi_info.output_format != 0))
   ofSet10bitColor(1020,1020,1020,1023);
  else
   ofSetColor(255,255,255,255);
  /* Start Patch RPI P4 */
  ofApp::shader_begin(1); //set for image = 1
  /* End Patch RPI P4 */
  img.draw(cur_op().posx,cur_op().posy,cur_op().dim1,cur_op().dim2); 
  /* Start Patch RPI P4 */
  ofApp::shader_end(1); //set for image = 1
  /* End Patch RPI P4 */
 
 }
 previous_image = cur_op().image; 
}

/*
 ##########################################################
 #                          Log                           #
 ##########################################################
*/
bool ofApp::parseIntValue(const std::string &key, const std::string &text, int &out) {
 if(patternParseInt(text, out))
  return true;
 fprintf(stderr, "PGEN: pattern line %s=%s ignored: not a number\n", key.c_str(), text.c_str());
 return false;
}

bool ofApp::parseIntList(const std::string &key, const std::string &text, size_t count, int *out) {
 if(patternParseInts(text, count, out))
  return true;
 fprintf(stderr, "PGEN: pattern line %s=%s ignored: %zu numbers needed\n", key.c_str(), text.c_str(), count);
 return false;
}

void ofApp::log(std::string str) {
  if (!log_enabled)
   return;
  ifstream f(DOLOG);
  if (f.good()) {
   f.close();
  } else {
   f.close();
   return;
  }   
  std::cout << "[" << boost::posix_time::microsec_clock::local_time().time_of_day().total_milliseconds() << "]: " << str << std::endl;
}

/*
 ##########################################################
 #                   Set Background                       #
 ##########################################################
*/
void ofApp::setBackground(int redbg, int greenbg, int bluebg) {
 redbg=sourceToOutputCode(redbg);
 greenbg=sourceToOutputCode(greenbg);
 bluebg=sourceToOutputCode(bluebg);
 int lldv422=usesLowLatencyDoVi422Transport();
 if (ofxRPI4Window::isHDR && !ofxRPI4Window::isDoVi && !ofxRPI4Window::is_std_DoVi) { 
  if (ofxRPI4Window::bit_depth == 10) {  
   if(cur_op().redbg != -1) {
	if (ofxRPI4Window::avi_info.output_format != 0) {
     RGB data = RGB(redbg,greenbg,bluebg);
     YCbCr bg = RGB2YCbCr(data,10, encodeColorimetry(), ofxRPI4Window::avi_info.rgb_quant_range);
     if (ofxRPI4Window::avi_info.output_format == 1) of10bitBackground(bg.Cb,bg.Cr,bg.Y);  //in YCbCr444, luminance is last channel
     if (ofxRPI4Window::avi_info.output_format == 2) of10bitBackground(bg.Y,bg.Cb,bg.Cr);  //in YCbCr422
    } else                                           of10bitBackground(redbg,greenbg,bluebg);
   }
  } else {
   if(cur_op().redbg != -1) {
	if (ofxRPI4Window::avi_info.output_format != 0) {
     RGB data = RGB(redbg,greenbg,bluebg);
     YCbCr bg = RGB2YCbCr(data,8,encodeColorimetry(), ofxRPI4Window::avi_info.rgb_quant_range);
     if (ofxRPI4Window::avi_info.output_format == 1) ofBackground(bg.Cb,bg.Cr,bg.Y);  //in YCbCr444, luminance is last channel
     if (ofxRPI4Window::avi_info.output_format == 2) ofBackground(bg.Y,bg.Cb,bg.Cr);  //in YCbCr422
    } else                                           ofBackground(redbg,greenbg,bluebg);
   }
  }
 } else {
  if (ofxRPI4Window::bit_depth == 10) {  
   if(cur_op().redbg != -1) {
	if (ofxRPI4Window::avi_info.output_format != 0 || ofxRPI4Window::is_std_DoVi) {
	 if (lldv422) {
	  of10bitBackground(redbg,greenbg,bluebg);
	 } else {
	     RGB data = RGB(redbg,greenbg,bluebg);
	     YCbCr bg = RGB2YCbCr(data,10, encodeColorimetry(), ofxRPI4Window::avi_info.rgb_quant_range);
	     if (ofxRPI4Window::avi_info.output_format == 1) 					of10bitBackground(bg.Cb,bg.Cr,bg.Y);  //in YCbCr444, luminance is last channel
	     if (ofxRPI4Window::avi_info.output_format == 2) 					of10bitBackground(bg.Y,bg.Cb,bg.Cr);  //in YCbCr422
		 if (ofxRPI4Window::is_std_DoVi && ofxRPI4Window::colorspace_on)	ofApp::setDoViBackground(redbg,greenbg,bluebg); //set dovi background only if standard dovi mode and drawing patterns
	 }
	    } else                                           					of10bitBackground(redbg,greenbg,bluebg);
   }
  } else {
   if(cur_op().redbg != -1) {
		if (ofxRPI4Window::avi_info.output_format != 0 || ofxRPI4Window::is_std_DoVi) {
		 if (lldv422) {
		  ofBackground(redbg,greenbg,bluebg);
		 } else {
	     RGB data = RGB(redbg,greenbg,bluebg);
	     YCbCr bg = RGB2YCbCr(data,8,encodeColorimetry(), ofxRPI4Window::avi_info.rgb_quant_range);
	     if (ofxRPI4Window::avi_info.output_format == 1)					ofBackground(bg.Cb,bg.Cr,bg.Y);  //in YCbCr444, luminance is last channel
	     if (ofxRPI4Window::avi_info.output_format == 2) 					ofBackground(bg.Y,bg.Cb,bg.Cr);  //in YCbCr422
		 if (ofxRPI4Window::is_std_DoVi && ofxRPI4Window::colorspace_on) 	ofApp::setDoViBackground(redbg,greenbg,bluebg);  //set dovi background only if standard dovi mode and drawing patterns
		 }
	    } else                                          					ofBackground(redbg,greenbg,bluebg);
   }
  }
 }
}

/*
 ##########################################################
 #                     Set Color                          #
 ##########################################################
*/
void ofApp::setColor(int red, int green, int blue) {
 red=sourceToOutputCode(red);
 green=sourceToOutputCode(green);
 blue=sourceToOutputCode(blue);
 if(ofxRPI4Window::is_std_DoVi && ofxRPI4Window::colorspace_on) {
  dv_source_max=cur_op().source_max;
  if(dv_source_max != 255 && dv_source_max != 1023 && dv_source_max != 4095)
   dv_source_max=255;
  dv_source_range=cur_op().source_range;
  dv_source_red=ofClamp(red,0,dv_source_max);
  dv_source_green=ofClamp(green,0,dv_source_max);
  dv_source_blue=ofClamp(blue,0,dv_source_max);
  // Geometry still uses the 8-bit framebuffer. The standard-DV shader
  // consumes the unquantized source integers above and emits packed bytes.
  ofSetColor(255,255,255,255);
  return;
 }
 if (ofxRPI4Window::isHDR && !ofxRPI4Window::isDoVi && !ofxRPI4Window::is_std_DoVi) { 
  if (ofxRPI4Window::bit_depth == 10) ofSet10bitColor(red,green,blue);
  else                                ofSetColor(red,green,blue);
 } else {
  if (ofxRPI4Window::bit_depth == 10) ofSet10bitColor(red,green,blue);
  else                                ofSetColor(red,green,blue);
 }
}

/*
 * A full-range code 0..full as the studio-range (Limited) code of an output
 * whose codes run 0..target_max, rounded once: BT.2100 Table 9,
 * D = Round[(219 x E' + 16) x 2^(n-8)] with E' = value / full.
 */
static int limitedCodeFromFull(int value, int full, int target_max) {
 int shift=(target_max == 1023) ? 2 : 0;
 return (16 << shift) + (int)(((long long)value * (219 << shift) + full / 2) / full);
}

/*
 * A pattern's source code as the code it is drawn with. Full-range codes
 * deeper than an RGB Limited output without the CSC (passthrough) are
 * quantized once, straight into the Limited codes: scaling them to the
 * output depth first and compressing after it rounded twice and moved
 * about one code in five by one. Everything else is scaled to the output
 * depth (scaleSourceToBitDepth), then brought to its range
 * (normalizeSourceValue).
 */
int ofApp::sourceToOutputCode(int value) {
 int source_max=cur_op().source_max;
 int target_max=(ofxRPI4Window::bit_depth == 10) ? 1023 : 255;
 if(value >= 0 && source_max > target_max && cur_op().source_range != 1 &&
    ofxRPI4Window::avi_info.output_format == 0 && ofxRPI4Window::avi_info.rgb_quant_range == 1 &&
    !ofxRPI4Window::isDoVi && !ofxRPI4Window::is_std_DoVi && ofxRPI4Window::rgbLimitedPassthrough()) {
  if(value > source_max)
   value=source_max;
  return limitedCodeFromFull(value,source_max,target_max);
 }
 return normalizeSourceValue(scaleSourceToBitDepth(value),cur_op().source_range);
}

/*
 * SOURCE_MAX codes deeper than the framebuffer (finer Resolve codes, the
 * 12-bit codes of a standard-DV pattern still loaded when the signal
 * switches to SDR/HDR10) are scaled down instead of being clipped: clipping
 * turned patch and background into the same white and showed a full field.
 * Shallower codes are left alone, as before (patterns without SOURCE_MAX
 * default to 255). Dolby Vision keeps its source codes for the tunnel
 * shader.
 */
int ofApp::scaleSourceToBitDepth(int value) {
 if(ofxRPI4Window::is_std_DoVi)
  return value;
 /* Low Latency DV keeps its source codes, except for an 8-bit pattern
    promoted to the 10-bit framebuffer (handled below). */
 if(ofxRPI4Window::isDoVi && !promotedEightBitPattern(cur_op().bits))
  return value;
 int source_max=cur_op().source_max;
 int target_max=(ofxRPI4Window::bit_depth == 10) ? 1023 : 255;
 /* YCbCr is always Limited: a client that asked for Full sends full-range
    codes (SOURCE_RANGE=FULL). The YCbCr shader reads studio-range codes,
    so compress them in the source depth, where 0/max land exactly on
    black/white (8 bit 16/235, 10 bit 64/940, 12 bit 256/3760). */
 if(cur_op().source_range == 2 && ofxRPI4Window::avi_info.output_format != 0 &&
    ofxRPI4Window::avi_info.rgb_quant_range == 1 && value >= 0) {
  /* SOURCE_MAX defaults to 255; BITS=10 codes without it are 0..1023. */
  int full=(source_max == 255 && cur_op().bits == 10) ? 1023 : (source_max > 0 ? source_max : 255);
  if(value > full)
   value=full;
  /* Deeper than the output (finer Resolve codes, 12-bit codes on a 10-bit
     output): one rounding, straight into the output's studio codes.
     Compressing in the source depth and scaling down after it rounded
     twice: 10-bit white 1023 went out as 234 instead of 235 on 8 bit. */
  if(full > target_max)
   return limitedCodeFromFull(value,full,target_max);
  int black=16 * (full + 1) / 256;
  int span=219 * (full + 1) / 256;
  value=black + (int)(((long long)value * span + full / 2) / full);
 }
 /* 8-bit pattern drawn in the 10-bit framebuffer (effectivePatternBits):
    RGB Limited wire codes go out times 4; full-range values take the
    8 -> 10 bit step that keeps 255 at 1023, so the later Limited
    compression lands on the 8 bpc code times 4 as well. */
 if(cur_op().bits == 8 && ofxRPI4Window::bit_depth == 10 && source_max == 255 && value >= 0) {
  if(value > 255)
   value=255;
  if(cur_op().source_range == 1 && ofxRPI4Window::avi_info.output_format == 0 &&
     ofxRPI4Window::avi_info.rgb_quant_range == 1)
   return value << 2;
  /* The YCbCr shader encodes its input as studio-range codes. */
  if(ofxRPI4Window::avi_info.output_format != 0)
   return value << 2;
  return (value * 1023 + 127) / 255;
 }
 if(value < 0 || source_max <= target_max)
  return value;
 /* Studio-range codes (SOURCE_RANGE=LIMITED; on YCbCr also an unset
    range) keep their place in the range: a deeper code is the shallower
    one times 2^(m-n) (BT.2100 Table 9), so divide by that and round.
    10-bit white 940 is 8-bit 235, where the full-range factor 255/1023
    gave 234. */
 if(cur_op().source_range == 1 ||
    (ofxRPI4Window::avi_info.output_format != 0 && cur_op().source_range != 2)) {
  int shift=((source_max == 4095) ? 12 : 10) - ((target_max == 1023) ? 10 : 8);
  int code=(value + (1 << (shift - 1))) >> shift;
  return (code > target_max) ? target_max : code;
 }
 return (value * target_max + source_max / 2) / source_max;
}

int ofApp::normalizeSourceValue(int value, int source_range_mode) {
 if(ofxRPI4Window::avi_info.output_format != 0)
  return value;
 // Standard DV source codes are already the 12-bit values consumed by
 // the tunnel packer. Expanding them here would destroy patch precision.
 if(ofxRPI4Window::isDoVi || ofxRPI4Window::is_std_DoVi)
  return value;
 if(ofxRPI4Window::avi_info.rgb_quant_range != 1)
  return value;
 int bit_depth=ofxRPI4Window::bit_depth ? ofxRPI4Window::bit_depth : 8;
 int shift=bit_depth - 8;
 int limited_min=16 << shift;
 int limited_span=219 << shift;
 int max_value=(1 << bit_depth) - 1;
 /*
  * Passthrough (patched vc4, see ofxRPI4Window::rgbLimitedPassthrough):
  * no CSC after the framebuffer, so SOURCE_RANGE=LIMITED wire codes go out
  * as drawn and full-range sources are compressed here, exactly.
  */
 if(ofxRPI4Window::rgbLimitedPassthrough()) {
  if(source_range_mode == 1)
   return value;
  if(value < 0)
   value=0;
  if(value > max_value)
   value=max_value;
  return limited_min + (int)(((long long)value * limited_span + max_value / 2) / max_value);
 }
 if(source_range_mode != 1)
  return value;
 /*
  * The vc4 HDMI CSC compresses the full-range RGB framebuffer to the
  * configured Limited wire range. SOURCE_RANGE=LIMITED values are wire
  * codes, so expand them to the full framebuffer domain first. Passing
  * code 16 through unchanged would make the CSC output about code 30 and
  * visibly lift black.
  */
 int normalized=(int)(((long long)(value - limited_min) * max_value +
                       limited_span / 2) / limited_span);
 if(normalized < 0)
  normalized=0;
 if(normalized > max_value)
  normalized=max_value;
 return normalized;
}

void ofApp::normalizeImageSourcePixels(int source_range_mode) {
 if(ofxRPI4Window::avi_info.output_format != 0)
  return;
 if(ofxRPI4Window::isDoVi || ofxRPI4Window::is_std_DoVi)
  return;
 if(ofxRPI4Window::avi_info.rgb_quant_range != 1)
  return;
 /* Passthrough: studio-range texels are already wire codes; full-range
    texels are compressed here as vc4 no longer does it. */
 if(ofxRPI4Window::rgbLimitedPassthrough()) {
  if(source_range_mode == 1)
   return;
  if(usesFloatImage()) {
   ofFloatPixels &pixels=float_img.getPixels();
   int channels=pixels.getNumChannels();
   int color_channels=(channels == 2) ? 1 : std::min(3,channels);
   float *data=pixels.getData();
   size_t pixel_count=(size_t)pixels.getWidth() * pixels.getHeight();
   const bool codes10=(cur_op().bits == 10);
   const float black=codes10 ? 64.0f : 16.0f;
   const float span=codes10 ? 876.0f : 219.0f;
   const float top=codes10 ? 1023.0f : 255.0f;
   for(size_t pixel=0;pixel<pixel_count;pixel++) {
    for(int channel=0;channel<color_channels;channel++) {
     float value=ofClamp(data[pixel*channels+channel],0.0f,1.0f);
     data[pixel*channels+channel]=(black + value * span) / top;
    }
   }
   float_img.update();
  } else {
   ofPixels &pixels=img.getPixels();
   int channels=pixels.getNumChannels();
   int color_channels=(channels == 2) ? 1 : std::min(3,channels);
   unsigned char *data=pixels.getData();
   size_t pixel_count=(size_t)pixels.getWidth() * pixels.getHeight();
   for(size_t pixel=0;pixel<pixel_count;pixel++) {
    for(int channel=0;channel<color_channels;channel++) {
     int value=data[pixel*channels+channel];
     data[pixel*channels+channel]=(unsigned char)(16 + (value * 219 + 127) / 255);
    }
   }
   img.update();
  }
  return;
 }
 if(source_range_mode != 1)
  return;

 /*
  * IMAGE textures bypass setColor(), so their studio-range texels need the
  * same expansion as rectangle patches before vc4 applies its framebuffer
  * Full -> wire Limited CSC. Values below 16 and above 235 cannot survive
  * that CSC and are intentionally clamped to framebuffer black/white.
  */
 if(usesFloatImage()) {
  ofFloatPixels &pixels=float_img.getPixels();
  int channels=pixels.getNumChannels();
  int color_channels=(channels == 2) ? 1 : std::min(3,channels);
  float *data=pixels.getData();
  size_t pixel_count=(size_t)pixels.getWidth() * pixels.getHeight();
  // 10-bit plates carry 10-bit codes (64-940); HDR images 8-bit ones.
  const bool codes10=(cur_op().bits == 10);
  const float limited_min=codes10 ? 64.0f / 1023.0f : 16.0f / 255.0f;
  const float limited_scale=codes10 ? 1023.0f / 876.0f : 255.0f / 219.0f;
  for(size_t pixel=0;pixel<pixel_count;pixel++) {
   for(int channel=0;channel<color_channels;channel++) {
    float normalized=(data[pixel*channels+channel] - limited_min) * limited_scale;
    data[pixel*channels+channel]=ofClamp(normalized,0.0f,1.0f);
   }
  }
  float_img.update();
 } else {
  ofPixels &pixels=img.getPixels();
  int channels=pixels.getNumChannels();
  int color_channels=(channels == 2) ? 1 : std::min(3,channels);
  unsigned char *data=pixels.getData();
  size_t pixel_count=(size_t)pixels.getWidth() * pixels.getHeight();
  for(size_t pixel=0;pixel<pixel_count;pixel++) {
   for(int channel=0;channel<color_channels;channel++) {
    int value=data[pixel*channels+channel];
    int normalized=((value - 16) * 255 + 219 / 2) / 219;
    data[pixel*channels+channel]=(unsigned char)ofClamp(normalized,0,255);
   }
  }
  img.update();
 }
}
/*
 ##########################################################
 #                       Shader Begin                     #
 ##########################################################
*/
void ofApp::shader_begin(int is_image) {
 if (!ofxRPI4Window::shader_init && usesRendererShader()) {
  if (is_image) { 
	if (usesFloatImage()) float_img.getTexture().bind();
	else 															         img.getTexture().bind();
  }
  if (ofxRPI4Window::is_std_DoVi && ofxRPI4Window::bit_depth == 10) fbo10.begin();
  if (ofxRPI4Window::is_std_DoVi && ofxRPI4Window::bit_depth == 8) fbo8.begin();  
  ofxRPI4Window::shader.begin();
  if (ofxRPI4Window::is_std_DoVi) {
	/* The window loads dovi_image_shader for IMAGE draws (colorspace_on 0),
	   else dovi_pattern_shader. */
	if (!ofxRPI4Window::colorspace_on) {
		/* dovi_image_shader: 8-bit texels in float32 (one code off PiTPG
		   near the rounding edge, see t/renderer_dovi_metadata.t). */
		ofxRPI4Window::shader.setUniform2f("resolution", ofGetWindowWidth(), ofGetWindowHeight());
		ofxRPI4Window::shader.setUniform1i("dv_full",dv_full);
		ofxRPI4Window::shader.setUniform1i("dv_src_full",doviSourceFull(cur_op().source_range));
		if (ofxRPI4Window::dv_profile == 2) setShaderYCbCrCoeffs(2); //Profile 8.2: BT709
		if (ofxRPI4Window::dv_profile == 1) setShaderYCbCrCoeffs(9); //Profile 8.1: BT2020
	} else {
		/* dovi_pattern_shader: one colour per draw, its tunnel codes in
		   PiTPG's double arithmetic. */
		int bits = dv_source_max == 4095 ? 12 : (dv_source_max == 1023 ? 10 : 8);
		int ycc[3];
		dovi::tunnelCodes(ofxRPI4Window::dv_profile == 1, bits, doviSourceFull(dv_source_range), dv_full,
		                  dv_source_red, dv_source_green, dv_source_blue, ycc);
		ofxRPI4Window::shader.setUniform3i("tunnel_ycc", ycc[0], ycc[1], ycc[2]);
	}

  }	else {
	int scalar1;
	int scalar2;

	// Same colorimetry -> coefficient and range mapping as RGB2YCbCr():
	// No Data takes the CTA-861 default (BT.601 on SD, BT.709 from 720
	// lines; encodeColorimetry), Default range to Limited.
	setShaderYCbCrCoeffs(encodeColorimetry());
	int shift = ofxRPI4Window::bit_depth - 8;
	YCbCrRangeScalars(ofxRPI4Window::bit_depth, ofxRPI4Window::avi_info.rgb_quant_range, scalar1, scalar2);
	int offset = 128 << shift;
	int normalizer = (256 << shift) - 1;
	int scale = normalizer;

	ofxRPI4Window::shader.setUniform1i("scalar1", scalar1);
    ofxRPI4Window::shader.setUniform1i("scalar2", scalar2);
    ofxRPI4Window::shader.setUniform1i("offset", offset);
    ofxRPI4Window::shader.setUniform1i("scale", scale);
    ofxRPI4Window::shader.setUniform1i("normalizer", normalizer);
    ofxRPI4Window::shader.setUniform1i("color_format", ofxRPI4Window::avi_info.output_format);
    ofxRPI4Window::shader.setUniform1i("passthrough_422", usesLowLatencyDoVi422Transport() ? 1 : 0);
    ofxRPI4Window::shader.setUniform1i("rgb_quant_range", ofxRPI4Window::avi_info.rgb_quant_range);
    ofxRPI4Window::shader.setUniform1i("bits", ofxRPI4Window::bit_depth);
    ofxRPI4Window::shader.setUniform1i("is_image", is_image);

  }
 }
} 
/*
 ##########################################################
 #                        Shader End                      #
 ##########################################################
*/
void ofApp::shader_end(int is_image) {
 if (!ofxRPI4Window::shader_init && usesRendererShader()) {
  ofxRPI4Window::shader.end();

  if (is_image) { 
	if (usesFloatImage()) float_img.getTexture().unbind();
    else 															         img.getTexture().unbind();
  }
  if (ofxRPI4Window::is_std_DoVi && ofxRPI4Window::bit_depth == 10) fbo10.end();
  if (ofxRPI4Window::is_std_DoVi && ofxRPI4Window::bit_depth == 8) fbo8.end();
 }		
}

 
void ofApp::YCbCr2RGB(){
	if (ofxRPI4Window::avi_info.output_format != 0) {
		int Y = 0, Cb = 0, Cr = 0;
		//Getting pointer to pixel array of image
		unsigned char *pixels = img.getPixels().getData();
		//Calculate number of pixel components
		int width = img.getPixels().getWidth();
		int height = img.getPixels().getHeight();
		int channels = img.getPixels().getNumChannels();
		//Modify pixel array
		for (int y=0; y<height; y++) {
			for (int x=0; x<width; x++) {
        
				//Read pixel (x,y) color components
				int index = channels * (x + width * y);

				if ( ofxRPI4Window::avi_info.output_format == 1) { //YCbCr444
					Cb = pixels[ index ];
					Cr = pixels[ index + 1 ];
					Y = pixels[ index + 2 ];
				}	
				if ( ofxRPI4Window::avi_info.output_format == 2) { 	//YCbCr422		
					Y = pixels[ index ];
					Cb = pixels[ index + 1 ];
					Cr = pixels[ index + 2 ];
				}

				YCbCr data = YCbCr(Y,Cb,Cr);
				RGB rgb = YCbCrToRGB(data,bits,encodeColorimetry(), ofxRPI4Window::avi_info.rgb_quant_range);
				//Set red 
				pixels[ index ] = rgb.R;
				//Set green 
				pixels[ index + 1 ] = rgb.G;
				//Set blue 
				pixels[ index + 2 ] = rgb.B;
			}
		}
		//Calling img.update() to apply changes
		img.update();
	}
}


int ofApp::dv_map_mode=2;
int ofApp::dv_minpq=62;
int ofApp::dv_maxpq=3696;
int ofApp::dv_diagonal=42;
int ofApp::dv_full=0;

/* How standard-DV source codes are normalised (pitpgd keeps this apart from
   the signal range: dv_ycc12's patch flag is set for patch scale Legal only,
   proto_handle@0x408990). SOURCE_RANGE=FULL (a PiTPG scale other than
   Legal): full-range codes; LIMITED: studio codes; unset (Calman, WebUI,
   port 85): as the signal range, as before. */
int ofApp::doviSourceFull(int source_range) {
 if(source_range == 2) return 1;
 if(source_range == 1) return 0;
 return dv_full ? 1 : 0;
}

/*
 ##########################################################
 #                   DoVi Metadata Packet                 #
 ##########################################################
*/
/* The display-management packet as PiTPG 2.0.3 sends it, with ETSI's L1
   average and a metadata id that steps on each change (dovi_metadata.h):
   container from dv_profile (main.cpp), signal range, source min/max PQ and
   diagonal, and the run mode in an L255 block when it is 1 or 2. */
void ofApp::dovi_packet_set(int run_mode) {
	dovi::Params p;
	p.container_2020 = (ofxRPI4Window::dv_profile == 1) ? 1 : 0;
	p.full = dv_full ? 1 : 0;
	p.min_pq = dv_minpq;
	p.max_pq = dv_maxpq;
	p.diagonal = dv_diagonal;
	unsigned char packet[dovi::packet_bytes];
	dovi::buildPacket(p, run_mode, packet);
	if (!dv_metadata_id.have) {
		// Gone after a daemon restart; if this fails, the save below logs it.
		mkdir(dovi::metadata_id_dir, 0770);
		dv_metadata_id.load(dovi::metadata_id_file);
	}
	int id = dv_metadata_id.next(packet);
	if (!dv_metadata_id.save(dovi::metadata_id_file))
		ofLogError() << "DoVi: cannot save the metadata id to " << dovi::metadata_id_file << ": " << strerror(errno)
		             << " (the next renderer start steps on from the last saved id, or starts at 0)";
	dovi::buildPacket(p, run_mode, packet, id);
	dovi::packetWords(packet, dv_packet_words);
	ofLog() << "DoVi: metadata " << (p.container_2020 ? "BT.2020" : "P3-D65") << " "
	        << (p.full ? "full" : "limited") << " range, PQ " << dovi::normalized(p).min_pq << "/"
	        << dovi::normalized(p).max_pq << ", diagonal " << dovi::normalized(p).diagonal
	        << ", run mode " << dovi::runModeFor(run_mode) << ", payload " << (int)packet[4] << " bytes, metadata id " << id;
}

/*
 ##########################################################
 #                   Create DoVi Metadata                 #
 ##########################################################
*/
void ofApp::dovi_metadata_create() {
	if (ofxRPI4Window::bit_depth == 10) {
		/* The 10-bit buffer carries no metadata bits, as before: its
		   metadata lines stay white. */
		const int meta_lines = doviWindowMetadataLines();
		ofShortPixels short_pix;
		ofShortImage short_img;
		short_pix.allocate(ofGetWindowWidth(), meta_lines, OF_IMAGE_COLOR_ALPHA);
		short_pix.setColor(1023);
		short_img.setFromPixels(short_pix);
		ofSet10bitColor(1023,1023,1023,1023);
		fbo_dovi.begin();
		short_img.getTexture().setTextureMinMagFilter(GL_NEAREST, GL_NEAREST);
		drawDoviMetadataPixels(short_img, ofGetWindowWidth());
		fbo_dovi.end();
		return;
	}

	/* pitpgd dv_embed@0x404870 on the GPU: the frame (fbo8, already the
	   12-bit tunnel packing) is copied pixel for pixel, and in pixels
	   0..3071 in raster order only C[0] (bit 4 of B) changes, so that the
	   XOR of the pixel's 24 tunnel bits equals packet bit (index & 1023),
	   MSB first. The pattern stays visible under the metadata. Mirrored by
	   dovi::embedBit, t/data/dovi_metadata_check.cpp. */
	ofShaderSettings settings;
	settings.shaderSources[GL_VERTEX_SHADER] = R"(
		#version 310 es
		uniform mat4 modelViewProjectionMatrix;
		in vec4 position;
		in vec2 texcoord;
		out vec2 texCoordVarying;
		out vec2 pixelPos;
		void main(){
			texCoordVarying = texcoord;
			pixelPos = position.xy;
			gl_Position = modelViewProjectionMatrix * position;
		}
	)";
	settings.shaderSources[GL_FRAGMENT_SHADER] = R"(
		#version 310 es
		precision highp float;
		precision highp int;
		uniform sampler2D tex0;
		uniform int meta[32];
		uniform int width;
		in vec2 texCoordVarying;
		in vec2 pixelPos;
		out vec4 outputColor;
		void main()
		{
			vec4 c = texture(tex0, texCoordVarying);
			int R = int(round(c.r * 255.0));
			int G = int(round(c.g * 255.0));
			int B = int(round(c.b * 255.0));
			int p = int(floor(pixelPos.y)) * width + int(floor(pixelPos.x));
			if (p >= 0 && p < 3072) {
				int k = p & 1023;
				int bit = (meta[k >> 5] >> (31 - (k & 31))) & 1;
				int y12 = (B & 15) | (G << 4);
				int c12 = (B >> 4) | (R << 4);
				int parity = bitCount(y12 ^ (c12 >> 1)) & 1;
				int c0 = bit ^ parity;
				B = ((c0 | ((B >> 4) & 14)) << 4) | (B & 15);
			}
			outputColor = vec4(float(R) / 255.0, float(G) / 255.0, float(B) / 255.0, 1.0);
		}
	)";
	settings.bindDefaults = true;
	dovi_embed.unload();
	if (!dovi_embed.setup(settings))
		ofLogError() << "DoVi: metadata embedding shader failed to build";

	/* Start sequence (pitpgd dv_show@0x40d2c0): after every mode set with a
	   run mode, the packet goes out without it (no L255 block) for four
	   frames plus 1 ms (67 ms when the refresh rate is unknown), then with
	   it. */
	int run_mode = dovi::runModeFor(dv_map_mode);
	dovi_packet_set(0);
	dv_start_pending = run_mode;
	dv_start_t0 = 0;
	double hz = 0.0;
	ofxRPI4Window *win = dynamic_cast<ofxRPI4Window*>(ofGetWindowPtr());
	if (win && win->mode.htotal && win->mode.vtotal)
		hz = win->mode.clock * 1000.0 / ((double)win->mode.htotal * win->mode.vtotal);
	dv_start_wait_ms = (hz > 1.0) ? (int)(4000.0 / hz) + 1 : 67;
}

/*
 ##########################################################
 #                   Draw DoVi Pattern/Image              #
 ##########################################################
*/
void ofApp::dovi_metadata_mux() {
	if (ofxRPI4Window::bit_depth == 10) {
		ofSetColor(1023,1023,1023,1023); 
		fbo10.draw(0,0,ofGetWindowWidth(),ofGetWindowHeight());
		fbo_dovi.draw(0,0,ofGetWindowWidth(),doviWindowMetadataLines());
		return;
	}
	if (dv_start_pending) {
		uint64_t now = ofGetElapsedTimeMillis();
		if (!dv_start_t0) {
			dv_start_t0 = now ? now : 1;
		} else if (now - dv_start_t0 >= (uint64_t)dv_start_wait_ms) {
			dovi_packet_set(dv_start_pending);
			dv_start_pending = 0;
		}
	}
	ofSetColor(255,255,255,255); 
	dovi_embed.begin();
	dovi_embed.setUniform1iv("meta", dv_packet_words, 32);
	dovi_embed.setUniform1i("width", ofGetWindowWidth());
	fbo8.draw(0,0,ofGetWindowWidth(),ofGetWindowHeight());
	dovi_embed.end();
}



/*
 ##########################################################
 #                   Set DoVi Background                  #
 ##########################################################
*/
void ofApp::setDoViBackground(int redbg, int greenbg, int bluebg) {
	ofApp::setColor(redbg,greenbg,bluebg);
	ofApp::shader_begin(0);

	ofDrawRectangle(0,0,ofGetWindowWidth(),ofGetWindowHeight());

	ofApp::shader_end(0);
}

/*
 ##########################################################
 #                        FBO Allocate                    #
 ##########################################################
*/
void ofApp::fbo_allocate() {
	if (ofxRPI4Window::is_std_DoVi) {
		ofFboSettings settings;
        settings.width                      = ofGetWidth();
        settings.height                     = doviWindowMetadataLines();
        settings.internalformat             = GL_RGBA;
		//set pixel precision
        settings.minFilter                  = GL_NEAREST;
        settings.maxFilter                  = GL_NEAREST;

		//allocate dovi metadata fbo, uses 8bit texture
//		fbo_dovi.allocate(ofGetWindowWidth(),2, GL_RGBA);
		fbo_dovi.allocate(settings);
		fbo_dovi.begin();
		ofClear(0,0,0,0);
		fbo_dovi.end();

		if (ofxRPI4Window::bit_depth == 10) {
			//allocate 10bit fbo
			settings.height 					= ofGetWindowHeight();
			settings.internalformat             = GL_RGB10_A2;
			//fbo10.allocate(ofGetWindowWidth(),ofGetWindowHeight(), GL_RGB10_A2);
			fbo10.allocate(settings);
			fbo10.begin();
			ofClear10bit(0,0,0,0);
			fbo10.end();
		} else {
			//allocate 8bit fbo
			settings.height = ofGetWindowHeight();
			fbo8.allocate(settings);
	//		fbo8.allocate(ofGetWindowWidth(),ofGetWindowHeight(), GL_RGBA);
			fbo8.begin();
			ofClear(0,0,0,0);
			fbo8.end();
		}
	}
}

/*
 ##########################################################
 #                        Old Routines                    #
 ##########################################################
*/



#if 0
void ofApp::dovi_dump() {
		int Y=0, Cb=0, Cr=0;
		//Getting pointer to pixel array of image
		unsigned char *pixels = img.getPixels().getData();
		//Calculate number of pixel components
		int width = img.getPixels().getWidth();
		int height = img.getPixels().getHeight();
		int channels = img.getPixels().getNumChannels();
		int num_bits=0;
		int hex_num=0;

		unsigned char mask = 1; // Bit mask
		unsigned char bits[8];
		unsigned char total_y0_bits[1920] = {0};
		unsigned char total_y1_bits[1920] = {0};
//		int i, j = CHAR_BIT-1;
//		int n = sizeof(byte)/sizeof(byte[0]);

		for (int y=0; y<height; y++) {
			num_bits=0;
			for (int x=0; x<width; x++) {
        
				//Read pixel (x,y) color components
				int index = channels * (x + width * y);
					num_bits++;
					Y = pixels[ index ];
					Cb = pixels[ index + 1 ];
					Cr = pixels[ index + 2 ];
					if (y==0) { 
						printf("posx=%d posy=%d  Before: Y %d ,Cb %d , Cr %d \n",x, y, Y, Cb, Cr);
						
						if (Cr == 16) {
						  total_y0_bits[x] = 1;
						} 
						if (Cr == 0) {
						  total_y0_bits[x] = 0;
						}

					}
					if (y==1) { 
						printf("posx=%d posy=%d  Before: Y %d ,Cb %d , Cr %d \n",x, y, Y, Cb, Cr);
						
						if (Cr == 16) {
						  total_y1_bits[x] = 1;
						} 
						if (Cr == 0) {
						  total_y1_bits[x] = 0;
						}

					}
					

			}	
		}
		printf("Y0 ");
		for ( int x=0; x < num_bits;x+=8) {
			for (int i=0; i < 8; i++) {
			   
				hex_num = (hex_num<<1)|total_y0_bits[i+x];
			   

			}
			printf("0x%02x, ", hex_num);
			hex_num=0;

		}
		puts("");
		printf("Y1 ");
		for ( int x=0; x < num_bits;x+=8) {
			for (int i=0;i < 8; i++) {
				hex_num = (hex_num<<1)|total_y1_bits[i+x];

			}
			printf("0x%02x, ", hex_num);
			hex_num=0;


		}
		puts("");

}
#endif 
#if 0
void ofApp::dovi_rpu_inject() {
	if (ofxRPI4Window::avi_info.rgb_quant_range == 1 && ofxRPI4Window::avi_info.output_format == 2) {
		int Y=0, Cb=0, Cr=0;
		//Getting pointer to pixel array of image
		unsigned char *pixels = img.getPixels().getData();
		//Calculate number of pixel components
		int width = img.getPixels().getWidth();
		int height = img.getPixels().getHeight();
		int channels = img.getPixels().getNumChannels();
		int num_bits=0;
		unsigned char byte[] = {0x00,0x00,0x00,0x01,0x19,0x08,0x09,0x00,0x40,0x61,0xb6,0x50,0x6f,0x00,0x3f,0xf8,0x01,0xff,
								0xc0,0x0f,0xff,0xd0,0x00,0x00,0x10,0x00,0x00,0x1b,0x00,0x00,0x03,0x02,0x00,0x00,0x03,0x03,
								0x60,0x00,0x00,0x40,0x00,0x00,0x68,0x80,0x00,0x0c,0x7c,0x1a,0x44,0x80,0x03,0xf1,0x6c,0x11,
								0x0c,0x80,0x00,0x04,0x2f,0xa9,0x5c,0x00,0x00,0x03,0x00,0x00,0x20,0x00,0x00,0x03,0x00,0x20,
								0x00,0x00,0x03,0x01,0x0a,0xe7,0xfa,0x8f,0xfa,0x8f,0xfa,0x8d,0x0a,0xe7,0xfa,0x8f,0xfa,0x8f,
								0xfa,0x8d,0x0a,0xe7,0xff,0xfc,0x00,0x00,0x03,0x00,0x00,0x03,0x00,0x00,0x03,0x00,0x01,0x90,
								0x81,0xf7,0x38,0x05,0x45,0x30,0x08,0x01,0x3c,0x80,0x8c,0x00,0xc0,0x28,0x21,0x22,0x98,0x00,
								0x80,0x08,0x00,0x80,0x01,0x00,0x02,0x02,0x00,0x00,0x03,0x00,0x09,0x06,0x0f,0xa0,0x00,0x32,
								0x00,0x00,0x03,0x00,0x00,0x46,0xf1,0x99,0x5c,0x80 };

		unsigned char mask = 1; // Bit mask
		unsigned char bits[8];
		unsigned char total_bits[1500] = {0};
		int i, j = CHAR_BIT-1;
		int n = sizeof(byte)/sizeof(byte[0]);

		// Extract the bits
		for (int k=0; k < n; k++) {
			printf("byte 0x%02x : ",byte[k]);
			for ( i = 0; i < 8; i++,j--,mask = 1) {
			// Mask each bit in the byte and store it
				bits[i] =( byte[k] & (mask<<=j))  !=0;

				printf("%d", bits[i]);
				total_bits[num_bits] = bits[i];
				num_bits++;
			}

			puts("");
			j = CHAR_BIT-1;

		}
		printf("Total number of bits %d\n",num_bits);
		int z=0;
		for (int y=0; y<height; y++) {
			for (int x=0; x<width; x++) {
        
				//Read pixel (x,y) color components
				int index = channels * (x + width * y);
				
					Y = pixels[ index ];
					Cb = pixels[ index + 1 ];
					Cr = pixels[ index + 2 ];

					if (index == 0) { //set metadata identifier to 0b00, single packet contains all DM metadata
					//	printf("z=%d Before: Y %d ,Cb %d , Cr %d ",z, Y, Cb, Cr);

						Cb &= 0x3fe;
						Cr &= 0x3fe;
						printf("..");
					}
					if ((z <= num_bits) && (index >= 0)) {
					//	printf("z=%d Before: Y %d ,Cb %d , Cr %d ",z, Y, Cb, Cr);

						if (z % 2 == 0) {
							//printf(" even ");
							if (total_bits[z] == 0) {
								Cb &= 0x3fe;
							//	Cb = 
								printf(".");
							} else {
								Cb |= 1;
								printf("^");
							}
						}else{
							//printf(" odd ");
							if (total_bits[z] == 0) {
								Cr &= 0x3fe;
								printf(".");
							} else {
								Cr |= 1;
								printf("^");
							}
						}
		//		printf("==> After: Y %d ,Cb %d , Cr %d \n",Y, Cb, Cr);
						z++;
						
					pixels[ index + 1 ] = Cb;
					pixels[ index + 2 ] = Cr;
					}

			}
		}
puts("");
	}

	//Calling img.update() to apply changes
	img.update();

}


#endif
