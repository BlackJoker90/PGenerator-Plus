/*
 * pg_v4l2_player: H.264 Annex-B/AUD -> bcm2835 stateful V4L2 decoder ->
 * exported DMA-BUF -> vc4 overlay. No decoded pixels are mapped or copied.
 * Root, with PGeneratord stopped. Raw kernel ioctls; no libdrm dependency.
 *
 * Usage: pg_v4l2_player [width height [connector [fps [space [range [ready [sar [refresh [timing]]]]]]]]]
 * fps and sar are positive rationals (e.g. 60000/1001 and 1/1). CFR only.
 * space: auto, bt709, bt470bg, smpte170m, bt2020nc. range: auto,tv,pc.
 * The daemon normally resets the connector when stopping the renderer.
 * Verify exposed SDR properties ourselves before any modeset; refuse stale
 * HDR/DOVI/YCbCr/deep-colour state, rather than trusting that reset. Exact
 * configured timing includes interlace. This is NOT a bit-exact source.
 *
 * Kernel 5.10 documentation used:
 * userspace-api/media/v4l/dev-decoder.html sections 4.5.1.5 Initialization,
 * 4.5.1.6 Capture Setup (COMPOSE = visible pixels, MIN_BUFFERS + pipeline),
 * 4.5.1.7 Decoding (CAPTURE is display order), 4.5.1.9 Dynamic Resolution
 * Change (drain LAST, stop/reallocate CAPTURE only), 4.5.1.10 Drain.
 * userspace-api/media/v4l/pixfmt-yuv420.html / pixfmt-nv12.html: contiguous
 * Y/chroma pitch and offsets; VIDIOC_EXPBUF exports the single memory plane.
 * gpu/drm-kms.html: drm_mode_config_funcs.atomic_commit (completion event);
 * gpu/drm-uapi.html: DRM_EVENT_FLIP_COMPLETE. Atomic NONBLOCK + flip event,
 * without ASYNC, latches on vblank. The event retires the PREVIOUS scanout;
 * only then may its CAPTURE index be QBUF'd. Legacy SETPLANE alone does not
 * provide this lifetime notification. A black dumb primary supplies borders.
 */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits.h>

#define AU_LIMIT (16u * 1024u * 1024u)
struct rational { uint32_t n, d; };
struct options {
 uint32_t width, height, connector;
 struct rational fps, sar;
 int encoding, full; /* -1 = infer matrix from visible height */
 const char *ready;
 double refresh; /* configured output Hz, 0 requires a usable active CRTC */
 const char *timing;
};
struct rectangle { uint32_t x, y, w, h; };

static int number(const char *s, uint32_t *v, uint32_t max) {
 char *end;
 unsigned long n;
 if (!s || *s < '0' || *s > '9') return -1;
 errno = 0; n = strtoul(s, &end, 10);
 if (errno || *end || n > max) return -1;
 *v = (uint32_t)n; return 0;
}
static int rational(const char *s, struct rational *r) {
 char a[32]; const char *slash = strchr(s, '/');
 if (slash) {
  size_t n = (size_t)(slash-s);
  if (!n || n >= sizeof(a)) return -1;
  memcpy(a, s, n); a[n] = 0;
  if (number(a, &r->n, 1000000) || number(slash+1, &r->d, 1000000)) return -1;
 } else { if (number(s, &r->n, 1000000)) return -1; r->d = 1; }
 return r->n && r->d ? 0 : -1;
}
static int refresh_value(const char *s, double *rate) {
 char *end; const char *p; int dots=0;
 struct rational r;
 if (strchr(s,'/')) { if (rational(s,&r)) return -1; *rate=(double)r.n/r.d; }
 else {
  if (!*s) return -1;
  for (p=s; *p; p++) if ((*p<'0' || *p>'9') && (*p!='.' || ++dots>1)) return -1;
  errno=0; *rate=strtod(s,&end); if (errno || *end) return -1;
 }
 return *rate==0 || (*rate>=1 && *rate<=240) ? 0 : -1;
}
static int parse_options(int argc, char **argv, struct options *o) {
 *o = (struct options){1920,1080,0,{25,1},{1,1},-1,0,NULL,0,NULL};
 if (argc > 11 || argc == 2) return -1;
 if (argc > 2 && (number(argv[1], &o->width, 16384) || !o->width ||
                  number(argv[2], &o->height, 16384) || !o->height)) return -1;
 if (argc > 3 && number(argv[3], &o->connector, UINT32_MAX)) return -1;
 if (argc > 4 && (rational(argv[4], &o->fps) ||
     (uint64_t)o->fps.n > 240ULL*o->fps.d || o->fps.n < o->fps.d)) return -1;
 if (argc > 5) {
  const char *s = argv[5];
  if (!strcmp(s,"bt709")) o->encoding = 1;
  else if (!strcmp(s,"bt470bg") || !strcmp(s,"smpte170m")) o->encoding = 0;
  else if (!strcmp(s,"bt2020nc")) o->encoding = 2;
  /* vc4's BT.2020 matrix is non-constant luminance; never silently use it for CL. */
  else if (strcmp(s,"auto") && strcmp(s,"unknown")) return -1;
 }
 if (argc > 6) {
  if (!strcmp(argv[6],"pc")) o->full = 1;
  else if (strcmp(argv[6],"tv") && strcmp(argv[6],"auto") && strcmp(argv[6],"unknown")) return -1;
 }
 if (argc > 7 && strcmp(argv[7],"-")) o->ready = argv[7];
 if (argc > 8 && rational(argv[8], &o->sar)) return -1;
 if (argc > 9 && refresh_value(argv[9], &o->refresh)) return -1;
 if (argc > 10 && strcmp(argv[10],"-")) o->timing=argv[10];
 return 0;
}
static int player_result(int failed, int was_stopped, uint64_t shown) {
 if (was_stopped) return 0;
 return failed ? (shown ? 3 : 1) : 0;
}
static int matrix(const struct options *o, unsigned height) {
 return o->encoding >= 0 ? o->encoding : (height > 576 ? 1 : 0);
}
static int64_t frame_time(uint64_t frame, struct rational fps) {
 return (int64_t)((long double)frame*1000000000.0L*fps.d/fps.n);
}
static struct rectangle aspect_fit(uint32_t w, uint32_t h, uint32_t mw, uint32_t mh,
                                   struct rational sar) {
 struct rectangle r = {0,0,mw,mh};
 uint64_t sw = (uint64_t)w*sar.n, sh = (uint64_t)h*sar.d;
 if (sw*mh > sh*mw) r.h = (uint32_t)(sh*mw/sw);
 else r.w = (uint32_t)(sw*mh/sh);
 if (!r.w) r.w = 1;
 if (!r.h) r.h = 1;
 r.x = (mw-r.w)/2; r.y = (mh-r.h)/2;
 return r;
}
/* Incremental scanner. Leaves a partial start code/header for the next read.
 * A preamble before the first AUD stays with that first access unit. */
