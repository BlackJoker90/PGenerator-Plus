#ifndef PG_DRM_SDR_H
#define PG_DRM_SDR_H
/* Read-only, fail-closed SDR precondition. Do not clear DOVI with a guessed
 * blob: ResetConnectorOnExit has an explicit DV-off sequence because zero
 * alone can leave the VSIF latched on these kernels. No framebuffer may be
 * attached if exposed connector properties still request HDR/DV/YUV/deep RGB.
 * Property state is a prerequisite, not proof of the signal on the cable. */
/* ABI from ofxRPI4Window.h::dovi_output_metadata (also drm_vc4.patch).
 * Match DoviBlobStatus() in ofxRPI4Window.cpp: the status byte follows oui.
 * The kernel property uses this 12-byte layout, including trailing padding. */
struct pg_drm_dovi_metadata {
 uint32_t oui;
 uint8_t dv_status,dv_interface,backlight_metadata,backlight_max_luminance;
 uint8_t aux_runmode,aux_version,aux_debug;
};
static int pg_drm_dovi_off(int fd,uint64_t id) {
 struct pg_drm_dovi_metadata data={0};
 struct drm_mode_get_blob b={0};int r;
 if(id>UINT32_MAX){errno=EOVERFLOW;return -1;}
 b.blob_id=(uint32_t)id;b.length=sizeof(data);b.data=(uint64_t)(uintptr_t)&data;
 do {r=ioctl(fd,DRM_IOCTL_MODE_GETPROPBLOB,&b);} while(r<0 && errno==EINTR);
 if(r<0)return -1;
 if(b.length!=sizeof(data)){errno=EPROTO;return -1;}
 return data.dv_status==0;
}
static int pg_drm_require_sdr(int fd,uint32_t connector_id) {
 struct drm_mode_get_connector c={0};
 uint32_t ids[128];uint64_t values[128];unsigned i,j,capacity;
 static const struct {const char *name;uint64_t expected;} rules[]={
  {"output format",0},{"active color format",0},{"max bpc",8},
  {"Colorimetry",0},{"Colorspace",0},{"rgb quant range",0},{"Broadcast RGB",0},
  {"HDR_OUTPUT_METADATA",0},{"DOVI_OUTPUT_METADATA",0}
 };
 int r;
 c.connector_id=connector_id;
 do {r=ioctl(fd,DRM_IOCTL_MODE_GETCONNECTOR,&c);} while(r<0 && errno==EINTR);
 if(r<0) goto unreadable;
 if(c.count_props>128){errno=EOVERFLOW;goto unreadable;}
 capacity=c.count_props;
 c.props_ptr=(uint64_t)(uintptr_t)ids;c.prop_values_ptr=(uint64_t)(uintptr_t)values;
 /* Query only properties: clear unrelated counts so the kernel never writes
  * modes/encoders through null pointers. */
 c.count_modes=0;c.count_encoders=0;
 do {r=ioctl(fd,DRM_IOCTL_MODE_GETCONNECTOR,&c);} while(r<0 && errno==EINTR);
 if(r<0) goto unreadable;
 if(c.count_props>capacity){errno=EOVERFLOW;goto unreadable;}
 for(i=0;i<c.count_props;i++) {
  struct drm_mode_get_property p={0};p.prop_id=ids[i];
  do {r=ioctl(fd,DRM_IOCTL_MODE_GETPROPERTY,&p);} while(r<0 && errno==EINTR);
  if(r<0) goto unreadable;
  if(!strcmp(p.name,"DOVI_OUTPUT_METADATA") && values[i]) {
   int off=pg_drm_dovi_off(fd,values[i]);
   if(off<0)goto unreadable;
   if(off)continue; /* Keep the renderer's committed DV-off VSIF intact. */
  }
  for(j=0;j<sizeof(rules)/sizeof(*rules);j++) if(!strcmp(p.name,rules[j].name) && values[i]!=rules[j].expected) {
   fprintf(stderr,"diagnostic DRM: refusing non-SDR connector %u: %s=%llu (need %llu)\n",
    connector_id,p.name,(unsigned long long)values[i],(unsigned long long)rules[j].expected);
   errno=EPERM;return -1;
  }
 }
 return 0;
unreadable:
 fprintf(stderr,"diagnostic DRM: cannot verify SDR connector %u: %s\n",connector_id,strerror(errno));
 return -1;
}
#endif
