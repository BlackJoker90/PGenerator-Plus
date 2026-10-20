/*
 * pgen_scanout: read back what the vc4 primary plane is scanning out, for the
 * PGenerator+ signal self-test. Needs root (GETFB2 only returns a buffer
 * handle to the DRM master or CAP_SYS_ADMIN); called through
 * PGenerator_cmd.pl SCANOUT_PROBE.
 *
 * Usage: pgen_scanout [x y w h]
 * Prints one line per scanned-out plane:
 *   FB card=<n> plane=<id> width=<w> height=<h> format=<fourcc> bits=<8|10>
 * and, when a region is given (default: 32x32 at the centre), the channel
 * minimum/maximum over every pixel of it:
 *   AREA x=<x> y=<y> w=<w> h=<h> r=<min>-<max> g=<min>-<max> b=<min>-<max>
 * Channels are the framebuffer components as stored: for YCbCr 4:4:4 the
 * renderer writes R=Cb G=Cr B=Y, for 4:2:2 R=Y G=Cb B=Cr.
 *
 * Build (pgen-build VM, bionic sysroot):
 *   arm-linux-gnueabihf-gcc-7 --sysroot=/work/sysroot -march=armv6 -mfpu=vfp
 *   -mfloat-abi=hard -marm -O2 -I/work/sysroot/usr/include/libdrm
 *   -o pgen_scanout pgen_scanout.c -ldrm
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

static int decode(uint32_t fmt, const uint8_t *p, int *r, int *g, int *b) {
	uint32_t v;
	memcpy(&v, p, 4);
	switch (fmt) {
	case DRM_FORMAT_XRGB2101010: case DRM_FORMAT_ARGB2101010:
		*r = (v >> 20) & 0x3ff; *g = (v >> 10) & 0x3ff; *b = v & 0x3ff; return 10;
	case DRM_FORMAT_XBGR2101010: case DRM_FORMAT_ABGR2101010:
		*b = (v >> 20) & 0x3ff; *g = (v >> 10) & 0x3ff; *r = v & 0x3ff; return 10;
	case DRM_FORMAT_XBGR8888: case DRM_FORMAT_ABGR8888:
		*r = p[0]; *g = p[1]; *b = p[2]; return 8;
	case DRM_FORMAT_XRGB8888: case DRM_FORMAT_ARGB8888:
		*b = p[0]; *g = p[1]; *r = p[2]; return 8;
	default:
		return 0;
	}
}

int main(int argc, char **argv) {
	int want_area = argc > 4;
	int ax = want_area ? atoi(argv[1]) : -1, ay = want_area ? atoi(argv[2]) : -1;
	int aw = want_area ? atoi(argv[3]) : 32, ah = want_area ? atoi(argv[4]) : 32;
	int found = 0;
	if (aw < 1 || ah < 1 || aw > 4096 || ah > 4096) {
		fprintf(stderr, "ERR bad region\n");
		return 2;
	}
	for (int c = 0; c < 3; c++) {
		char path[32];
		snprintf(path, sizeof(path), "/dev/dri/card%d", c);
		int fd = open(path, O_RDWR | O_CLOEXEC);
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
			int r, g, b;
			uint8_t probe[4] = { 0 };
			int bits = decode(fb->pixel_format, probe, &r, &g, &b);
			printf("FB card=%d plane=%u width=%u height=%u format=%s bits=%d\n",
			       c, pl->plane_id, fb->width, fb->height, fcc, bits);
			found++;
			if (!fb->handles[0]) { printf("ERR no-handle\n"); goto next; }
			if (!bits) { printf("ERR unsupported-format\n"); goto next; }
			if (fb->modifier != DRM_FORMAT_MOD_LINEAR && fb->modifier != DRM_FORMAT_MOD_INVALID) {
				printf("ERR tiled\n"); goto next;
			}
			struct drm_mode_map_dumb md = { .handle = fb->handles[0] };
			if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md)) { printf("ERR map-dumb\n"); goto next; }
			size_t len = (size_t)fb->pitches[0] * fb->height;
			uint8_t *map = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, md.offset);
			if (map == MAP_FAILED) { printf("ERR mmap\n"); goto next; }
			int x0 = ax >= 0 ? ax : ((int)fb->width - aw) / 2;
			int y0 = ay >= 0 ? ay : ((int)fb->height - ah) / 2;
			if (x0 < 0 || y0 < 0 || x0 + aw > (int)fb->width || y0 + ah > (int)fb->height) {
				printf("ERR region-outside\n");
			} else {
				int min[3] = { 4096, 4096, 4096 }, max[3] = { -1, -1, -1 };
				for (int y = y0; y < y0 + ah; y++) {
					for (int x = x0; x < x0 + aw; x++) {
						int v[3];
						decode(fb->pixel_format, map + (size_t)y * fb->pitches[0] + (size_t)x * 4, &v[0], &v[1], &v[2]);
						for (int k = 0; k < 3; k++) {
							if (v[k] < min[k]) min[k] = v[k];
							if (v[k] > max[k]) max[k] = v[k];
						}
					}
				}
				printf("AREA x=%d y=%d w=%d h=%d r=%d-%d g=%d-%d b=%d-%d\n",
				       x0, y0, aw, ah, min[0], max[0], min[1], max[1], min[2], max[2]);
			}
			munmap(map, len);
next:
			drmModeFreeFB2(fb);
			drmModeFreePlane(pl);
		}
		drmModeFreePlaneResources(pr);
		close(fd);
	}
	if (!found) printf("ERR no-plane\n");
	return found ? 0 : 1;
}