struct annexb { unsigned char *data; size_t len, scan; int aud; };
static size_t access_unit(struct annexb *a, int eof) {
 while (a->scan+4 <= a->len) {
  size_t p = a->scan, header = 0;
  if (!a->data[p] && !a->data[p+1]) {
   if (a->data[p+2] == 1) header = p+3;
   else if (!a->data[p+2]) {
    if (p+5 > a->len) break;
    if (a->data[p+3] == 1) header = p+4;
   }
  }
  if (header && (a->data[header]&31) == 9) {
   if (a->aud) return p;
   a->aud = 1;
  }
  a->scan = header ? header+1 : p+1;
 }
 return eof && a->aud ? a->len : 0;
}
static void consume_unit(struct annexb *a, size_t n) {
 memmove(a->data, a->data+n, a->len-n);
 a->len -= n; a->scan = 0; a->aud = 0;
}

#ifndef PG_V4L2_CORE_ONLY
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/videodev2.h>
#include <drm.h>
#include <drm_mode.h>
#include <drm_fourcc.h>
#include "pg_drm_mode.h"
#include "pg_drm_sdr.h"

#define PTR(x) ((uint64_t)(uintptr_t)(x))
#ifndef DRM_PLANE_TYPE_OVERLAY
#define DRM_PLANE_TYPE_OVERLAY 0
#endif
#define MAX_BUFS 64
#define OUT_TYPE V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE
#define CAP_TYPE V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
static volatile sig_atomic_t stopping;
static int drm_fd = -1, video_fd = -1, out_on, cap_on;
static struct options opt;
static void stop_signal(int sig) { (void)sig; stopping = 1; }
static int xioctl(int fd, unsigned long req, void *arg) {
 int r;
 do { r = ioctl(fd,req,arg); } while (r < 0 && errno == EINTR && !stopping);
 return r;
}
static int fail(const char *what) {
 fprintf(stderr,"pg_v4l2_player: %s: %s\n",what,strerror(errno)); return -1;
}
static int64_t now_ns(void) {
 struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
 return (int64_t)t.tv_sec*1000000000LL+t.tv_nsec;
}
struct output_buffer { void *map; size_t size; int busy; };
struct capture_buffer { int fd; uint32_t handle, fb; size_t size; };
static struct output_buffer output[MAX_BUFS];
static struct capture_buffer capture[MAX_BUFS];
static unsigned nout, ncap;
static struct drm_mode_crtc saved;
static uint32_t saved_connectors[32], nsaved;
static int have_saved, changed;
static uint32_t connector, crtc, crtc_index, plane;
static struct drm_mode_modeinfo mode;
static struct v4l2_rect crop;
static struct rectangle dest;
static uint32_t black_handle, black_fb;
static int current=-1,pending=-1;
struct decoded_frame {unsigned index;uint64_t slot;int last;};
static struct decoded_frame ready[2];
static unsigned ready_count;
static uint64_t decoded_slots,pending_slot,reanchors;
static int capture_ended;
static int64_t pace_epoch;
static int pending_last, change_pending, last_seen, draining;
static uint64_t frames, dropped_frames, late_drops;
static int64_t first_frame, last_frame, report_time, start_time;
/* Plane properties are discovered by name, including enum VALUES. */
static const char *property_names[] = {"FB_ID","CRTC_ID","SRC_X","SRC_Y","SRC_W","SRC_H",
 "CRTC_X","CRTC_Y","CRTC_W","CRTC_H","COLOR_ENCODING","COLOR_RANGE"};
static uint32_t props[12];
static uint64_t colour[2], old_colour[2];

