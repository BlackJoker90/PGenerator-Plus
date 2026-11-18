#pragma once

#include <cmath>
#include <cstdint>
#include <cstring>
#include <cstdio>

// Standard (TV-led) Dolby Vision display-management packet in three forms
// (Params::form, below). PiTPG's form is built the way PiTPG 2.0.3 builds it
// (pitpgd dv_md_build@0x4043e0, dv_packet@0x4045f0,
// pq12@0x40d530; REA/Ghidra ev_7183b908, ev_2b3bb6bd). Field layout: ETSI GS
// CCM 001 V1.1.1, 6.2. Built on the Mac under ASan/UBSan by
// t/renderer_dovi_metadata.t.
// One departure from pitpgd, to ETSI GS CCM 001 V1.1.1: the L1 average
// is the value a sink infers without L1, (source_min_PQ + source_max_PQ) / 2
// (6.2.2; pitpgd sends min + (max - min) / 3, a scene statistic no pattern
// has). Header byte 1, the metadata ids, is 0 in every form, as PGenerator
// 1.6, Calman's generator packet and pitpgd send it; ETSI GS CCM 001 6.3.1
// asks for an id that steps when the metadata change (maintainer's choice of
// 1.6 over 6.3.1, 2026-11-17; for PiTPG's form too, 2026-11-18).
//
// The packet is 128 bytes: header bytes 0..2 (byte 1 the metadata ids), the
// payload length as u16 BE in 3..4, the payload, zeros, and the
// CRC-32/MPEG-2 of bytes 0..123 big-endian in 124..127.
// Payload (offsets in the payload):
//    0..1   0
//    2..19  ycc_to_rgb matrix, 9 x int16 BE (scale 1/8192)
//   20..31  ycc_to_rgb offsets, 3 x u32 BE: Y 0x01000000 limited / 0 full,
//           Cb, Cr 0x08000000
//   32..49  rgb_to_lms matrix, 9 x int16 BE
//   50..63  FF FF 00 00 00 00 00 00 00 00 0C 00 01 01
//   64..69  source min PQ, max PQ, diagonal (u16 BE)
//   70      number of extension blocks: 2, or 3 with a run mode
//   71..81  L1: 00 00 00 06 01 min max avg, avg = (min + max) / 2
//   82..90  L4: 00 00 00 04 04 0F FF 0F FF
//   91..101 L255 (run mode 1 or 2 only): 00 00 00 06 FF run 00 00 00 00 00
// Length 91 (0x5B) without the L255 block, 102 (0x66) with it.
//
// Three forms (Params::form). PiTPG's (form_pitpg, a PiTPG client) is the
// layout above. Calman's (form_calman, a Calman session) and PGenerator
// 1.6's (form_pg16, every other session) leave out the L4 block:
//   70      number of extension blocks: 1, or 2 with the L255 block
//   71..81  L1 as above
//   82..92  L255: 00 00 00 06 FF run 00 00 00 00 00
// Length 82 (0x52) without the L255 block, 93 (0x5D) with it. Calman's form
// sends L255 only with a run mode (Perceptual without it), 1.6's always
// (run 0 in Perceptual). In all three forms the metadata id stays 0 also
// when the metadata change (a mode switch), as 1.6, Calman and pitpgd send
// it, where ETSI GS CCM 001 6.3.1 asks for a step: a departure from the
// standard, kept on purpose. Byte numbers below are packet bytes (payload
// offset + 5).
//
// Calman's form: the packet Calman itself
// hands a Murideo 6G/7G or VideoForge Pro generator. calmanv5.dll (5.17,
// sha256 19cc7538...) holds one per mode in .data (0x10a6ec18 Perceptual,
// 0x10a6ec98 Absolute, 0x10a6ed18 Relative) and copies it whole into the
// generator (functions 0x10689030 and 0x1068c0e0): no L4 block, metadata id
// 0. One byte is not taken over: Calman's Relative packet carries
// signal_color_space 1, a reserved value (ETSI GS CCM 001 V1.1.1 table 6:
// 0 YCbCr, 2 ICtCp, 1 and 3 reserved); this form sends 0 (YCbCr) in every
// mode, as PGenerator 1.6 does (dv_color_space, shipped 0). 1.6's template is
// Calman's Relative packet, but 1.6 rewrites byte 66 from conf
// dv_color_space (shipped 0) and always sends the L255 block (byte 92 from
// dv_map_mode): Absolute and Relative of this form are 1.6's packets.
//
// 1.6's form: what PGenerator 1.6 sends for the same container, run mode
// and mastering values, dv_color_space as shipped (PGeneratord
// sha256 5882ec1b..., ofApp::dovi_metadata_update 0x70dc8: the template of
// the container, 0x1c218c P3-D65 or 0x1c220c BT.2020, with byte 66 from
// dv_color_space 0, 69..74 and the L1 81..86 from the conf, byte 92 the run
// mode, and its CRC). 1.6 rewrites it only when those conf values change
// (dovi_metadata_update's one call is in dovi_metadata_create, 0x72b3c): no
// start sequence.

