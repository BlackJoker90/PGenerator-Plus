/*
 * pgen_bootscreen - animated start and restart screen on /dev/fb0.
 *
 *   pgen_bootscreen boot [--daemon]     while Linux starts, until the renderer runs
 *   pgen_bootscreen reboot [--daemon]   while the Pi shuts down for a restart
 *   pgen_bootscreen stop                end a running instance
 *   pgen_bootscreen --preview OUT.ppm boot|reboot STEP SECONDS
 *
 * Text, icons and the logo come from /usr/share/PGenerator/bootscreen.dat
 * (rendered by the maintainer's tools/bootscreen/make_assets.py). The screen
 * is only visible while no DRM client owns the display, i.e. on the console's
 * plain RGB link, so colours are drawn as RGB. It exits non-zero before
 * drawing when the framebuffer or the assets are missing, so the caller can
 * fall back to the static splash.
 *
 * Build (static, like fb_player; the Pi has no kernel headers):
 *   arm-linux-gnueabihf-gcc -static -O2 -o pgen_bootscreen pgen_bootscreen.c -lm
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

/* --- Inline framebuffer definitions (from linux/fb.h) --- */
struct fb_bitfield { unsigned int offset, length, msb_right; };
struct fb_var_screeninfo {
	unsigned int xres, yres, xres_virtual, yres_virtual, xoffset, yoffset;
	unsigned int bits_per_pixel, grayscale;
	struct fb_bitfield red, green, blue, transp;
	unsigned int nonstd, activate, height, width, accel_flags, pixclock;
	unsigned int left_margin, right_margin, upper_margin, lower_margin;
	unsigned int hsync_len, vsync_len, sync, vmode, rotate, colorspace;
	unsigned int reserved[4];
};
struct fb_fix_screeninfo {
	char id[16];
	unsigned long smem_start;
	unsigned int smem_len, type, type_aux, visual;
	unsigned short xpanstep, ypanstep, ywrapstep;
	unsigned int line_length;
	unsigned long mmio_start;
	unsigned int mmio_len, accel;
	unsigned short capabilities, reserved[2];
};
#define FBIOGET_VSCREENINFO 0x4600
#define FBIOGET_FSCREENINFO 0x4602
/* --- End framebuffer definitions --- */

#define ASSETS "/usr/share/PGenerator/bootscreen.dat"
#define SELF_COMM "pgen_bootscreen"
/* Overridden only by the local tests, which build against a fake process
 * table. */
#ifndef PROC_DIR
#define PROC_DIR "/proc"
#endif

/* The WebUI's dark theme on the splash background. */
#define C_BG     0x101018
#define C_TEXT   0xe0e0e8
#define C_TEXT2  0x888898
#define C_ACCENT 0x5b7fff
#define C_FILL   0x4a68e8
#define C_TRACK  0x20202d
#define C_EDGE   0x2a2a3a
#define C_DONE   0x4caf50
#define C_IDLE   0x55556a

#define FPS 30
#define BOOT_TIMEOUT 150.0   /* no renderer after this: leave the logo */
#define REBOOT_TIMEOUT 90.0  /* still alive after this: the restart hangs */

enum { MODE_BOOT, MODE_REBOOT };

typedef struct { char name[32]; int kind, w, h; const uint8_t *data; } sprite_t;
static sprite_t sprites[64];
static int nsprites;

static int W, H;
static uint32_t *base;   /* background + logo */
static uint32_t *canvas; /* base + everything that moves */

static volatile sig_atomic_t stop_requested;

/* ------------------------------------------------------------ assets */

