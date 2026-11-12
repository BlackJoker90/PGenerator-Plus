# Product

<!-- impeccable:product-schema 1 -->

> Product record for design work on the WebUI (read by the Impeccable design
> skill). Confirmed by the maintainer on 2026-11-12.

## Platform

web

## Users

Display calibrators, from hobbyists to ISF-level professionals, calibrating
TVs, projectors and monitors. They work in a darkened room with an OLED or a
projector screen in front of them, a colorimeter or spectroradiometer on the
screen, and Calman, ColourSpace or HCFR on a laptop next to it. They drive the
WebUI from a phone, a tablet or the laptop, often one-handed and at arm's
length, between measurements.

## Product Purpose

PGenerator+ turns a Raspberry Pi 4 into an HDMI test-pattern generator. The
WebUI sets the signal (mode, resolution, range, bit depth, colour format,
colorimetry, HDR10 and Dolby Vision metadata), shows patterns and playlists,
runs on-Pi meter series and charts, controls an LG TV and HDMI-CEC, and
administers the device (network, OTA updates, logs). Success: the calibrator
trusts what is on the cable and reaches the next control without lighting up
the room.

## Positioning

The generator proves its own output: it reads back the scanout and reports
codes, link depth and infoframes bit-exactly (Signal Self-Test, and the
readback in each setting field in Output). Standards decide the signalling:
BT.709, BT.2020 and BT.2100; ST 2084 and ST 2086; ARIB STD-B67; CTA-861 for
the AVI and DRM infoframes; ETSI GS CCM 001 for Dolby Vision. Where a standard
is silent, PGenerator 1.6 is the reference.

## Operating Context

Dark room, dim or black walls, the display under test is the brightest object.
Sessions run from minutes to hours. Neighbouring tools: Calman (also as a
Portrait Displays G1), ColourSpace, HCFR, DaVinci Resolve, LG AutoCal, the TV
remote over HDMI-CEC (pattern menu and playlists on the TV). The Pi is often
offline; the page is served by the Pi's own Perl daemon as fragments
(`usr/share/PGenerator/webui-*`), at `http://pgenerator.local` on port 80.

## Capabilities and Constraints

- Workspaces: Output (with Live Information as a drawer on Desktop), Patterns
  (with Playlists), Calibration, Meter Profiler, 3D LUT, Display Profiler,
  Connectivity (network, LG TV, Resolve, HDMI-CEC on Tablet), System,
  Settings. The Measure workspaces can be hidden for pattern-only setups.
- Two layouts, chosen in Settings: Desktop (sidebar of workspaces) and Tablet
  (bottom tab bar, one workspace at a time, Output first) for tablets and
  phones.
- Signal settings take effect only through the Apply bar.
- Every control, id, name, data attribute and inline handler is behaviour and
  stays; the maintainer's local page tests guard the callers.
- Anything that shows a calibration colour (pattern swatches, previews, chart
  patches) is colour-accurate: no tint, filter, blend, opacity or gradient,
  and nothing translucent may lie over it.
- No runtime dependency, CDN or fetched web font: fonts are files shipped in
  the repo and served by the Pi, with the OTA size in mind.
- Works on older Safari and Chrome tablets.
- A dark default that does not light the room, and a working light theme.
  Thirteen colour themes exist (Volt is the README's screenshot theme).
- README screenshots: Volt theme, 1280x800, Desktop layout, GET-only.

## Brand Commitments

Name PGenerator+; the PGen+ wordmark with its red-green-blue-yellow-red bar.
English UI copy. The fork's promise is the signal on the cable, proven, not
assumed.

## Evidence on Hand

The running page on the Pi (`http://pgenerator.local`), README screenshots
(`screenshots/`), the maintainer's local WebUI tests, the Signal Self-Test's
readback results on the Pi. No user research, analytics or
testimonials exist; none may be invented.

## Product Principles

1. The signal on the cable comes first: the UI never changes or misstates it.
2. Colour on screen is data; the interface itself stays out of its way.
3. Darkness is the working condition, not a theme.
4. Numbers are exact: codes, ranges and bit depths are shown as they are sent.
5. Dense is fine when it is ordered; nothing needs a second visit to be found.

## Accessibility & Inclusion

Touch targets usable in the dark on a phone (44 px on touch, 24 px under a
fine pointer); text contrast at WCAG AA in both themes; nothing under 12 px;
reduced motion respected; forced colours supported; state never carried by
hue alone.
