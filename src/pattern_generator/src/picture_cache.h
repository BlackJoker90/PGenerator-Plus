#ifndef PGEN_PICTURE_CACHE_H
#define PGEN_PICTURE_CACHE_H
/*
 * Which picture ofApp::image() holds, and what a draw has to do for it.
 * Free of openFrameworks so it can be built and tested on its own (the
 * maintainer's t/renderer_picture_cache.t).
 *
 * A picture is held twice: its pixels in memory (decoded from the file,
 * rotated, and rewritten by normalizeImageSourcePixels for the range of the
 * output) and the texture made from them.
 *
 * - The texture goes with every window setup: ofxRPI4Window::DestroyWindow
 *   destroys the EGL context. The pixels stay, so the texture is made from
 *   them again (UPLOAD), without reading the file, in the window's first
 *   draw: the frame before stays on screen until that flip.
 * - The pixels are another picture's when the path, the rotation, the
 *   texture kind (8 bit / float) or the normalization differs: the file is
 *   read (LOAD). The normalization, not the SOURCE_RANGE line: what was done
 *   to the texels (ofApp::imageNormalization), which also changes with the
 *   output while the line stays.
 * - While the daemon waits for the first flip after a signal change taken
 *   in place (SIGHUP; 3 s, command.pm renderer_reconfigure_in_place), a
 *   file is not read for pixels other than the ones held: the draw leaves
 *   the picture out (LATER) and the next one reads it. Reading takes 0.6 s
 *   at 1080p and 4 s at 2160p on the Pi 4; making the texture 0.05 to
 *   0.5 s, 1.5 s for a float texture at 2160p (read 2026-11-15). Unless
 *   the pattern is new: its first flip (running/presented) says the
 *   picture is on screen. The picture held is never left out, and a window
 *   the renderer sets up by itself (the pattern's bit depth, standard
 *   Dolby Vision) is not waited for: nothing is left out there.
 *
 * Before, the path alone decided: a picture stayed dark after a signal
 * change taken in place until another path came, and a picture asked for
 * again with another SOURCE_RANGE kept the texels of its first load.
 *
 * The first picture after a pattern without one is read at two draws ("to
 * allow time to load shader", as before), any other change at one, as
 * before. A window setup between the two (a picture whose BITS are not the
 * window's: the setup follows in the next frame) makes the texture from
 * the pixels of the first read instead, and a draw the daemon waits for
 * does without the second read.
 */
#include <string>

struct PictureCache {
 enum { HELD=0, LOAD=1, UPLOAD=2, LATER=3 };

 std::string path;
 int rotate=0;
 int normalization=0;
 bool float_texture=false;
 unsigned long window=0; // the window last drawn in
 bool held=false;
 int loads=0;

 /* A pattern without a picture is drawn: the next picture is a first
    one. */
 void forget() {
  held=false;
  path.clear();
  loads=0;
 }

 /* The 8-bit image's pixels and texture were replaced by something else
    (ofApp::grabFrameForSave grabs the screen into it for a saved frame):
    an 8-bit picture held there is gone, its next draw reads the file once
    (loads stays, so not twice). A float picture lives in its own image and
    stays held. */
 void eightBitImageReplaced() {
  if(!float_texture)
   held=false;
 }

 /* Once per draw of a picture: what this draw has to do before it.
    fresh: the pattern was read since the last draw of a picture.
    awaited: the daemon waits for the flip of this draw. */
 int needs(const std::string &p, int rot, int norm, bool is_float, bool fresh, bool awaited, unsigned long win) {
  bool same=held && p == path && rot == rotate && norm == normalization && is_float == float_texture;
  bool new_window=win != window;
  if(!same && awaited && !fresh)
   return LATER;
  bool read=!same || (loads < 2 && !new_window && !awaited);
  held=true;
  path=p;
  rotate=rot;
  normalization=norm;
  float_texture=is_float;
  window=win;
  if(loads < 2)
   loads++;
  if(read)
   return LOAD;
  return new_window ? UPLOAD : HELD;
 }
};

#endif