static int load_assets(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return -1;
	if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -1; }
	long size = ftell(f);
	rewind(f);
	if (size < 8 || size > (16 << 20)) { fclose(f); return -1; }
	uint8_t *buf = malloc(size);
	if (!buf || fread(buf, 1, size, f) != (size_t)size) { fclose(f); free(buf); return -1; }
	fclose(f);
	if (memcmp(buf, "PGBS", 4) != 0 || (buf[4] | buf[5] << 8) != 1)
		return -1;
	int count = buf[6] | buf[7] << 8;
	long p = 8;
	for (int i = 0; i < count && nsprites < (int)(sizeof(sprites) / sizeof(sprites[0])); i++) {
		if (p + 1 > size) return -1;
		int nl = buf[p++];
		if (nl >= (int)sizeof(sprites[0].name) || p + nl + 5 > size) return -1;
		sprite_t *s = &sprites[nsprites];
		memcpy(s->name, buf + p, nl);
		s->name[nl] = 0;
		p += nl;
		s->kind = buf[p];
		s->w = buf[p + 1] | buf[p + 2] << 8;
		s->h = buf[p + 3] | buf[p + 4] << 8;
		p += 5;
		long bytes = (long)s->w * s->h * (s->kind == 1 ? 2 : 1);
		if (p + bytes > size) return -1;
		s->data = buf + p;
		p += bytes;
		nsprites++;
	}
	return nsprites > 0 ? 0 : -1;
}

static const sprite_t *sp(const char *name)
{
	for (int i = 0; i < nsprites; i++)
		if (strcmp(sprites[i].name, name) == 0)
			return &sprites[i];
	return NULL;
}

/* ------------------------------------------------------------ drawing */

static inline uint32_t mix(uint32_t a, uint32_t b, int t)
{
	if (t <= 0) return a;
	if (t >= 255) return b;
	uint32_t r = (((a >> 16) & 255) * (255 - t) + ((b >> 16) & 255) * t + 127) / 255;
	uint32_t g = (((a >> 8) & 255) * (255 - t) + ((b >> 8) & 255) * t + 127) / 255;
	uint32_t bl = ((a & 255) * (255 - t) + (b & 255) * t + 127) / 255;
	return r << 16 | g << 8 | bl;
}

static void fill(uint32_t *buf, int x, int y, int w, int h, uint32_t c)
{
	for (int j = y < 0 ? 0 : y; j < y + h && j < H; j++)
		for (int i = x < 0 ? 0 : x; i < x + w && i < W; i++)
			buf[j * W + i] = c;
}

/* Alpha sprite tinted with C; returns the right edge (sprites carry 2 px of
 * padding left and right). */
static int put_alpha(uint32_t *buf, const sprite_t *s, int x, int y, uint32_t c)
{
	if (!s || s->kind != 0)
		return x;
	for (int j = 0; j < s->h; j++) {
		int yy = y + j;
		if (yy < 0 || yy >= H) continue;
		for (int i = 0; i < s->w; i++) {
			int xx = x + i;
			if (xx < 0 || xx >= W) continue;
			int a = s->data[j * s->w + i];
			if (a)
				buf[yy * W + xx] = mix(buf[yy * W + xx], c, a);
		}
	}
	return x + s->w;
}

static void put_rgb565(uint32_t *buf, const sprite_t *s, int x, int y)
{
	if (!s || s->kind != 1)
		return;
	for (int j = 0; j < s->h; j++) {
		int yy = y + j;
		if (yy < 0 || yy >= H) continue;
		for (int i = 0; i < s->w; i++) {
			int xx = x + i;
			if (xx < 0 || xx >= W) continue;
			const uint8_t *p = s->data + 2 * (j * s->w + i);
			unsigned v = p[0] | p[1] << 8;
			unsigned r = (v >> 11) & 31, g = (v >> 5) & 63, b = v & 31;
			buf[yy * W + xx] = (r * 255 / 31) << 16 | (g * 255 / 63) << 8 | (b * 255 / 31);
		}
	}
}

static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

/* Coverage of a horizontal capsule (rounded bar) spanning x0..x1 at a pixel
 * centre. */
static float capsule(float px, float py, float x0, float x1, float cy, float r)
{
	float cx;
	if (x1 - x0 <= 2 * r) cx = (x0 + x1) / 2;
	else cx = clampf(px, x0 + r, x1 - r);
	float dx = px - cx, dy = py - cy;
	return clampf(r + 0.5f - sqrtf(dx * dx + dy * dy), 0, 1);
}