namespace dovi {

// pitpgd's tables (2.0.3 .rodata 0x493290..0x493340), as int16.
static const int16_t ycc_to_rgb_709[9]       = { 9574, 0, 14739, 9574, -1753, -4382, 9574, 17369, 0 };
static const int16_t ycc_to_rgb_709_full[9]  = { 8192, 0, 12901, 8192, -1535, -3835, 8192, 15201, 0 };
static const int16_t ycc_to_rgb_2020[9]      = { 9574, 0, 13802, 9574, -1540, -5348, 9574, 17610, 0 };
static const int16_t ycc_to_rgb_2020_full[9] = { 8192, 0, 12080, 8192, -1348, -4681, 8192, 15412, 0 };
static const int16_t rgb_to_lms_p3[9]        = { 5845, 9702, 837, 2568, 12256, 1561, 0, 679, 15705 };
static const int16_t rgb_to_lms_2020[9]      = { 7222, 8771, 390, 2654, 12430, 1300, 0, 422, 15962 };

const int packet_bytes = 128;
const int form_pitpg = 0;
const int form_calman = 1;
const int form_pg16 = 2;
const int payload_max = 0x66;

struct Params {
	int container_2020; // 1: BT.2020 container (BT.2020 matrices), 0: P3-D65 (BT.709 matrices)
	int full;           // 1: full-range tunnel signal, 0: limited
	int min_pq;         // source display min, 12-bit PQ
	int max_pq;         // source display max, 12-bit PQ
	int diagonal;       // source display diagonal, inches
	int form;           // form_pitpg, form_calman or form_pg16 (see above)
};

// pitpgd pq12: nits -> 12-bit PQ code (ST 2084), 0 for nits <= 0.
inline int pq12(double nits) {
	double y = nits / 10000.0;
	if (!(y > 0.0)) return 0;
	if (y > 1.0) y = 1.0;
	double p = std::pow(y, 0.1593017578125);
	double v = std::pow((p * 18.8515625 + 0.8359375) / (p * 18.6875 + 1.0), 78.84375);
	return (int)(v * 4095.0 + 0.5);
}

// The run mode the metadata carries: dv_map_mode 1 or 2, else none (0), as
// pitpgd apply_now.
inline int runModeFor(int map_mode) {
	return (map_mode == 1 || map_mode == 2) ? map_mode : 0;
}

// The start sequence after a mode set (pitpgd dv_show@0x40d2c0): the run
// mode the first packet carries, and the one it switches to four frames
// later (0: no switch). PiTPG's form starts without the run mode; Calman's
// and 1.6's carry it at once (Calman hands it its generator so, 1.6 rewrites
// its packet, run mode included, only when its conf values change).
inline void startSequence(int run_mode, int form, int *first, int *pending) {
	*first = (form == form_pitpg) ? 0 : run_mode;
	*pending = (form == form_pitpg) ? run_mode : 0;
}

// pitpgd apply_now: max PQ not below min PQ, diagonal at most 1023. The PQ
// values are 12-bit codes (the protocol and the conf take 0..4095); out of
// that range they are clamped here.
inline Params normalized(Params p) {
	if (p.min_pq < 0) p.min_pq = 0;
	if (p.min_pq > 4095) p.min_pq = 4095;
	if (p.max_pq < 0) p.max_pq = 0;
	if (p.max_pq > 4095) p.max_pq = 4095;
	if (p.max_pq < p.min_pq) p.max_pq = p.min_pq;
	if (p.diagonal > 1023) p.diagonal = 1023;
	if (p.diagonal < 0) p.diagonal = 0;
	return p;
}

inline void put16(unsigned char *d, int v) {
	d[0] = (unsigned char)((v >> 8) & 0xff);
	d[1] = (unsigned char)(v & 0xff);
}

// The payload; returns its length (PiTPG's form 0x5B or 0x66; Calman's 0x52
// or 0x5D; 1.6's 0x5D).
inline int buildPayload(const Params &in, int run_mode, unsigned char *p) {
	Params m = normalized(in);
	run_mode = runModeFor(run_mode);
	memset(p, 0, payload_max);
	const int16_t *ycc = m.container_2020 ? (m.full ? ycc_to_rgb_2020_full : ycc_to_rgb_2020)
	                                      : (m.full ? ycc_to_rgb_709_full : ycc_to_rgb_709);
	const int16_t *lms = m.container_2020 ? rgb_to_lms_2020 : rgb_to_lms_p3;
	for (int i = 0; i < 9; i++) put16(p + 2 + 2 * i, (uint16_t)ycc[i]);
	p[20] = m.full ? 0 : 1;
	p[24] = 0x08;
	p[28] = 0x08;
	for (int i = 0; i < 9; i++) put16(p + 32 + 2 * i, (uint16_t)lms[i]);
	p[50] = 0xff;
	p[51] = 0xff;
	p[60] = 0x0c;
	p[62] = 0x01;
	p[63] = 0x01;
	put16(p + 64, m.min_pq);
	put16(p + 66, m.max_pq);
	put16(p + 68, m.diagonal);
	p[74] = 0x06;
	p[75] = 0x01;
	put16(p + 76, m.min_pq);
	put16(p + 78, m.max_pq);
	put16(p + 80, (m.min_pq + m.max_pq) / 2);
	if (m.form == form_calman || m.form == form_pg16) {
		const bool l255 = run_mode || m.form == form_pg16;
		p[70] = l255 ? 2 : 1;
		if (!l255) return 0x52;
		p[85] = 0x06;
		p[86] = 0xff;
		p[87] = (unsigned char)run_mode;
		return 0x5d;
	}
	p[70] = run_mode ? 3 : 2;
	p[85] = 0x04;
	p[86] = 0x04;
	p[87] = 0x0f;
	p[88] = 0xff;
	p[89] = 0x0f;
	p[90] = 0xff;
	if (!run_mode) return 0x5b;
	p[94] = 0x06;
	p[95] = 0xff;
	p[96] = (unsigned char)run_mode;
	return 0x66;
}

// CRC-32/MPEG-2: poly 0x04C11DB7, init 0xFFFFFFFF, MSB first, no final XOR.
inline uint32_t crc32mpeg(const unsigned char *d, size_t n) {
	uint32_t c = 0xffffffffu;
	for (size_t i = 0; i < n; i++) {
		c ^= (uint32_t)d[i] << 24;
		for (int b = 0; b < 8; b++) c = (c & 0x80000000u) ? (c << 1) ^ 0x04c11db7u : (c << 1);
	}
	return c;
}

// The whole 128-byte packet (pitpgd dv_packet), metadata ids (byte 1) 0.
inline void buildPacket(const Params &in, int run_mode, unsigned char *out) {
	unsigned char payload[payload_max];
	int len = buildPayload(in, run_mode, payload);
	memset(out, 0, packet_bytes);
	out[4] = (unsigned char)len;
	memcpy(out + 5, payload, len);
	uint32_t crc = crc32mpeg(out, 124);
	out[124] = (unsigned char)(crc >> 24);
	out[125] = (unsigned char)(crc >> 16);
	out[126] = (unsigned char)(crc >> 8);
	out[127] = (unsigned char)crc;
}

// The 1024 packet bits MSB first as 32 words, bit i = word[i / 32] bit
// 31 - i % 32 (for the embedding shader).
inline void packetWords(const unsigned char *packet, int32_t *words) {
	for (int w = 0; w < 32; w++) {
		uint32_t v = 0;
		for (int b = 0; b < 4; b++) v = (v << 8) | packet[w * 4 + b];
		words[w] = (int32_t)v;
	}
}

// pitpgd dv_embed@0x404870 on one XRGB8888 tunnel pixel: the low chroma bit
// (bit 4 of B, C[0]) is set so that the XOR of all 24 tunnel bits (Y[11:0]
// and C[11:0]) equals the metadata bit. Y and C[11:1] are kept.
inline uint32_t embedBit(uint32_t px, int bit) {
	uint32_t y12 = (px & 0xf) | ((px & 0xff00) >> 4);
	uint32_t c12 = ((px >> 4) & 0xf) | ((px & 0xff0000) >> 12);
	uint32_t v = y12 ^ (c12 >> 1);
	int parity = 0;
	for (; v; v &= v - 1) parity ^= 1;
	uint32_t c0 = (uint32_t)((bit & 1) ^ parity);
	return (((c0 | ((px >> 4) & 0xe)) << 4) | (px & 0xff0000) | (px & 0xff00000f) | (px & 0xff00));
}

// The metadata bit pixel i (0..3071) carries: bit i % 1024 of the packet,
// MSB first.
inline int packetBit(const unsigned char *packet, int i) {
	int k = i & 1023;
	return (packet[k >> 3] >> (7 - (k & 7))) & 1;
}

// pitpgd dv_ycc12@0x404790 / dv_ycc12n@0x4046a0 / dv_code12@0x404810 (REA
// ev_9724be19, ev_c64293f6): source codes of depth bits (8, 10, 12) to the
// 12-bit tunnel Y, Cb, Cr, in double as PiTPG computes them. Two separate
// flags, as in pitpgd: src_full picks how the source codes are normalised
// (pitpgd's patch flag, proto_handle@0x408990: limited only for patch scale
// Legal; c / (2^b - 1) otherwise), full the signal range (pitpgd's global
// dv_full, dv_show@0x40d2c0: patch scale Full). Limited signal: Y = 3504Y'
// + 256, C = 3584(B'-Y') / d + 2048, codes 16..4079; full: Y = 4095Y',
// C = 4095(..) / d + 2048, codes 0..4095; rounding (long)(x + 0.5).
// Against PGenerator 1.6 (PGeneratord sha256 5882ec1b..., its tunnel shader
// text with the uniforms ofApp::shader_begin sets: BT.2020 luma weights for
// dv_profile 1, BT.709 for 2, in float32), recomputed on the CPU for every
// 8-bit colour: inside 16..235 Y is the same and Cb or Cr one code apart for
// 2942 (BT.2020) and 2421 (BT.709) of the 220^3 colours (0.02-0.03 %; 2880
// and 2346 with fused multiply-adds), where the exact value lies within
// float32 error of .5. Outside 16..235 the clamp below is pitpgd's; 1.6's
// shader has none. So this arithmetic serves PiTPG sessions only: elsewhere
// the renderer computes 1.6's tunnel exactly (pg16Codes below).
inline long code12(double x, int full) {
	long hi = full ? 4095 : 4079, lo = full ? 0 : 16;
	long v = (long)(x + 0.5);
	return v < lo ? lo : (v > hi ? hi : v);
}

inline void tunnelCodes(int container_2020, int bits, int src_full, int full, int r, int g, int b, int *ycc) {
	if (bits != 10 && bits != 12) bits = 8;
	int maxc = (1 << bits) - 1;
	r = r < 0 ? 0 : (r > maxc ? maxc : r);
	g = g < 0 ? 0 : (g > maxc ? maxc : g);
	b = b < 0 ? 0 : (b > maxc ? maxc : b);
	double off = src_full ? 0.0 : (double)(16 << (bits - 8));
	double span = src_full ? (double)maxc : (double)(219 << (bits - 8));
	double R = ((double)r - off) / span, G = ((double)g - off) / span, B = ((double)b - off) / span;
	double kr = container_2020 ? 0.2627 : 0.2126, kb = container_2020 ? 0.0593 : 0.0722;
	double d = container_2020 ? 1.8814 : 1.8556, e = container_2020 ? 1.4746000000000001 : 1.5748; // pitpgd .rodata: one ulp above 1.4746
	double y = (R - G) * kr + G + (B - G) * kb;
	double ys = full ? 4095.0 : 3504.0, yo = full ? 0.0 : 256.0, cs = full ? 4095.0 : 3584.0;
	ycc[0] = (int)code12(ys * y + yo, full);
	ycc[1] = (int)code12(((B - y) * cs) / d + 2048.0, full);
	ycc[2] = (int)code12(((R - y) * cs) / e + 2048.0, full);
}

// The Standard DV tunnel outside PiTPG sessions: PGenerator 1.6's
// (PGeneratord sha256 5882ec1b..., tunnel shaders at file offsets 0x1d1b88
// and 0x1d1020, uniforms from ofApp::shader_begin@0x71274), computed exactly
// (maintainer, 2026-11-18: bit-exact also where 1.6's float32 rounds the
// wrong way). 1.6 takes each channel as int(c * 256) << 4 of the colour c
// (code / max), so 8-bit codes keep their value, 255 gives 256 and 10- or
// 12-bit codes land on the 8-bit grid; then for a pixel pair (a, b)
//   Y = R(Kr R + Kg G + Kb B) per pixel,
//   Cb = R(2048 + 224/219 ((B - Y) / Db of a + of b) / 2),
//   Cr = R(2048 + 224/219 ((R - Y) / Dr of a + of b) / 2),
// with dv_profile 1 BT.2020's Kr 0.2627, Kb 0.0593, Db 1.8814, Dr 1.4746
// and 2 BT.709's 0.2126, 0.0722, 1.8556, 1.5748, no clamp. 1.6 evaluates
// this in float32; here every coefficient is a ratio of integers (per
// 10000), so the codes come from integer arithmetic: R(x) is
// floor(x + 0.5), and no exact .5 occurs (Y: 16 (Kr r + ..) is never 5000
// mod 10000; C: 224 k = 219 D (2j + 1) fails, the left side holds more
// factors of 2 than D). The shaders
// (ofxRPI4Window.cpp pg16_dovi_*_frag) run the same steps in 32-bit ints:
// t/renderer_pg16_tunnel.t compiles them against these.
struct Pg16Matrix { int kr, kg, kb, db, dr; };
inline Pg16Matrix pg16Matrix(int profile) {
	if (profile == 1) return { 2627, 6780, 593, 18814, 14746 };
	return { 2126, 7152, 722, 18556, 15748 };
}

// 1.6's step int(c * 256) of the colour doviSetPg16Color sets: code / max,
// or (16 + 219 code / max) / 255 for a full-range source. 0..256.
inline int pg16Step(int v, int maxc, int src_full) {
	if (maxc < 1) maxc = 1;
	v = v < 0 ? 0 : (v > maxc ? maxc : v);
	long long num = src_full ? 256LL * (16LL * maxc + 219LL * v) : 256LL * v;
	long long den = src_full ? 255LL * maxc : (long long)maxc;
	return (int)(num / den);
}

// 2048 + R(224 k / (2 d)) for the pair sum k of (B - Y) Db or (R - Y) Dr in
// 1/10000 units and d = 219 Db (or Dr) in the same: floor((224 k + d) /
// (2 d)) in steps that stay within 32 bits for |k| < 16 * 2d.
inline int pg16Chroma(int k, int d) {
	int e = 2 * d;
	int ko = k + 16 * e;
	int u = ko / e;
	int v = ko - u * e;
	return 2048 + 224 * (u - 16) + (224 * v + d) / e;
}

// Steps (0..256) of the even pixel a and the odd pixel b to Y of a, Y of b,
// Cb and Cr of the pair.
inline void pg16Codes(int profile, const int *a, const int *b, int *out) {
	Pg16Matrix m = pg16Matrix(profile);
	int ra = a[0] << 4, ga = a[1] << 4, ba = a[2] << 4;
	int rb = b[0] << 4, gb = b[1] << 4, bb = b[2] << 4;
	out[0] = (m.kr * ra + m.kg * ga + m.kb * ba + 5000) / 10000;
	out[1] = (m.kr * rb + m.kg * gb + m.kb * bb + 5000) / 10000;
	out[2] = pg16Chroma(-m.kr * ra - m.kg * ga + (m.db / 2) * ba - m.kr * rb - m.kg * gb + (m.db / 2) * bb, 219 * m.db);
	out[3] = pg16Chroma((m.dr / 2) * ra - m.kg * ga - m.kb * ba + (m.dr / 2) * rb - m.kg * gb - m.kb * bb, 219 * m.dr);
}

} // namespace dovi
