/*
 * Copyright (c) 2021-2022 Juan Francisco Loya
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

class RGB
{
public:
	int R;
	int G;
	int B;

	RGB(int r, int g, int b)
	{
		R = r;// * 0.8588235 + 16.0;
		G = g;// * 0.8588235 + 16.0;
		B = b;// * 0.8588235 + 16.0;
//		R = r * 0.856305 + 16.0 << (bits - 8);
//		G = g * 0.856305 + 16.0 << (bits - 8);
//		B = b * 0.856305 + 16.0 << (bits - 8);
	}

	bool Equals(RGB rgb)
	{
		return (R == rgb.R) && (G == rgb.G) && (B == rgb.B);
	}
};

class YCbCr
{
public:
	float Y;
	float Cb;
	float Cr;


	YCbCr(float y, float cb, float cr)
	{
		Y = y;
		Cb = cb;
		Cr = cr;
	}

	bool Equals(YCbCr ycbcr)
	{
		return (Y == ycbcr.Y) && (Cb == ycbcr.Cb) && (Cr == ycbcr.Cr);
	}
};

/*
 * Luma/chroma coefficients for an AVI colorimetry value (DRM "Colorimetry"
 * connector enum as passed through map_kms_colorspace). d = 2*(1-Kb),
 * e = 2*(1-Kr).
 *   9 BT2020_RGB / 10 BT2020_YCC              -> BT.2020
 *   1 SMPTE_170M_YCC, 3 XVYCC_601, 5 SYCC_601,
 *   6 OPYCC_601                                -> BT.601
 *   everything else (0 Default, 2 BT709_YCC)   -> BT.709 (HD/UHD default)
 */
struct YCbCrCoeffs
{
	float Kr;
	float Kg;
	float Kb;
	float d;
	float e;
};

static inline YCbCrCoeffs YCbCrCoeffsForColorimetry(int colorimetry) {
	if (colorimetry == 9 || colorimetry == 10) {
		YCbCrCoeffs bt2020 = { 0.2627f, 0.6780f, 0.0593f, 1.8814f, 1.4746f };
		return bt2020;
	}
	if (colorimetry == 1 || colorimetry == 3 || colorimetry == 5 || colorimetry == 6) {
		YCbCrCoeffs bt601 = { 0.299f, 0.587f, 0.114f, 1.772f, 1.402f };
		return bt601;
	}
	YCbCrCoeffs bt709 = { 0.2126f, 0.7152f, 0.0722f, 1.8556f, 1.5748f };
	return bt709;
}

/*
 * Chroma scale for the YCbCr encode. HDMI YCbCr defaults to limited range,
 * so rgb_quant_range 0 (Default) behaves like 1 (Limited); only 2 is Full.
 */
static inline void YCbCrRangeScalars(int bits, int rgb_quant_range, int &scalar1, int &scalar2) {
	if (rgb_quant_range == 2) {
		scalar1 = 256 << (bits - 8);
		scalar2 = 255 << (bits - 8);
	} else {
		scalar1 = 224 << (bits - 8);
		scalar2 = 219 << (bits - 8);
	}
}

static YCbCr RGB2YCbCr(RGB rgb, int bits, int colorimetry, int rgb_quant_range) {
	YCbCrCoeffs k = YCbCrCoeffsForColorimetry(colorimetry);
	/* Full range 0-255: 256/255, Studio range: 256/219, Limited range: 224/219 */
	int scalar1;
	int scalar2;
	YCbCrRangeScalars(bits, rgb_quant_range, scalar1, scalar2);
	int offset = 128 << (bits - 8);
	int R, G, B;
	float d = k.d, e = k.e;
	
	// Pattern values already arrive in the active draw depth selected by BITS.
	R = rgb.R;
	G = rgb.G;
	B = rgb.B;	
//	if (bits == 8) {
//		R = R * 0.85588235 + 16;
//		G = G * 0.85588235 + 16;
//		B = B * 0.85588235 + 16;
//	} 
//	if (bits == 10) {
//		R = R * 0.856305 + 64;
//		G = G * 0.856305 + 64;
//		B = B * 0.856305 + 64;
//	}	
	int Y = std::round((k.Kr * R + k.Kg* G + k.Kb * B));
	int Cb = std::round(((-k.Kr/d) * R - (k.Kg/d) * G + ((d/2)/d) * B)*scalar1/scalar2 + offset); // Chrominance Blue
	int Cr = std::round((((e/2)/e) * R - (k.Kg/e) * G - (k.Kb/e) * B)*scalar1/scalar2 + offset); // Chrominance Red

	return YCbCr(Y, Cb, Cr); 
}

static RGB YCbCrToRGB(YCbCr ycbcr, int bits, int colorimetry, int rgb_quant_range) {
	YCbCrCoeffs k = YCbCrCoeffsForColorimetry(colorimetry);
	/* Full range 0-255: 256/255, Studio range: 256/219, Limited range: 224/219 */
	int scalar1;
	int scalar2;
	YCbCrRangeScalars(bits, rgb_quant_range, scalar1, scalar2);
	int offset = 128 << (bits - 8);
	float d = k.d, e = k.e;
	float r = ycbcr.Y + (ycbcr.Cr - offset) * scalar2/scalar1 * e;
	float g = ycbcr.Y + (ycbcr.Cb - offset) * scalar2/scalar1 * -k.Kb*d/k.Kg + (ycbcr.Cr - offset) * scalar2/scalar1 * -k.Kr*e/k.Kg;
	float b = ycbcr.Y + (ycbcr.Cb - offset) * scalar2/scalar1 * d;

	return RGB((int)r, (int)g, (int)b);
}