/* Progress bar: VALUE 0..100, or a travelling glow while INDETERMINATE. A
 * soft sheen runs over the filled part so a slow phase still moves. */
static void draw_bar(int bx, int by, int bw, int bh, float value, int indeterminate, int done, double t)
{
	float r = bh / 2.0f, cy = by + r;
	float fw = bw * clampf(value, 0, 100) / 100.0f;
	uint32_t fc = done ? C_DONE : C_FILL;
	float sheen = (float)fmod(t / 2.4, 1.0) * 1.6f - 0.3f;
	float glow = (float)fmod(t / 1.8, 1.0);
	glow = glow * glow * (3 - 2 * glow) * 1.4f - 0.2f; /* ease in-out, starts and ends off the track */
	for (int y = by - 1; y <= by + bh; y++) {
		for (int x = bx - 1; x <= bx + bw; x++) {
			if (x < 0 || x >= W || y < 0 || y >= H) continue;
			float px = x + 0.5f, py = y + 0.5f;
			float ct = capsule(px, py, bx, bx + bw, cy, r);
			if (ct <= 0) continue;
			uint32_t c = mix(canvas[y * W + x], C_TRACK, (int)(ct * 255));
			if (indeterminate) {
				float d = fabsf(px - (bx + glow * bw)) / (0.2f * bw);
				float k = clampf(1 - d, 0, 1);
				k = k * k * (3 - 2 * k);
				c = mix(c, C_FILL, (int)(k * ct * 0.85f * 255));
			} else if (fw > 0) {
				float cf = capsule(px, py, bx, bx + (fw < bh ? bh : fw), cy, r);
				if (cf > 0) {
					uint32_t f = fc;
					if (!done) {
						float d = (px - (bx + sheen * fw)) / (0.12f * bw);
						float k = (float)exp(-d * d) * 0.28f;
						f = mix(fc, 0xffffff, (int)(k * 255));
					}
					c = mix(c, f, (int)(cf * 255));
				}
			}
			canvas[y * W + x] = c;
		}
	}
}

/* Current-step icon: a faint ring with a quarter arc turning once per 0.9 s
 * (the WebUI's spinner), 4x4 supersampled. */
static void draw_spinner(int x, int y, int size, double t)
{
	float R = size * 0.35f, th = size * 0.1f, c0 = size / 2.0f;
	float rot = (float)fmod(t / 0.9, 1.0) * 2 * (float)M_PI;
	for (int j = 0; j < size; j++) {
		for (int i = 0; i < size; i++) {
			int ring = 0, arc = 0;
			for (int sy = 0; sy < 4; sy++) {
				for (int sx = 0; sx < 4; sx++) {
					float px = i + (sx + 0.5f) / 4 - c0, py = j + (sy + 0.5f) / 4 - c0;
					float d = sqrtf(px * px + py * py);
					if (fabsf(d - R) > th / 2) continue;
					ring++;
					float a = atan2f(py, px) - rot;
					while (a < 0) a += 2 * (float)M_PI;
					while (a >= 2 * (float)M_PI) a -= 2 * (float)M_PI;
					if (a < (float)M_PI / 2) arc++;
				}
			}
			int xx = x + i, yy = y + j;
			if (xx < 0 || xx >= W || yy < 0 || yy >= H || !ring) continue;
			uint32_t c = mix(canvas[yy * W + xx], C_ACCENT, ring * 255 * 3 / 10 / 16);
			canvas[yy * W + xx] = mix(c, C_ACCENT, arc * 255 / 16);
		}
	}
}