static int get_connector(uint32_t id, struct drm_mode_get_connector *c,
                         struct drm_mode_modeinfo *m, uint32_t *enc) {
 uint32_t p[128]; uint64_t v[128];
 memset(c,0,sizeof(*c)); c->connector_id = id;
 if (xioctl(drm_fd,DRM_IOCTL_MODE_GETCONNECTOR,c)) return -1;
 if (c->count_modes > 128 || c->count_encoders > 32 || c->count_props > 128) { errno=EOVERFLOW; return -1; }
 c->modes_ptr=PTR(m); c->encoders_ptr=PTR(enc); c->props_ptr=PTR(p); c->prop_values_ptr=PTR(v);
 if (xioctl(drm_fd,DRM_IOCTL_MODE_GETCONNECTOR,c)) return -1;
 if (c->count_modes>128 || c->count_encoders>32 || c->count_props>128) { errno=EOVERFLOW; return -1; }
 return 0;
}
static const char *mode_choice="unselected";
static double mode_hz(const struct drm_mode_modeinfo *m) {
 double hz;
 if (!m->clock || !m->htotal || !m->vtotal) return m->vrefresh;
 hz=(double)m->clock*1000.0/m->htotal/m->vtotal;
 if (m->flags&DRM_MODE_FLAG_INTERLACE) hz*=2;
 if (m->flags&DRM_MODE_FLAG_DBLSCAN) hz/=2;
 if (m->vscan>1) hz/=m->vscan;
 return hz;
}
static int same_timing(const struct drm_mode_modeinfo *a, const struct drm_mode_modeinfo *b) {
 return a->clock==b->clock && a->hdisplay==b->hdisplay && a->hsync_start==b->hsync_start &&
  a->hsync_end==b->hsync_end && a->htotal==b->htotal && a->hskew==b->hskew &&
  a->vdisplay==b->vdisplay && a->vsync_start==b->vsync_start && a->vsync_end==b->vsync_end &&
  a->vtotal==b->vtotal && a->vscan==b->vscan && (a->flags&~DRM_MODE_FLAG_PIC_AR_MASK)==(b->flags&~DRM_MODE_FLAG_PIC_AR_MASK);
}
static int select_mode(const struct drm_mode_crtc *active,
                       const struct drm_mode_modeinfo *modes, unsigned count) {
 unsigned i; int hit=-1;
 if(opt.timing) {
  struct drm_mode_modeinfo want;
  if(pg_drm_mode_parse(opt.timing,&want) || want.hdisplay!=opt.width || want.vdisplay!=opt.height) {
   errno=EINVAL;return fail("invalid configured timing");
  }
  if(active->mode_valid && same_timing(&active->mode,&want)) {
   mode=active->mode;mode_choice="active-exact";return 0;
  }
  for(i=0;i<count;i++) if(same_timing(&modes[i],&want)) {
   mode=modes[i];mode_choice="configured-exact";return 0;
  }
  errno=EINVAL;return fail("exact configured timing not advertised");
 }
 double active_delta=mode_hz(&active->mode)-opt.refresh;
 if (active->mode_valid && active->mode.hdisplay==opt.width && active->mode.vdisplay==opt.height &&
     (opt.refresh==0 || (active_delta>=-0.011 && active_delta<=0.011))) {
  mode=active->mode; mode_choice="active"; return 0; /* Full timings/flags survive; never infer from list order. */
 }
 if (opt.refresh<=0) { errno=EINVAL; return fail("inactive/mismatched CRTC needs configured refresh"); }
 for (i=0; i<count; i++) {
  double delta=mode_hz(&modes[i])-opt.refresh;
  /* modetest prints hundredths of Hz. This tolerance accepts that rounding
   * while distinguishing 23.976/24 and 59.94/60 Hz. */
  if (modes[i].hdisplay!=opt.width || modes[i].vdisplay!=opt.height || delta < -0.011 || delta > 0.011) continue;
  if (hit>=0 && !same_timing(&modes[hit],&modes[i])) {
   errno=EINVAL; return fail("configured refresh has ambiguous timings");
  }
  hit=(int)i;
 }
 if (hit<0) { errno=EINVAL; return fail("configured output timing not advertised"); }
 mode=modes[hit]; mode_choice="configured"; return 0;
}
static int choose_drm(void) {
 unsigned card, i, j;
 for (card=0; card<16; card++) {
  char path[40]; struct drm_mode_card_res r = {0};
  uint32_t crtcs[32], conns[32], encs[128], fbs[128];
  struct drm_set_client_cap cap = {DRM_CLIENT_CAP_ATOMIC,1};
  snprintf(path,sizeof(path),"/dev/dri/card%u",card);
  drm_fd=open(path,O_RDWR|O_CLOEXEC|O_NONBLOCK);
  if (drm_fd<0) continue;
  if (xioctl(drm_fd,DRM_IOCTL_SET_MASTER,NULL)) goto skip;
  if (xioctl(drm_fd,DRM_IOCTL_SET_CLIENT_CAP,&cap)) goto skip;
  /* ATOMIC also enables picture-aspect flags. Match the renderer/modetest
   * view: ofxRPI4Window.cpp disables ASPECT_RATIO immediately after ATOMIC. */
  cap.capability=DRM_CLIENT_CAP_ASPECT_RATIO;cap.value=0;
  if (xioctl(drm_fd,DRM_IOCTL_SET_CLIENT_CAP,&cap)) goto skip;
  if (xioctl(drm_fd,DRM_IOCTL_MODE_GETRESOURCES,&r)) goto skip;
  if (r.count_crtcs>32 || r.count_connectors>32 || r.count_encoders>128 || r.count_fbs>128) goto skip;
  r.crtc_id_ptr=PTR(crtcs); r.connector_id_ptr=PTR(conns);
  r.encoder_id_ptr=PTR(encs); r.fb_id_ptr=PTR(fbs);
  if (xioctl(drm_fd,DRM_IOCTL_MODE_GETRESOURCES,&r)) goto skip;
  if (r.count_crtcs>32 || r.count_connectors>32 || r.count_encoders>128 || r.count_fbs>128) goto skip;
  for (i=0; i<r.count_connectors; i++) {
   struct drm_mode_get_connector c; struct drm_mode_modeinfo m[128]; uint32_t e[32];
   struct drm_mode_get_encoder en = {0};
   if (get_connector(conns[i],&c,m,e)) continue;
   if (opt.connector ? c.connector_id!=opt.connector :
       (c.connector_type!=DRM_MODE_CONNECTOR_HDMIA && c.connector_type!=DRM_MODE_CONNECTOR_HDMIB)) continue;
   if (c.connection!=1 || !c.count_modes) continue; /* Never force an EDID-less output. */
   crtc=0; en.encoder_id=c.encoder_id;
   if (en.encoder_id && !xioctl(drm_fd,DRM_IOCTL_MODE_GETENCODER,&en)) crtc=en.crtc_id;
   if (!crtc) {
    for (j=0; j<c.count_encoders && !crtc; j++) {
     unsigned k; en.encoder_id=e[j];
     if (xioctl(drm_fd,DRM_IOCTL_MODE_GETENCODER,&en)) continue;
     for (k=0; k<r.count_crtcs; k++) if (en.possible_crtcs&(1u<<k)) { crtc=crtcs[k]; break; }
    }
   }
   if (!crtc) continue;
   for (crtc_index=0; crtc_index<r.count_crtcs; crtc_index++) if (crtcs[crtc_index]==crtc) break;
   if (crtc_index==r.count_crtcs) continue;
   memset(&saved,0,sizeof(saved)); saved.crtc_id=crtc;
   if (xioctl(drm_fd,DRM_IOCTL_MODE_GETCRTC,&saved)) continue;
   if (select_mode(&saved,m,c.count_modes)) continue;
   if (pg_drm_require_sdr(drm_fd,c.connector_id)) return -1;
   connector=c.connector_id; have_saved=1; nsaved=0;
   /* Preserve the actual connector routing, including an originally disabled CRTC. */
   for (j=0; j<r.count_connectors; j++) {
    struct drm_mode_get_connector c2; struct drm_mode_modeinfo m2[128]; uint32_t e2[32];
    if (get_connector(conns[j],&c2,m2,e2)) return fail("save connector routing");
    en.encoder_id=c2.encoder_id;
    if (en.encoder_id) {
     if (xioctl(drm_fd,DRM_IOCTL_MODE_GETENCODER,&en)) return fail("save encoder routing");
     if (en.crtc_id==crtc) saved_connectors[nsaved++]=c2.connector_id;
    }
   }
   fprintf(stderr,"pg_v4l2_player: %s connector=%u crtc=%u mode=%ux%u@%.3f CFR=%u/%u timing_source=%s\n",
    path,connector,crtc,mode.hdisplay,mode.vdisplay,mode_hz(&mode),opt.fps.n,opt.fps.d,mode_choice);
   return 0;
  }
 skip:
  xioctl(drm_fd,DRM_IOCTL_DROP_MASTER,NULL); close(drm_fd); drm_fd=-1;
 }
 errno=ENODEV; return fail("no usable HDMI DRM card (daemon stopped?)");
}
static int black_primary(void) {
 struct drm_mode_create_dumb d = {0}; struct drm_mode_map_dumb m = {0};
 struct drm_mode_fb_cmd fb = {0}; struct drm_mode_crtc c = {0}; void *map;
 d.width=mode.hdisplay; d.height=mode.vdisplay; d.bpp=32;
 if (xioctl(drm_fd,DRM_IOCTL_MODE_CREATE_DUMB,&d)) return fail("black CREATE_DUMB");
 black_handle=d.handle; m.handle=d.handle;
 if (xioctl(drm_fd,DRM_IOCTL_MODE_MAP_DUMB,&m)) return fail("black MAP_DUMB");
 map=mmap(NULL,d.size,PROT_READ|PROT_WRITE,MAP_SHARED,drm_fd,m.offset);
 if (map==MAP_FAILED) return fail("black mmap");
 memset(map,0,d.size); munmap(map,d.size);
 fb.width=d.width; fb.height=d.height; fb.pitch=d.pitch; fb.bpp=32; fb.depth=24; fb.handle=d.handle;
 if (xioctl(drm_fd,DRM_IOCTL_MODE_ADDFB,&fb)) return fail("black ADDFB");
 black_fb=fb.fb_id; c.crtc_id=crtc; c.fb_id=black_fb; c.mode=mode; c.mode_valid=1;
 c.set_connectors_ptr=PTR(&connector); c.count_connectors=1;
 if (xioctl(drm_fd,DRM_IOCTL_MODE_SETCRTC,&c)) return fail("black SETCRTC");
 changed=1; return 0;
}
static int plane_properties(uint32_t id, int encoding, int full) {
 struct drm_mode_obj_get_properties o = {0}; uint32_t ids[128]; uint64_t vals[128]; unsigned i,j;
 int overlay=0, found_colour[2]={0,0};
 o.obj_id=id; o.obj_type=DRM_MODE_OBJECT_PLANE;
 if (xioctl(drm_fd,DRM_IOCTL_MODE_OBJ_GETPROPERTIES,&o) || o.count_props>128) return -1;
 o.props_ptr=PTR(ids); o.prop_values_ptr=PTR(vals);
 if (xioctl(drm_fd,DRM_IOCTL_MODE_OBJ_GETPROPERTIES,&o) || o.count_props>128) return -1;
 memset(props,0,sizeof(props));
 for (i=0; i<o.count_props; i++) {
  struct drm_mode_get_property p = {0}; struct drm_mode_property_enum enums[64]; uint64_t values[64];
  p.prop_id=ids[i];
  if (xioctl(drm_fd,DRM_IOCTL_MODE_GETPROPERTY,&p) || p.count_enum_blobs>64 || p.count_values>64) return -1;
  p.enum_blob_ptr=PTR(enums); p.values_ptr=PTR(values);
  if (xioctl(drm_fd,DRM_IOCTL_MODE_GETPROPERTY,&p) || p.count_enum_blobs>64 || p.count_values>64) return -1;
  if (!strcmp(p.name,"type") && vals[i]==DRM_PLANE_TYPE_OVERLAY) overlay=1;
  /* Do not steal a plane already attached to another CRTC (or active here). */
  if (!strcmp(p.name,"CRTC_ID") && vals[i]) return -1;
  for (j=0; j<12; j++) if (!strcmp(p.name,property_names[j])) props[j]=p.prop_id;
  if (!strcmp(p.name,"COLOR_ENCODING") || !strcmp(p.name,"COLOR_RANGE")) {
   int k=!strcmp(p.name,"COLOR_RANGE"); unsigned n;
   const char *name = k ? (full ? "YCbCr full range" : "YCbCr limited range") :
     (encoding==2 ? "ITU-R BT.2020 YCbCr" : encoding==1 ? "ITU-R BT.709 YCbCr" : "ITU-R BT.601 YCbCr");
   old_colour[k]=vals[i];
   for (n=0; n<p.count_enum_blobs; n++) if (!strcmp(enums[n].name,name)) {
    colour[k]=enums[n].value; found_colour[k]=1;
   }
  }
 }
 for (i=0; i<12; i++) if (!props[i]) return -1;
 return overlay && found_colour[0] && found_colour[1] ? 0 : -1;
}
static int choose_plane(uint32_t format, int encoding) {
 struct drm_mode_get_plane_res r = {0}; uint32_t ids[128]; unsigned i,j;
 if (xioctl(drm_fd,DRM_IOCTL_MODE_GETPLANERESOURCES,&r) || r.count_planes>128) return fail("plane resources");
 r.plane_id_ptr=PTR(ids);
 if (xioctl(drm_fd,DRM_IOCTL_MODE_GETPLANERESOURCES,&r) || r.count_planes>128) return fail("planes");
 for (i=0; i<r.count_planes; i++) {
  struct drm_mode_get_plane p = {0}; uint32_t formats[128]; int supported=0;
  p.plane_id=ids[i];
  if (xioctl(drm_fd,DRM_IOCTL_MODE_GETPLANE,&p) || p.count_format_types>128) continue;
  p.format_type_ptr=PTR(formats);
  if (xioctl(drm_fd,DRM_IOCTL_MODE_GETPLANE,&p) || p.count_format_types>128) continue;
  if (!(p.possible_crtcs&(1u<<crtc_index))) continue;
  for (j=0; j<p.count_format_types; j++) if (formats[j]==format) supported=1;
  if (supported && !plane_properties(ids[i],encoding,opt.full)) { plane=ids[i]; return 0; }
 }
 errno=ENOTSUP; return fail("no idle overlay with format and colour properties");
}
static int commit_plane(uint32_t fb, int event) {
 uint32_t count=12; struct drm_mode_atomic a = {0};
 uint64_t values[12] = {fb,fb ? crtc : 0,(uint64_t)crop.left<<16,(uint64_t)crop.top<<16,
  (uint64_t)crop.width<<16,(uint64_t)crop.height<<16,dest.x,dest.y,dest.w,dest.h,colour[0],colour[1]};
 if (!fb) { count=2; }
 a.count_objs=1; a.objs_ptr=PTR(&plane); a.count_props_ptr=PTR(&count);
 a.props_ptr=PTR(props); a.prop_values_ptr=PTR(values);
 a.flags=event ? DRM_MODE_ATOMIC_NONBLOCK|DRM_MODE_PAGE_FLIP_EVENT : 0;
 a.user_data=1;
 if (xioctl(drm_fd,DRM_IOCTL_MODE_ATOMIC,&a)) return fail("atomic overlay commit");
 return 0;
}
static int restore_plane_colour(void) {
 struct drm_mode_atomic a = {0}; uint32_t count=2;
 a.count_objs=1; a.objs_ptr=PTR(&plane); a.count_props_ptr=PTR(&count);
 a.props_ptr=PTR(props+10); a.prop_values_ptr=PTR(old_colour);
 return xioctl(drm_fd,DRM_IOCTL_MODE_ATOMIC,&a) ? fail("restore overlay colour") : 0;
}
static int qcapture(unsigned index) {
 struct v4l2_buffer b = {0}; struct v4l2_plane p = {0};
 b.type=CAP_TYPE; b.memory=V4L2_MEMORY_MMAP; b.index=index; b.length=1; b.m.planes=&p;
 return xioctl(video_fd,VIDIOC_QBUF,&b) ? fail("CAPTURE QBUF") : 0;
}
static int release_capture(void) {
 unsigned i; enum v4l2_buf_type type=CAP_TYPE;
 /* Blocking disable retires ALL old scanout references even if a flip was
  * pending when SIGTERM arrived. Never return these buffers to the decoder. */
 if (plane && (commit_plane(0,0) || restore_plane_colour())) return -1;
 plane=0;
 if (cap_on && xioctl(video_fd,VIDIOC_STREAMOFF,&type)) return fail("CAPTURE STREAMOFF");
 cap_on=0;
 for (i=0; i<ncap; i++) {
  if (capture[i].fb && xioctl(drm_fd,DRM_IOCTL_MODE_RMFB,&capture[i].fb)) return fail("RMFB");
  if (capture[i].handle) {
   struct drm_gem_close c = {0}; c.handle=capture[i].handle;
   if (xioctl(drm_fd,DRM_IOCTL_GEM_CLOSE,&c)) return fail("GEM_CLOSE");
  }
  if (capture[i].fd>=0) close(capture[i].fd);
  capture[i]=(struct capture_buffer){-1,0,0,0};
 }
 ncap=0; current=pending=-1;ready_count=0;capture_ended=0;
 if (video_fd>=0) {
  struct v4l2_requestbuffers r = {0}; r.type=CAP_TYPE; r.memory=V4L2_MEMORY_MMAP;
  if (xioctl(video_fd,VIDIOC_REQBUFS,&r)) return fail("release CAPTURE buffers");
 }
 return 0;
}
static int setup_capture(void) {
 struct v4l2_format f = {0}; struct v4l2_selection s = {0};
 struct v4l2_control min = {0}; struct v4l2_requestbuffers r = {0};
 struct v4l2_pix_format_mplane *pix=&f.fmt.pix_mp;
 enum v4l2_buf_type type=CAP_TYPE;
 uint32_t format, pitch, height; uint64_t ysize, total; unsigned i;
 f.type=CAP_TYPE;
 if (xioctl(video_fd,VIDIOC_G_FMT,&f)) return fail("CAPTURE G_FMT");
 if (pix->pixelformat!=V4L2_PIX_FMT_YUV420 && pix->pixelformat!=V4L2_PIX_FMT_NV12) {
  pix->pixelformat=V4L2_PIX_FMT_YUV420;
  if (xioctl(video_fd,VIDIOC_S_FMT,&f)) return fail("CAPTURE S_FMT YU12");
 }
 format=pix->pixelformat; pitch=pix->plane_fmt[0].bytesperline; height=pix->height;
 if ((format!=V4L2_PIX_FMT_YUV420 && format!=V4L2_PIX_FMT_NV12) || pix->num_planes!=1 ||
     !pix->width || !height || pix->width>16384 || height>16384 || pitch<pix->width || (pitch&1) || (height&1)) {
  errno=ENOTSUP; return fail("unsupported CAPTURE layout");
 }
 s.type=CAP_TYPE; s.target=V4L2_SEL_TGT_COMPOSE;
 if (xioctl(video_fd,VIDIOC_G_SELECTION,&s)) {
  s.target=V4L2_SEL_TGT_CROP;
  if (xioctl(video_fd,VIDIOC_G_SELECTION,&s)) return fail("visible CAPTURE selection");
 }
 crop=s.r;
 if (crop.left<0 || crop.top<0 || !crop.width || !crop.height ||
     (uint64_t)crop.left+crop.width>pix->width || (uint64_t)crop.top+crop.height>height) {
  errno=EINVAL; return fail("invalid visible crop");
 }
 if (choose_plane(format,matrix(&opt,crop.height))) return -1;
 dest=aspect_fit(crop.width,crop.height,mode.hdisplay,mode.vdisplay,opt.sar);
 min.id=V4L2_CID_MIN_BUFFERS_FOR_CAPTURE;
 if (xioctl(video_fd,VIDIOC_G_CTRL,&min)) return fail("MIN_BUFFERS_FOR_CAPTURE");
 if (min.value<1 || min.value>MAX_BUFS-4) { errno=EOVERFLOW; return fail("CAPTURE minimum"); }
 r.type=CAP_TYPE; r.memory=V4L2_MEMORY_MMAP; r.count=min.value+4;
 if (xioctl(video_fd,VIDIOC_REQBUFS,&r)) return fail("CAPTURE REQBUFS");
 if (r.count>MAX_BUFS || r.count<(unsigned)min.value+4) { errno=ENOMEM; return fail("insufficient CAPTURE spare buffers"); }
 ncap=r.count;
 ysize=(uint64_t)pitch*height; total=ysize+ysize/2;
 if (total>UINT32_MAX) { errno=EOVERFLOW; return fail("CAPTURE size"); }
 for (i=0; i<ncap; i++) {
  struct v4l2_buffer b = {0}; struct v4l2_plane p = {0};
  struct v4l2_exportbuffer e = {0}; struct drm_prime_handle prime = {0};
  struct drm_mode_fb_cmd2 fb = {0};
  b.type=CAP_TYPE; b.memory=V4L2_MEMORY_MMAP; b.index=i; b.length=1; b.m.planes=&p;
  if (xioctl(video_fd,VIDIOC_QUERYBUF,&b)) return fail("CAPTURE QUERYBUF");
  if (p.length<total) { errno=EINVAL; return fail("short CAPTURE allocation"); }
  capture[i].size=p.length;
  e.type=CAP_TYPE; e.index=i; e.flags=O_CLOEXEC;
  if (xioctl(video_fd,VIDIOC_EXPBUF,&e)) return fail("CAPTURE EXPBUF");
  capture[i].fd=e.fd; prime.fd=e.fd;
  if (xioctl(drm_fd,DRM_IOCTL_PRIME_FD_TO_HANDLE,&prime)) return fail("PRIME import");
  capture[i].handle=prime.handle;
  fb.width=pix->width; fb.height=height; fb.pixel_format=format;
  fb.handles[0]=fb.handles[1]=prime.handle; fb.pitches[0]=pitch; fb.offsets[1]=(uint32_t)ysize;
  if (format==V4L2_PIX_FMT_YUV420) {
   fb.handles[2]=prime.handle; fb.pitches[1]=fb.pitches[2]=pitch/2;
   fb.offsets[2]=(uint32_t)(ysize+ysize/4);
  } else fb.pitches[1]=pitch;
  if (xioctl(drm_fd,DRM_IOCTL_MODE_ADDFB2,&fb)) return fail("DMA-BUF ADDFB2");
  capture[i].fb=fb.fb_id;
  if (qcapture(i)) return -1;
 }
 if (xioctl(video_fd,VIDIOC_STREAMON,&type)) return fail("CAPTURE STREAMON");
 cap_on=1; change_pending=last_seen=capture_ended=0;ready_count=0;
 fprintf(stderr,"pg_v4l2_player: CAPTURE %.4s %ux%u pitch=%u visible=%d,%d %ux%u min=%d spare=4 buffers=%u overlay=%u dest=%u,%u %ux%u BT.%s %s\n",
  (char *)&format,pix->width,height,pitch,crop.left,crop.top,crop.width,crop.height,min.value,ncap,plane,
  dest.x,dest.y,dest.w,dest.h,matrix(&opt,crop.height)==2?"2020":matrix(&opt,crop.height)==1?"709":"601",opt.full?"full":"limited");
 return 0;
}
static int setup_decoder(void) {
 struct v4l2_capability c = {0}; struct v4l2_format f = {0};
 struct v4l2_event_subscription sub = {0}; struct v4l2_requestbuffers r = {0};
 enum v4l2_buf_type type=OUT_TYPE; unsigned i; uint32_t caps;
 video_fd=open("/dev/video10",O_RDWR|O_NONBLOCK|O_CLOEXEC);
 if (video_fd<0) return fail("open /dev/video10");
 if (xioctl(video_fd,VIDIOC_QUERYCAP,&c)) return fail("QUERYCAP");
 caps=c.capabilities&V4L2_CAP_DEVICE_CAPS ? c.device_caps : c.capabilities;
 if (strcmp((char *)c.card,"bcm2835-codec-decode") ||
     !(caps&V4L2_CAP_VIDEO_M2M_MPLANE) || !(caps&V4L2_CAP_STREAMING)) {
  errno=ENODEV; return fail("not the bcm2835 stateful decoder");
 }
 sub.type=V4L2_EVENT_SOURCE_CHANGE;
 if (xioctl(video_fd,VIDIOC_SUBSCRIBE_EVENT,&sub)) return fail("subscribe SOURCE_CHANGE");
 /* Leave the coded size unset (the driver's 32x32 default): CAPTURE is set
  * up only from SOURCE_CHANGE, and bcm2835-codec queues that event only
  * when the parsed stream differs from the configured size. Measured on
  * the Pi 4 (5.10.89): OUTPUT 1920x1080 with a 1080p stream gave no event
  * in 3 s; 0x0 or 1280x720 gave one after 0.16 s with CAPTURE 1920x1088.
  * opt.width/height are the display mode, not the stream. */
 f.type=OUT_TYPE; f.fmt.pix_mp.width=0; f.fmt.pix_mp.height=0;
 f.fmt.pix_mp.pixelformat=V4L2_PIX_FMT_H264; f.fmt.pix_mp.num_planes=1;
 f.fmt.pix_mp.plane_fmt[0].sizeimage=4*1024*1024;
 if (xioctl(video_fd,VIDIOC_S_FMT,&f)) return fail("OUTPUT S_FMT");
 if (f.fmt.pix_mp.pixelformat!=V4L2_PIX_FMT_H264 || f.fmt.pix_mp.num_planes!=1) {
  errno=ENOTSUP; return fail("OUTPUT H264 format");
 }
 r.type=OUT_TYPE; r.memory=V4L2_MEMORY_MMAP; r.count=8;
 if (xioctl(video_fd,VIDIOC_REQBUFS,&r)) return fail("OUTPUT REQBUFS");
 if (!r.count || r.count>MAX_BUFS) { errno=ENOMEM; return fail("OUTPUT count"); }
 nout=r.count;
 fprintf(stderr,"pg_v4l2_player: OUTPUT H264 sizeimage=%u requested=%u buffers=%u\n",
  f.fmt.pix_mp.plane_fmt[0].sizeimage,4u*1024u*1024u,nout);
 for (i=0; i<nout; i++) {
  struct v4l2_buffer b = {0}; struct v4l2_plane p = {0};
  b.type=OUT_TYPE; b.memory=V4L2_MEMORY_MMAP; b.index=i; b.length=1; b.m.planes=&p;
  if (xioctl(video_fd,VIDIOC_QUERYBUF,&b)) return fail("OUTPUT QUERYBUF");
  output[i].size=p.length;
  if(i==0)fprintf(stderr,"pg_v4l2_player: OUTPUT allocation=%u bytes per buffer\n",p.length);
  output[i].map=mmap(NULL,p.length,PROT_READ|PROT_WRITE,MAP_SHARED,video_fd,p.m.mem_offset);
  if (output[i].map==MAP_FAILED) { output[i].map=NULL; return fail("OUTPUT mmap"); }
 }
 if (xioctl(video_fd,VIDIOC_STREAMON,&type)) return fail("OUTPUT STREAMON");
 out_on=1; return 0;
}
static int decoder_events(void) {
 struct v4l2_event e;
 while (!xioctl(video_fd,VIDIOC_DQEVENT,&e))
  if (e.type==V4L2_EVENT_SOURCE_CHANGE && (e.u.src_change.changes&V4L2_EVENT_SRC_CH_RESOLUTION)) {
   if (!cap_on) { if (setup_capture()) return -1; }
   else change_pending=1;
  }
 /* v4l2-event.c::__v4l2_event_dequeue returns ENOENT for an empty queue
  * on O_NONBLOCK descriptors. Accept EAGAIN too; do not conflate DQBUF. */
 return errno==ENOENT || errno==EAGAIN ? 0 : fail("DQEVENT");
}
static int output_done(void) {
 struct v4l2_buffer b = {0}; struct v4l2_plane p = {0};
 b.type=OUT_TYPE; b.memory=V4L2_MEMORY_MMAP; b.length=1; b.m.planes=&p;
 while (!xioctl(video_fd,VIDIOC_DQBUF,&b)) {
  if (b.index>=nout) { errno=EIO; return fail("OUTPUT index"); }
  if (b.flags&V4L2_BUF_FLAG_ERROR)
   fprintf(stderr,"pg_v4l2_player: decoder reported errored OUTPUT buffer %u\n",b.index);
  output[b.index].busy=0;
 }
 /* VIDIOC_QBUF/DQBUF uAPI: EAGAIN means no completed buffer with
  * O_NONBLOCK; unlike DQEVENT, ENOENT is an actual failure here. */
 return errno==EAGAIN ? 0 : fail("OUTPUT DQBUF");
}
static void stats(void) {
 int64_t now=now_ns();
 if (frames>1) fprintf(stderr,"pg_v4l2_player: presented=%llu elapsed=%.3f fps=%.3f (flip events, CFR target=%.6f) late_drops=%llu error_drops=%llu reanchors=%llu\n",
  (unsigned long long)frames,(last_frame-first_frame)/1e9,
  (frames-1)*1e9/(last_frame-first_frame),(double)opt.fps.n/opt.fps.d,
  (unsigned long long)late_drops,(unsigned long long)dropped_frames,(unsigned long long)reanchors);
 report_time=now;
}
static int flip_done(void) {
 unsigned char data[1024]; ssize_t n; size_t pos=0;
 n=read(drm_fd,data,sizeof(data));
 if (n<0) return errno==EAGAIN || errno==EINTR ? 0 : fail("DRM event read");
 if (!n) { errno=EIO; return fail("DRM event EOF"); }
 while (pos+sizeof(struct drm_event)<=(size_t)n) {
  struct drm_event e; memcpy(&e,data+pos,sizeof(e));
  if (e.length<sizeof(e) || pos+e.length>(size_t)n) { errno=EIO; return fail("DRM event length"); }
  if (e.type==DRM_EVENT_FLIP_COMPLETE && pending>=0) {
   if (current>=0 && qcapture(current)) return -1;
   current=pending; pending=-1; last_frame=now_ns();
   if (!frames++) {
    first_frame=report_time=last_frame;
    pace_epoch=first_frame-frame_time(pending_slot,opt.fps);
    fprintf(stderr,"pg_v4l2_player: first frame presented; zero-copy H.264; SDR connector properties verified, timing_source=%s\n",mode_choice);
    if (opt.ready) {
     int fd=open(opt.ready,O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC|O_NOFOLLOW,0600);
     if (fd<0) return fail("first-frame marker");
     if (write(fd,"ready\n",6)!=6) { close(fd); return fail("write first-frame marker"); }
     if (close(fd)) return fail("close first-frame marker");
    }
   }
   if (pending_last) { last_seen=1; pending_last=0; }
   if (last_frame-report_time>=5000000000LL) stats();
  }
  pos+=e.length;
 }
 return 0;
}
static int playback(void) {
 struct annexb a = {0}; int eof=0, result=-1; uint64_t queued=0;
 int flags=fcntl(STDIN_FILENO,F_GETFL); int64_t due=0;
 a.data=malloc(AU_LIMIT);
 if (!a.data) return fail("Annex-B buffer");
 if (flags<0 || fcntl(STDIN_FILENO,F_SETFL,flags|O_NONBLOCK)<0) goto done;
 while (!stopping) {
  unsigned i; size_t unit; int64_t now=now_ns();
  if (frames && now-last_frame>10000000000LL) { errno=ETIMEDOUT; fail("no presented frame for 10 seconds"); goto done; }
  if (!frames && now-start_time>5000000000LL) { errno=ETIMEDOUT; fail("no first frame within 5 seconds"); goto done; }
  if (decoder_events() || output_done()) goto done;
  unit=access_unit(&a,eof);
  for (i=0; i<nout && unit; i++) if (!output[i].busy) {
   struct v4l2_buffer b = {0}; struct v4l2_plane p = {0};
   if (unit>output[i].size) { fprintf(stderr,"pg_v4l2_player: access unit=%zu OUTPUT allocation=%zu\n",unit,output[i].size); errno=EOVERFLOW; fail("access unit exceeds OUTPUT buffer"); goto done; }
   memcpy(output[i].map,a.data,unit); /* Compressed bytes ONLY. */
   b.type=OUT_TYPE; b.memory=V4L2_MEMORY_MMAP; b.index=i; b.length=1; b.m.planes=&p;
   b.timestamp.tv_sec=queued/1000000; b.timestamp.tv_usec=queued%1000000;
   p.bytesused=unit; p.length=output[i].size;
   if (xioctl(video_fd,VIDIOC_QBUF,&b)) { fail("OUTPUT QBUF"); goto done; }
   queued++; output[i].busy=1; consume_unit(&a,unit); unit=access_unit(&a,eof);
  }
  if (eof && !a.len && !draining) {
   struct v4l2_decoder_cmd cmd = {0}; cmd.cmd=V4L2_DEC_CMD_STOP;
   if (xioctl(video_fd,VIDIOC_DECODER_CMD,&cmd)) { fail("decoder drain STOP"); goto done; }
   draining=1;
  }
  /* Two dequeued candidates allow lookahead even while the prior atomic
   * flip is pending. MIN+4 covers current, pending, two candidates; never
   * borrow a buffer still owned by KMS. Drain only immediately ready frames. */
  while(cap_on && ready_count<2 && !capture_ended && !stopping) {
   struct v4l2_buffer b={0};struct v4l2_plane p={0};unsigned j;
   b.type=CAP_TYPE;b.memory=V4L2_MEMORY_MMAP;b.length=1;b.m.planes=&p;
   if(xioctl(video_fd,VIDIOC_DQBUF,&b)) {
    /* VIDIOC_QBUF/DQBUF uAPI: EAGAIN = not ready; EPIPE = exhausted
     * CAPTURE after LAST during decoder drain/dynamic source change. */
    if(errno==EAGAIN || errno==EPIPE)break;
    fail("CAPTURE DQBUF");goto done;
   }
   if(b.index>=ncap || b.index==(unsigned)current || b.index==(unsigned)pending) {
    errno=EIO;fail("CAPTURE index/scanout ownership");goto done;
   }
   for(j=0;j<ready_count;j++)if(ready[j].index==b.index){errno=EIO;fail("duplicate CAPTURE index");goto done;}
   if(!decoded_slots)fprintf(stderr,"pg_v4l2_player: first CAPTURE field=%u expected progressive=%u\n",b.field,V4L2_FIELD_NONE);
   if(b.flags&V4L2_BUF_FLAG_LAST)capture_ended=1;
   if(b.flags&V4L2_BUF_FLAG_ERROR) {
    decoded_slots++;dropped_frames++;
    fprintf(stderr,"pg_v4l2_player: skipped errored CAPTURE buffer %u (dropped=%llu)\n",b.index,(unsigned long long)dropped_frames);
    if(capture_ended)last_seen=1;else if(qcapture(b.index))goto done;
   }else {
    if(p.data_offset || p.bytesused>capture[b.index].size || b.field!=V4L2_FIELD_NONE) {
     errno=EIO;fail("CAPTURE layout (progressive 8-bit only)");goto done;
    }
    if(p.bytesused)ready[ready_count++]=(struct decoded_frame){b.index,decoded_slots++,capture_ended};
    else if(capture_ended)last_seen=1;
    else if(qcapture(b.index))goto done;
   }
  }
  if(last_seen && pending<0 && !ready_count) {
   if(change_pending){if(release_capture() || setup_capture())goto done;}
   else if(draining){result=0;goto done;}
  }
  now=now_ns();
  /* Drop only with a newer decoded replacement already in hand. This can
   * happen during a pending flip, so a small pool does not throttle decode
   * to the output refresh. A lone late frame remains useful: show it. */
  if(frames && ready_count==2 && now-pace_epoch>=frame_time(ready[0].slot+1,opt.fps)) {
   if(qcapture(ready[0].index))goto done;
   ready[0]=ready[1];ready_count=1;late_drops++;
   continue;
  }
  due=now;
  if(ready_count && pending<0) {
   if(frames && now-pace_epoch>=frame_time(ready[0].slot+1,opt.fps)) {
    pace_epoch=now-frame_time(ready[0].slot,opt.fps);reanchors++;
   }
   due=frames ? pace_epoch+frame_time(ready[0].slot,opt.fps)-
    (int64_t)(500000000.0/(mode_hz(&mode)>0?mode_hz(&mode):60)) : now;
   if(now>=due) {
    if(commit_plane(capture[ready[0].index].fb,1))goto done;
    pending=ready[0].index;pending_slot=ready[0].slot;pending_last=ready[0].last;
    ready_count--;if(ready_count)ready[0]=ready[1];
   }
  }
  {
   struct pollfd fds[3]; int timeout=50, r; int free_output=0;
   for (i=0; i<nout; i++) if (!output[i].busy) free_output=1;
   fds[0]=(struct pollfd){(!eof && !unit && a.len<AU_LIMIT)?STDIN_FILENO:-1,POLLIN,0};
   fds[1]=(struct pollfd){video_fd,POLLPRI | (!free_output?POLLOUT:0) |
        ((cap_on && ready_count<2 && !capture_ended)?POLLIN:0),0};
   fds[2]=(struct pollfd){drm_fd,pending>=0?POLLIN:0,0};
   if(ready_count && pending<0 && due>now){int ms=(int)((due-now+999999)/1000000);if(ms<timeout)timeout=ms;}
   if(frames && ready_count==2) {
    int64_t expires=pace_epoch+frame_time(ready[0].slot+1,opt.fps);
    int ms=expires>now?(int)((expires-now+999999)/1000000):0;
    if(ms<timeout)timeout=ms;
   }
   if (!eof && !unit && a.len==AU_LIMIT) { errno=EOVERFLOW; fail("Annex-B unit too large or missing AUD"); goto done; }
   r=poll(fds,3,timeout);
   if (r<0) { if (errno==EINTR) continue; fail("poll"); goto done; }
   if (fds[2].revents&POLLIN) { if (flip_done()) goto done; }
   if (fds[0].fd>=0 && (fds[0].revents&(POLLIN|POLLHUP))) {
    size_t want=AU_LIMIT-a.len; ssize_t n;
    if (want>65536) want=65536;
    n=read(STDIN_FILENO,a.data+a.len,want);
    if (n>0) a.len+=n;
    else if (!n) { eof=1; if (a.len && !access_unit(&a,1)) { errno=EINVAL; fail("input has no AUD"); goto done; } }
    else if (errno!=EAGAIN && errno!=EINTR) { fail("stdin read"); goto done; }
   }
   if ((fds[0].revents|fds[2].revents)&(POLLERR|POLLNVAL)) { errno=EIO; fail("pipe/DRM poll error"); goto done; }
   /* V4L2 can report POLLERR before CAPTURE is configured: not fatal. */
  }
 }
 result=0;
 done:
 fcntl(STDIN_FILENO,F_SETFL,flags); free(a.data); return result;
}
static void cleanup(void) {
 unsigned i; enum v4l2_buf_type type=OUT_TYPE;
 stats();
 /* Never requeue a scanned buffer on an error path. STREAMOFF stops the
  * decoder before exported buffers are destroyed, even if disable fails. */
 if (drm_fd>=0 && plane && commit_plane(0,0)) fprintf(stderr,"pg_v4l2_player: overlay disable failed\n");
 if (drm_fd>=0 && have_saved && changed) {
  saved.set_connectors_ptr=PTR(saved_connectors); saved.count_connectors=saved.mode_valid ? nsaved : 0;
  if (xioctl(drm_fd,DRM_IOCTL_MODE_SETCRTC,&saved)) fail("restore saved CRTC");
 }
 if (video_fd>=0) {
  if (out_on && xioctl(video_fd,VIDIOC_STREAMOFF,&type)) fail("OUTPUT STREAMOFF");
  type=CAP_TYPE;
  if (cap_on && xioctl(video_fd,VIDIOC_STREAMOFF,&type)) fail("CAPTURE STREAMOFF");
 }
 if (drm_fd>=0) {
  /* Restore colour of the formerly idle overlay, too. */
  if (plane) restore_plane_colour();
  for (i=0; i<ncap; i++) {
   struct drm_gem_close c = {0}; c.handle=capture[i].handle;
   if (capture[i].fb) xioctl(drm_fd,DRM_IOCTL_MODE_RMFB,&capture[i].fb);
   if (c.handle) xioctl(drm_fd,DRM_IOCTL_GEM_CLOSE,&c);
  }
  if (black_fb) xioctl(drm_fd,DRM_IOCTL_MODE_RMFB,&black_fb);
  if (black_handle) {
   struct drm_mode_destroy_dumb d = {0}; d.handle=black_handle;
   xioctl(drm_fd,DRM_IOCTL_MODE_DESTROY_DUMB,&d);
  }
  xioctl(drm_fd,DRM_IOCTL_DROP_MASTER,NULL); close(drm_fd); drm_fd=-1;
 }
 for (i=0; i<ncap; i++) if (capture[i].fd>=0) close(capture[i].fd);
 for (i=0; i<nout; i++) if (output[i].map) munmap(output[i].map,output[i].size);
 if (video_fd>=0) close(video_fd);
}
int main(int argc, char **argv) {
 struct sigaction sa; unsigned i; int result=1;
 start_time=now_ns(); /* Include decoder setup/connector probes/modeset in the deadline. */
 if (parse_options(argc,argv,&opt)) {
  fprintf(stderr,"Usage: pg_v4l2_player [width height [connector [fps [space [range [ready|- [sar [refresh [timing]]]]]]]]]\n"); return 2;
 }
 for (i=0; i<MAX_BUFS; i++) capture[i].fd=-1;
 memset(&sa,0,sizeof(sa)); sa.sa_handler=stop_signal; sigemptyset(&sa.sa_mask);
 sigaction(SIGTERM,&sa,NULL); sigaction(SIGINT,&sa,NULL);
 if (!setup_decoder() && !stopping && !choose_drm() && !stopping && !black_primary() && !stopping)
  result=playback() ? 1 : 0;
 cleanup(); return player_result(result,stopping,frames);
}
#endif
