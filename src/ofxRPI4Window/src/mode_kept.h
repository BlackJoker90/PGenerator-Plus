/* When a commit that keeps the CRTC's mode has to switch the CRTC off first
 * (ofxRPI4Window::SwitchOffIfModeKept). vc4 programs the CSC and the AVI
 * quantisation range only when it enables the encoder, and "rgb quant range"
 * alone is no reason for a modeset, so a commit in the mode already on the
 * CRTC leaves the range the CRTC was last enabled with on the wire.
 * Plain functions without libdrm, so t/renderer_mode_kept.t can build them on
 * the Mac. */
#ifndef PG_MODE_KEPT_H
#define PG_MODE_KEPT_H

#include <stdint.h>

/* Worth looking at the CRTC: the first flip of the renderer process (the
 * wire range is unknown: the kernel's boot mode, the console's restore, or a
 * range written while no renderer ran), or a flip whose request changes
 * "rgb quant range" from the value the connector holds. */
static inline bool pgModeKeptCheck(bool first_flip, bool range_known, uint64_t range_before,
				   bool range_pending, uint64_t range_pending_value)
{
	if (first_flip)
		return true;
	return range_pending && range_known && range_before != range_pending_value;
}

/* The fields the kernel's drm_mode_equal() compares (clock, timings, flags;
   not the name, type or vrefresh): modes equal in all of them are no
   modeset. M is drmModeModeInfo, or a struct with the same members. */
template <typename M>
static inline bool pgSameModeTimings(const M &a, const M &b)
{
	return a.clock == b.clock &&
		a.hdisplay == b.hdisplay && a.hsync_start == b.hsync_start &&
		a.hsync_end == b.hsync_end && a.htotal == b.htotal &&
		a.hskew == b.hskew && a.vdisplay == b.vdisplay &&
		a.vsync_start == b.vsync_start && a.vsync_end == b.vsync_end &&
		a.vtotal == b.vtotal && a.vscan == b.vscan &&
		a.flags == b.flags;
}

/* Switch the CRTC off before the commit: checked, the CRTC is on (enabling
   an inactive CRTC is a modeset anyway) and the mode stays. */
static inline bool pgModeKeptSwitchOff(bool check, bool crtc_active, bool same_mode)
{
	return check && crtc_active && same_mode;
}

#endif