/* "m:ss elapsed", right-aligned at RIGHT. */
static void draw_elapsed(int right, int y, double seconds)
{
	int s = (int)seconds;
	if (s < 0) s = 0;
	if (s > 5999) s = 5999;
	char txt[8];
	snprintf(txt, sizeof(txt), "%d:%02d", s / 60, s % 60);
	int adv = 0;
	for (int d = 0; d < 10; d++) {
		char n[4] = { 'd', (char)('0' + d), 0 };
		const sprite_t *g = sp(n);
		if (g && g->w - 4 > adv) adv = g->w - 4;
	}
	const sprite_t *colon = sp("colon"), *word = sp("word_elapsed");
	int width = (word ? word->w - 4 : 0) + 10;
	for (const char *p = txt; *p; p++)
		width += (*p == ':') ? (colon ? colon->w - 4 : 0) : adv;
	int x = right - width;
	for (const char *p = txt; *p; p++) {
		if (*p == ':') {
			put_alpha(canvas, colon, x - 2, y, C_TEXT2);
			x += colon ? colon->w - 4 : 0;
		} else {
			char n[4] = { 'd', *p, 0 };
			const sprite_t *g = sp(n);
			if (g) put_alpha(canvas, g, x - 2 + (adv - (g->w - 4)) / 2, y, C_TEXT2);
			x += adv;
		}
	}
	put_alpha(canvas, word, x + 10 - 2, y, C_TEXT2);
}

/* ------------------------------------------------------------ layout */

typedef struct {
	int mode, nsteps;
	int col_x, col_w;
	int logo_x, logo_y;
	int title_y, meta_y, bar_y, status_y, divider_y, steps_y;
	int dyn_y0, dyn_y1; /* rows redrawn every frame */
} layout_t;

#define BAR_H 10
#define ICON 30
#define STEP_ROW 46

static void make_layout(layout_t *L, int mode)
{
	const sprite_t *logo = sp("logo");
	const sprite_t *title = sp(mode == MODE_BOOT ? "title_boot" : "title_reboot");
	const sprite_t *status = sp("status_reboot");
	int logo_h = logo ? logo->h : 0, title_h = title ? title->h : 60, line_h = status ? status->h : 36;
	L->mode = mode;
	L->nsteps = mode == MODE_BOOT ? 4 : 3;
	L->col_w = 880 < W - 80 ? 880 : W - 80;
	L->col_x = (W - L->col_w) / 2;
	int total = logo_h + 48 + title_h + 6 + line_h + 22 + BAR_H + 14 + line_h + 22 + 1 + 18 + L->nsteps * STEP_ROW;
	int y = (H - total) / 2;
	if (y < 0) y = 0;
	L->logo_x = logo ? (W - logo->w) / 2 : 0;
	L->logo_y = y;
	y += logo_h + 48;
	L->title_y = y;
	y += title_h + 6;
	L->meta_y = y;
	y += line_h + 22;
	L->bar_y = y;
	y += BAR_H + 14;
	L->status_y = y;
	y += line_h + 22;
	L->divider_y = y;
	y += 1 + 18;
	L->steps_y = y;
	L->dyn_y0 = L->meta_y;
	L->dyn_y1 = L->steps_y + L->nsteps * STEP_ROW;
}

static void draw_base(const layout_t *L)
{
	fill(base, 0, 0, W, H, C_BG);
	put_rgb565(base, sp("logo"), L->logo_x, L->logo_y);
}

