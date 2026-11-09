#pragma once

#include <cmath>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cerrno>

// Standard (TV-led) Dolby Vision display-management packet, built the way
// PiTPG 2.0.3 builds it (pitpgd dv_md_build@0x4043e0, dv_packet@0x4045f0,
// pq12@0x40d530; REA/Ghidra ev_7183b908, ev_2b3bb6bd). Field layout: ETSI GS
// CCM 001 V1.1.1, 6.2. Built on the Mac under ASan/UBSan by
// t/renderer_dovi_metadata.t.
// Two departures from pitpgd, both to ETSI GS CCM 001 V1.1.1: the L1 average
// is the value a sink infers without L1, (source_min_PQ + source_max_PQ) / 2
// (6.2.2; pitpgd sends min + (max - min) / 3, a scene statistic no pattern
// has), and header byte 1 carries a metadata id that steps (mod 16) each time
// the packet changes (6.3.1-6.3.2; pitpgd leaves it 0). The id goes into
// both nibbles (affected = current: the metadata are the current picture's),
// as the independent encoder CroqueMr/libreelec-x86-DV dvbridge_metadata.h
// writes packet[1]=(id<<4)|id.
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

namespace dovi {

// pitpgd's tables (2.0.3 .rodata 0x493290..0x493340), as int16.
static const int16_t ycc_to_rgb_709[9]       = { 9574, 0, 14739, 9574, -1753, -4382, 9574, 17369, 0 };
static const int16_t ycc_to_rgb_709_full[9]  = { 8192, 0, 12901, 8192, -1535, -3835, 8192, 15201, 0 };
static const int16_t ycc_to_rgb_2020[9]      = { 9574, 0, 13802, 9574, -1540, -5348, 9574, 17610, 0 };
static const int16_t ycc_to_rgb_2020_full[9] = { 8192, 0, 12080, 8192, -1348, -4681, 8192, 15412, 0 };
static const int16_t rgb_to_lms_p3[9]        = { 5845, 9702, 837, 2568, 12256, 1561, 0, 679, 15705 };
static const int16_t rgb_to_lms_2020[9]      = { 7222, 8771, 390, 2654, 12430, 1300, 0, 422, 15962 };

const int packet_bytes = 128;
const int payload_max = 0x66;

struct Params {
	int container_2020; // 1: BT.2020 container (BT.2020 matrices), 0: P3-D65 (BT.709 matrices)
	int full;           // 1: full-range tunnel signal, 0: limited
	int min_pq;         // source display min, 12-bit PQ
	int max_pq;         // source display max, 12-bit PQ
	int diagonal;       // source display diagonal, inches
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

// The payload; returns its length (0x5B or 0x66).
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
	p[70] = run_mode ? 3 : 2;
	p[74] = 0x06;
	p[75] = 0x01;
	put16(p + 76, m.min_pq);
	put16(p + 78, m.max_pq);
	put16(p + 80, (m.min_pq + m.max_pq) / 2);
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

// The metadata id of a packet (ETSI GS CCM 001 6.3.1): it steps, mod 16,
// when the packet differs from the one before (bytes 3..123: everything but
// the header and the CRC); the first packet keeps the start value.
// The renderer restarts on most DV setting changes (PQ, range, container),
// so the last id and packet live in a file (load/save) and a new process
// steps on from them; without a file (first start after a boot or a daemon
// restart, or no save ever worked) it starts at 0.
struct MetadataId {
	int id = 0;
	bool have = false;
	unsigned char prev[packet_bytes];
	// pkt built with metadata id 0; returns the id to send it with.
	int next(const unsigned char *pkt) {
		if (have && memcmp(prev + 3, pkt + 3, 121) != 0) id = (id + 1) & 15;
		memcpy(prev, pkt, packet_bytes);
		have = true;
		return id;
	}
	// The id byte and the packet; anything else (missing, short, an id
	// above 15) is ignored. Returns whether it was taken.
	bool load(const char *path) {
		unsigned char b[1 + packet_bytes + 1];
		FILE *f = fopen(path, "rb");
		if (!f) return false;
		size_t n = fread(b, 1, sizeof(b), f);
		fclose(f);
		if (n != 1 + (size_t)packet_bytes || b[0] > 15) return false;
		id = b[0];
		memcpy(prev, b + 1, packet_bytes);
		have = true;
		return true;
	}
	// Written whole to path.tmp, then renamed over path. On failure errno
	// is the failed step's.
	bool save(const char *path) const {
		if (!have) return false;
		char tmp[512];
		if (snprintf(tmp, sizeof(tmp), "%s.tmp", path) >= (int)sizeof(tmp)) return false;
		FILE *f = fopen(tmp, "wb");
		if (!f) return false;
		unsigned char b = (unsigned char)id;
		bool ok = fwrite(&b, 1, 1, f) == 1 && fwrite(prev, 1, packet_bytes, f) == (size_t)packet_bytes;
		ok = (fclose(f) == 0) && ok;
		if (!ok || rename(tmp, path) != 0) {
			int e = errno;
			remove(tmp);
			errno = e;
			return false;
		}
		return true;
	}
};

// Where the renderer keeps it: a subdirectory of running/, the renderer's
// tmpfs (owner pgenerator, mode 0770). clean_files empties running/ itself on
// every renderer stop and most starts but keeps its subdirectories; the init
// script unmounts it on a daemon stop, so a daemon restart or a boot normally
// starts at 0.
static const char *const metadata_id_dir = "/var/lib/PGenerator/running/dovi";
static const char *const metadata_id_file = "/var/lib/PGenerator/running/dovi/metadata_id";

// CRC-32/MPEG-2: poly 0x04C11DB7, init 0xFFFFFFFF, MSB first, no final XOR.
inline uint32_t crc32mpeg(const unsigned char *d, size_t n) {
	uint32_t c = 0xffffffffu;
	for (size_t i = 0; i < n; i++) {
		c ^= (uint32_t)d[i] << 24;
		for (int b = 0; b < 8; b++) c = (c & 0x80000000u) ? (c << 1) ^ 0x04c11db7u : (c << 1);
	}
	return c;
}

// The whole 128-byte packet (pitpgd dv_packet), metadata id in byte 1.
inline void buildPacket(const Params &in, int run_mode, unsigned char *out, int metadata_id = 0) {
	unsigned char payload[payload_max];
	int len = buildPayload(in, run_mode, payload);
	memset(out, 0, packet_bytes);
	out[1] = (unsigned char)(((metadata_id & 15) << 4) | (metadata_id & 15));
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

} // namespace dovi
