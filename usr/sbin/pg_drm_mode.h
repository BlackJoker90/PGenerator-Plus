#ifndef PG_DRM_MODE_H
#define PG_DRM_MODE_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#ifndef DRM_MODE_FLAG_PIC_AR_MASK
#define DRM_MODE_FLAG_PIC_AR_MASK (15u << 19)
#endif
/* Picture-aspect flags describe the picture, not its scanout timing.
 * Exact modetest timing, shared by both raw-DRM diagnostic players.
 * clock:hd:hss:hse:ht:hskew:vd:vss:vse:vt:vscan:flags (decimal).
 * DRM refresh is field rate for interlaced timings, not modetest frame rate. */
static inline double pg_drm_mode_hz(const struct drm_mode_modeinfo *m) {
 double hz;
 if (!m->clock || !m->htotal || !m->vtotal) return m->vrefresh;
 hz=(double)m->clock*1000.0/m->htotal/m->vtotal;
 if (m->flags&DRM_MODE_FLAG_INTERLACE) hz*=2;
 if (m->flags&DRM_MODE_FLAG_DBLSCAN) hz/=2;
 if (m->vscan>1) hz/=m->vscan;
 return hz;
}
static inline int pg_drm_same_mode(const struct drm_mode_modeinfo *a,const struct drm_mode_modeinfo *b) {
 return a->clock==b->clock && a->hdisplay==b->hdisplay && a->hsync_start==b->hsync_start &&
  a->hsync_end==b->hsync_end && a->htotal==b->htotal && a->hskew==b->hskew &&
  a->vdisplay==b->vdisplay && a->vsync_start==b->vsync_start && a->vsync_end==b->vsync_end &&
  a->vtotal==b->vtotal && a->vscan==b->vscan && (a->flags&~DRM_MODE_FLAG_PIC_AR_MASK)==(b->flags&~DRM_MODE_FLAG_PIC_AR_MASK);
}
static inline int pg_drm_mode_parse(const char *text,struct drm_mode_modeinfo *m) {
 uint32_t v[12]; unsigned i; const char *p=text; char *end;
 if (!p || strlen(p)>255) return -1;
 for(i=0;i<12;i++) {
  unsigned long n;
  if(*p<'0' || *p>'9') return -1;
  errno=0;n=strtoul(p,&end,10);
  if(errno || n>UINT32_MAX || (i>0 && i<11 && n>65535)) return -1;
  v[i]=(uint32_t)n;
  if(i<11 ? *end!=':' : *end!=0) return -1;
  p=end+1;
 }
 if(!v[0] || !v[1] || !v[6] || v[1]>v[2] || v[2]>v[3] || v[3]>v[4] ||
    v[6]>v[7] || v[7]>v[8] || v[8]>v[9] || !v[4] || !v[9]) return -1;
 memset(m,0,sizeof(*m));
 m->clock=v[0];m->hdisplay=v[1];m->hsync_start=v[2];m->hsync_end=v[3];m->htotal=v[4];m->hskew=v[5];
 m->vdisplay=v[6];m->vsync_start=v[7];m->vsync_end=v[8];m->vtotal=v[9];m->vscan=v[10];m->flags=v[11];
 m->vrefresh=(uint32_t)(pg_drm_mode_hz(m)+0.5);
 return 0;
}
#endif