/* step: index of the current step; nsteps = everything done. */
static void draw_frame(const layout_t *L, int step, float value, double t, double elapsed)
{
	memcpy(canvas, base, (size_t)W * H * sizeof(uint32_t));
	int boot = L->mode == MODE_BOOT, done = step >= L->nsteps;
	char name[32];
	put_alpha(canvas, sp(boot ? "title_boot" : "title_reboot"), L->col_x - 2, L->title_y, C_TEXT);
	if (!boot)
		put_alpha(canvas, sp("meta_reboot"), L->col_x - 2, L->meta_y, C_TEXT2);
	draw_elapsed(L->col_x + L->col_w, L->meta_y, elapsed);
	draw_bar(L->col_x, L->bar_y, L->col_w, BAR_H, value, !boot, done, t);
	if (boot)
		snprintf(name, sizeof(name), "status_boot%d", step < L->nsteps ? step : L->nsteps - 1);
	else
		snprintf(name, sizeof(name), step > 0 && sp("status_reboot1") ? "status_reboot1" : "status_reboot");
	put_alpha(canvas, sp(name), L->col_x - 2, L->status_y, C_TEXT);
	fill(canvas, L->col_x, L->divider_y, L->col_w, 1, C_EDGE);
	for (int i = 0; i < L->nsteps; i++) {
		int ry = L->steps_y + i * STEP_ROW, iy = ry + (STEP_ROW - ICON) / 2;
		const char *m = boot ? "boot" : "reboot";
		if (i < step) {
			put_alpha(canvas, sp("icon_check"), L->col_x, iy, C_DONE);
			snprintf(name, sizeof(name), "step_%s%d", m, i);
			put_alpha(canvas, sp(name), L->col_x + ICON + 12, ry + 5, C_TEXT);
		} else if (i == step) {
			draw_spinner(L->col_x, iy, ICON, t);
			snprintf(name, sizeof(name), "stepcur_%s%d", m, i);
			put_alpha(canvas, sp(name), L->col_x + ICON + 12, ry + 5, C_TEXT);
		} else {
			put_alpha(canvas, sp("icon_dot"), L->col_x, iy, C_IDLE);
			snprintf(name, sizeof(name), "step_%s%d", m, i);
			put_alpha(canvas, sp(name), L->col_x + ICON + 12, ry + 5, C_TEXT2);
		}
	}
}

/* ------------------------------------------------------------ boot progress */

/* Step boundaries on the bar and the usual duration of each step on a Pi 4
 * (measured: fb0 at 8.3 s, dhcpcd 11.8 s, default route ~13 s, daemon
 * 31.8 s, renderer 32.4 s after the kernel starts). Within a step the bar
 * creeps towards 90 % of its span and only passes it when the step is
 * really done. */
static const float MARK[] = { 0, 14, 22, 92, 100 };
static const float EXPECT[] = { 3.5f, 1.5f, 19.0f, 1.5f };

static float boot_target(int step, double in_step)
{
	if (step >= 4)
		return 100;
	float span = MARK[step + 1] - MARK[step];
	return MARK[step] + span * 0.9f * (1 - (float)exp(-(float)in_step / EXPECT[step]));
}

static int read_small(const char *path, char *buf, size_t len)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0) return -1;
	ssize_t n = read(fd, buf, len - 1);
	close(fd);
	if (n < 0) return -1;
	buf[n] = 0;
	return (int)n;
}

/* The renderer runs as PGeneratord, or PGeneratord.dv for Dolby Vision. */
static int is_renderer(const char *comm)
{
	return !strcmp(comm, "PGeneratord") || !strcmp(comm, "PGeneratord.dv");
}

/* Bit 0: dhcp client, 1: PGenerator daemon, 2: renderer, 3: another
 * pgen_bootscreen. */
static int scan_processes(void)
{
	int found = 0;
	DIR *d = opendir(PROC_DIR);
	if (!d) return 0;
	struct dirent *e;
	char path[300], comm[64], cmd[256];
	pid_t self = getpid();
	while ((e = readdir(d))) {
		if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
		if (atoi(e->d_name) == self) continue;
		snprintf(path, sizeof(path), PROC_DIR "/%s/comm", e->d_name);
		if (read_small(path, comm, sizeof(comm)) <= 0) continue;
		comm[strcspn(comm, "\n")] = 0;
		if (!strcmp(comm, "dhcpcd") || !strcmp(comm, "dhclient") || !strcmp(comm, "udhcpc"))
			found |= 1;
		else if (is_renderer(comm))
			found |= 4;
		else if (!strcmp(comm, SELF_COMM))
			found |= 8;
		else if (!strncmp(comm, "/usr/sbin/PGene", 15) || !strcmp(comm, "perl")) {
			snprintf(path, sizeof(path), PROC_DIR "/%s/cmdline", e->d_name);
			int n = read_small(path, cmd, sizeof(cmd));
			for (int i = 0; i < n; i++) if (!cmd[i]) cmd[i] = ' ';
			if (n > 0 && strstr(cmd, "PGeneratord.pl"))
				found |= 2;
		}
	}
	closedir(d);
	return found;
}

