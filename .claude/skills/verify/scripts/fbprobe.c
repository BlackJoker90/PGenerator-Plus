/*
 * fbprobe: read back the pixels the vc4 primary plane is scanning out.
 * Read-only test tool (not shipped). Usage: fbprobe [x y]
 * Prints the framebuffer format/modifier and the decoded code values at
 * (x,y) (default: screen centre) and at a few neighbours.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

static void decode(uint32_t fmt, const uint8_t *p, int *r, int *g, int *b, int *bits) {
	uint32_t v;
	memcpy(&v, p, 4);
	switch (fmt) {
	case DRM_FORMAT_XRGB2101010: case DRM_FORMAT_ARGB2101010:
		*r = (v >> 20) & 0x3ff; *g = (v >> 10) & 0x3ff; *b = v & 0x3ff; *bits = 10; return;
	case DRM_FORMAT_XBGR2101010: case DRM_FORMAT_ABGR2101010:
		*b = (v >> 20) & 0x3ff; *g = (v >> 10) & 0x3ff; *r = v & 0x3ff; *bits = 10; return;
	case DRM_FORMAT_XBGR8888: case DRM_FORMAT_ABGR8888:
		*r = p[0]; *g = p[1]; *b = p[2]; *bits = 8; return;
	default: /* XRGB8888 / ARGB8888 */
		*b = p[0]; *g = p[1]; *r = p[2]; *bits = 8; return;
	}
}

int main(int argc, char **argv) {
	const char *cards[] = { "/dev/dri/card0", "/dev/dri/card1", "/dev/dri/card2" };
	for (unsigned c = 0; c < 3; c++) {
		int fd = open(cards[c], O_RDWR | O_CLOEXEC);
		if (fd < 0) continue;
		drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
		drmModePlaneRes *pr = drmModeGetPlaneResources(fd);
		if (!pr) { close(fd); continue; }
		for (unsigned i = 0; i < pr->count_planes; i++) {
			drmModePlane *pl = drmModeGetPlane(fd, pr->planes[i]);
			if (!pl || !pl->fb_id) { drmModeFreePlane(pl); continue; }
			drmModeFB2 *fb = drmModeGetFB2(fd, pl->fb_id);
			if (!fb) { drmModeFreePlane(pl); continue; }
			char fcc[5] = { 0 };
			memcpy(fcc, &fb->pixel_format, 4);
			printf("%s plane %u fb %u %ux%u format %s modifier 0x%llx pitch %u handle %u\n",
			       cards[c], pl->plane_id, pl->fb_id, fb->width, fb->height, fcc,
			       (unsigned long long)fb->modifier, fb->pitches[0], fb->handles[0]);
			if (!fb->handles[0]) { printf("  no handle (need root)\n"); goto next; }
			if (fb->modifier != DRM_FORMAT_MOD_LINEAR && fb->modifier != DRM_FORMAT_MOD_INVALID) {
				printf("  tiled buffer, not decoded\n"); goto next;
			}
			struct drm_mode_map_dumb md = { .handle = fb->handles[0] };
			if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md)) { perror("  MAP_DUMB"); goto next; }
			size_t len = (size_t)fb->pitches[0] * fb->height;
			uint8_t *map = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, md.offset);
			if (map == MAP_FAILED) { perror("  mmap"); goto next; }
			int x = argc > 2 ? atoi(argv[1]) : (int)fb->width / 2;
			int y = argc > 2 ? atoi(argv[2]) : (int)fb->height / 2;
			int pts[][2] = { { x, y }, { x + 1, y }, { x, y + 1 }, { 2, 2 } };
			for (unsigned k = 0; k < 4; k++) {
				int px = pts[k][0], py = pts[k][1], r, g, b, bits;
				if (px < 0 || py < 0 || px >= (int)fb->width || py >= (int)fb->height) continue;
				decode(fb->pixel_format, map + (size_t)py * fb->pitches[0] + (size_t)px * 4, &r, &g, &b, &bits);
				printf("  (%d,%d) %d-bit R=%d G=%d B=%d\n", px, py, bits, r, g, b);
			}
			munmap(map, len);
next:
			drmModeFreeFB2(fb);
			drmModeFreePlane(pl);
		}
		drmModeFreePlaneResources(pr);
		close(fd);
	}
	return 0;
}
