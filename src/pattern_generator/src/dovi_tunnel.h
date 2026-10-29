#pragma once

#include <cstddef>

// Standard Dolby Vision metadata tunnel (ETSI GS CCM 001 V1.1.1, 6.4.1 and
// 6.4.3): the 1024-bit packet three times, one bit per pixel in raster order
// from pixel 0, i.e. pixels 0..3071 over as many top lines as the width needs
// (2 at 1920, 1 at 3840, 3 at 1280). Every other pixel keeps the picture.
// Built on the Mac under ASan/UBSan by t/renderer_dovi_tunnel.t.

const int dovi_metadata_pixels = 3 * 1024;

// Top lines the metadata pixels take at this width.
inline int doviMetadataLines(int width) {
	return width > 0 ? (dovi_metadata_pixels + width - 1) / width : 2;
}

// Draws exactly the metadata pixels of a doviMetadataLines(width) x width
// image: full lines, then the rest of the last one.
template <class Image> void drawDoviMetadataPixels(Image &image, int width) {
	if (width <= 0) return;
	int left = dovi_metadata_pixels;
	for (int line = 0; left > 0; line++, left -= width)
		image.drawSubsection(0, line, left < width ? left : width, 1, 0, line);
}

// Writes the tunnel codes into an 8-bit, 4-channel (Y, Cb, Cr, A) buffer of
// width x lines pixels: pixel p carries bit p % 1024 of bits[] as Y 128,
// Cb 16, Cr 16 (1) or 0 (0), the codes of PGenerator 1.6. Alpha and the
// pixels after 3071 are left alone. Returns the number of pixels written.
inline int doviFillTunnel8(unsigned char *data, int width, int lines, const unsigned char *bits) {
	if (!data || !bits || width <= 0 || lines <= 0) return 0;
	const long long room = (long long)width * lines;
	const int n = room < dovi_metadata_pixels ? (int)room : dovi_metadata_pixels;
	for (int p = 0; p < n; p++) {
		unsigned char *px = data + (size_t)p * 4;
		px[0] = 128;
		px[1] = 16;
		px[2] = bits[p % 1024] ? 16 : 0;
	}
	return n;
}