static int has_default_route(void)
{
	FILE *f = fopen(PROC_DIR "/net/route", "r");
	if (!f) return 0;
	char line[256];
	int yes = 0;
	if (fgets(line, sizeof(line), f)) {
		while (fgets(line, sizeof(line), f)) {
			char ifc[32];
			unsigned long dest;
			if (sscanf(line, "%31s %lx", ifc, &dest) == 2 && dest == 0) { yes = 1; break; }
		}
	}
	fclose(f);
	return yes;
}

static double uptime_s(void)
{
	char b[64];
	if (read_small(PROC_DIR "/uptime", b, sizeof(b)) <= 0) return 0;
	return atof(b);
}

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ------------------------------------------------------------ output */

typedef struct {
	int fd;
	uint8_t *mem;
	size_t size;
	int bpp, stride;
	struct fb_var_screeninfo var;
	/* Static rows as last written: something else clearing fb0 (the boot
	 * scripts clear tty1 and unbind the console after the first frame)
	 * shows up as a difference here, and the whole frame is drawn again. */
	int nsent, sent_y[4];
	uint8_t *sent;
} fb_t;

static int fb_open(fb_t *fb)
{
	struct fb_fix_screeninfo fix;
	fb->fd = open("/dev/fb0", O_RDWR);
	if (fb->fd < 0) return -1;
	if (ioctl(fb->fd, FBIOGET_VSCREENINFO, &fb->var) < 0 || ioctl(fb->fd, FBIOGET_FSCREENINFO, &fix) < 0)
		return -1;
	fb->bpp = fb->var.bits_per_pixel;
	if (fb->bpp != 16 && fb->bpp != 32) return -1;
	fb->stride = fix.line_length;
	fb->size = fix.smem_len;
	W = fb->var.xres;
	H = fb->var.yres;
	if (W < 320 || H < 240 || (size_t)fb->stride * H > fb->size) return -1;
	fb->mem = mmap(NULL, fb->size, PROT_READ | PROT_WRITE, MAP_SHARED, fb->fd, 0);
	return fb->mem == MAP_FAILED ? -1 : 0;
}

/* Rows Y0..Y1 of the canvas to the framebuffer; 4x4 ordered dither when a
 * channel has fewer than 8 bits (RGB565), so the glow does not band. */
static void fb_push(fb_t *fb, int y0, int y1)
{
	static const uint8_t bayer[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
	struct fb_bitfield *rf = &fb->var.red, *gf = &fb->var.green, *bf = &fb->var.blue;
	if (y0 < 0) y0 = 0;
	if (y1 > H) y1 = H;
	for (int y = y0; y < y1; y++) {
		uint8_t *row = fb->mem + (size_t)y * fb->stride;
		for (int x = 0; x < W; x++) {
			uint32_t c = canvas[y * W + x];
			int th = bayer[(y & 3) * 4 + (x & 3)];
			unsigned ch[3] = { (c >> 16) & 255, (c >> 8) & 255, c & 255 };
			struct fb_bitfield *f[3] = { rf, gf, bf };
			uint32_t v = 0;
			for (int k = 0; k < 3; k++) {
				int len = f[k]->length > 8 ? 8 : (int)f[k]->length;
				unsigned q = ch[k];
				if (len < 8) {
					unsigned step = 1u << (8 - len);
					q = q + (th * step) / 16;
					if (q > 255) q = 255;
				}
				v |= (q >> (8 - len)) << f[k]->offset;
			}
			if (fb->bpp == 16) ((uint16_t *)row)[x] = (uint16_t)v;
			else ((uint32_t *)row)[x] = v;
		}
	}
}

static void fb_watch_rows(fb_t *fb, const layout_t *L)
{
	const sprite_t *logo = sp("logo");
	int ys[4] = { 4, L->logo_y + (logo ? logo->h / 2 : 0), L->title_y + 20, H - 5 };
	fb->nsent = 0;
	fb->sent = malloc((size_t)fb->stride * 4);
	if (!fb->sent) return;
	for (int i = 0; i < 4; i++)
		if (ys[i] >= 0 && ys[i] < H && (ys[i] < L->dyn_y0 || ys[i] >= L->dyn_y1))
			fb->sent_y[fb->nsent++] = ys[i];
}

static void fb_remember(fb_t *fb)
{
	for (int i = 0; i < fb->nsent; i++)
		memcpy(fb->sent + (size_t)i * fb->stride, fb->mem + (size_t)fb->sent_y[i] * fb->stride, fb->stride);
}

static int fb_intact(const fb_t *fb)
{
	for (int i = 0; i < fb->nsent; i++)
		if (memcmp(fb->sent + (size_t)i * fb->stride, fb->mem + (size_t)fb->sent_y[i] * fb->stride, fb->stride))
			return 0;
	return 1;
}

/* The changing rows, or the whole frame on the first call and whenever the
 * static part was overwritten. */
static void fb_show(fb_t *fb, const layout_t *L, int *first)
{
	if (*first || !fb_intact(fb)) {
		fb_push(fb, 0, H);
		fb_remember(fb);
		*first = 0;
	} else {
		fb_push(fb, L->dyn_y0, L->dyn_y1);
	}
}

static int write_ppm(const char *path)
{
	FILE *f = fopen(path, "wb");
	if (!f) return -1;
	fprintf(f, "P6\n%d %d\n255\n", W, H);
	for (int i = 0; i < W * H; i++) {
		uint8_t px[3] = { (uint8_t)(canvas[i] >> 16), (uint8_t)(canvas[i] >> 8), (uint8_t)canvas[i] };
		fwrite(px, 1, 3, f);
	}
	return fclose(f);
}

/* ------------------------------------------------------------ main */

static void on_signal(int sig) { (void)sig; stop_requested = 1; }

static int stop_others(void)
{
	DIR *d = opendir(PROC_DIR);
	if (!d) return 1;
	struct dirent *e;
	char path[300], comm[64];
	pid_t self = getpid();
	while ((e = readdir(d))) {
		if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
		pid_t pid = atoi(e->d_name);
		if (pid == self) continue;
		snprintf(path, sizeof(path), PROC_DIR "/%s/comm", e->d_name);
		if (read_small(path, comm, sizeof(comm)) <= 0) continue;
		comm[strcspn(comm, "\n")] = 0;
		if (!strcmp(comm, SELF_COMM))
			kill(pid, SIGTERM);
	}
	closedir(d);
	/* Wait (up to 1 s) so the caller can draw on fb0 right after. */
	for (int i = 0; i < 20 && (scan_processes() & 8); i++)
		usleep(50000);
	return 0;
}

static void usage(void)
{
	fprintf(stderr, "usage: pgen_bootscreen boot|reboot [--daemon] | stop | --preview OUT.ppm boot|reboot STEP SECONDS\n");
}

int main(int argc, char **argv)
{
	if (argc >= 2 && !strcmp(argv[1], "stop"))
		return stop_others();

	if (argc >= 6 && !strcmp(argv[1], "--preview")) {
		int mode = !strcmp(argv[3], "reboot") ? MODE_REBOOT : MODE_BOOT;
		int step = atoi(argv[4]);
		double t = atof(argv[5]);
		W = 1920;
		H = 1080;
		if (load_assets(getenv("PGEN_BOOTSCREEN_ASSETS") ? getenv("PGEN_BOOTSCREEN_ASSETS") : ASSETS) < 0) {
			fprintf(stderr, "pgen_bootscreen: cannot load assets\n");
			return 1;
		}
		base = malloc((size_t)W * H * 4);
		canvas = malloc((size_t)W * H * 4);
		if (!base || !canvas) return 1;
		layout_t L;
		make_layout(&L, mode);
		draw_base(&L);
		draw_frame(&L, step, mode == MODE_BOOT ? boot_target(step, t) : 0, t, t);
		return write_ppm(argv[2]) == 0 ? 0 : 1;
	}

	if (argc < 2 || (strcmp(argv[1], "boot") && strcmp(argv[1], "reboot"))) {
		usage();
		return 2;
	}
	int mode = !strcmp(argv[1], "reboot") ? MODE_REBOOT : MODE_BOOT;
	int daemonize = argc >= 3 && !strcmp(argv[2], "--daemon");

	if (mode == MODE_BOOT && (scan_processes() & (8 | 4)))
		return 0; /* already showing, or the renderer owns the display */
	if (mode == MODE_REBOOT)
		stop_others();

	fb_t fb;
	if (fb_open(&fb) < 0) {
		fprintf(stderr, "pgen_bootscreen: no usable /dev/fb0\n");
		return 1;
	}
	if (load_assets(ASSETS) < 0) {
		fprintf(stderr, "pgen_bootscreen: cannot load %s\n", ASSETS);
		return 1;
	}
	base = malloc((size_t)W * H * 4);
	canvas = malloc((size_t)W * H * 4);
	if (!base || !canvas) return 1;

	if (daemonize) {
		pid_t pid = fork();
		if (pid < 0) return 1;
		if (pid > 0) return 0;
		setsid();
		int nul = open("/dev/null", O_RDWR);
		if (nul >= 0) { dup2(nul, 0); dup2(nul, 1); dup2(nul, 2); if (nul > 2) close(nul); }
	}
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	signal(SIGHUP, SIG_IGN);

	layout_t L;
	make_layout(&L, mode);
	draw_base(&L);
	fb_watch_rows(&fb, &L);

	double t0 = now_s(), last_scan = -1, step_t0 = t0, done_at = 0;
	int step = 0, first = 1;
	float value = 0;
	while (!stop_requested) {
		double t = now_s() - t0;
		/* Once the daemon runs the renderer follows within a second: look
		 * more often then, so the last frame lands before the daemon blanks
		 * fb0 (it does that as soon as the renderer is DRM master). */
		if (mode == MODE_BOOT && t - last_scan >= (step >= 3 ? 0.05 : 0.25)) {
			last_scan = t;
			int pr = scan_processes();
			int s = step;
			if (pr & 4) s = 4;
			else if (pr & 2) s = s < 3 ? 3 : s;
			else if (has_default_route()) s = s < 2 ? 2 : s;
			else if (pr & 1) s = s < 1 ? 1 : s;
			if (s != step) { step = s; step_t0 = now_s(); }
		}
		if (mode == MODE_BOOT) {
			if (step >= 4) {
				/* Renderer started: one finished frame, which stays until the
				 * renderer takes the display, then step aside. */
				done_at = t;
				draw_frame(&L, step, 100, t, uptime_s());
				fb_show(&fb, &L, &first);
				break;
			}
			float target = boot_target(step, now_s() - step_t0);
			value += (target - value) * 0.12f;
			if (t > BOOT_TIMEOUT) break;
		} else if (t > REBOOT_TIMEOUT) {
			break;
		}
		double elapsed = mode == MODE_BOOT ? uptime_s() : t;
		draw_frame(&L, step, value, t, elapsed);
		fb_show(&fb, &L, &first);
		double next = t0 + t + 1.0 / FPS, n = now_s();
		if (next > n) usleep((useconds_t)((next - n) * 1e6));
	}
	/* Restart screen: the TERM comes from sendsigs (or from the next restart
	 * screen, which draws over it at once). The system goes down now, so the
	 * frame that stays until the Pi resets shows the restart step. */
	if (stop_requested && mode == MODE_REBOOT) {
		draw_frame(&L, 1, 0, now_s() - t0, now_s() - t0);
		fb_show(&fb, &L, &first);
		return 0;
	}
	/* Leave the plain splash (logo only) when the renderer never came or the
	 * restart hangs. After a normal start the renderer covers the last frame;
	 * after "stop" the caller takes over the framebuffer. */
	if (!stop_requested && !(mode == MODE_BOOT && done_at)) {
		memcpy(canvas, base, (size_t)W * H * sizeof(uint32_t));
		fb_push(&fb, 0, H);
	}
	return 0;
}
