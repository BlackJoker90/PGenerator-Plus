---
name: PGenerator+ WebUI
description: The control surface of a Raspberry Pi 4 HDMI pattern generator, built for the calibration dark room.
colors:
  pale-aqua: "#8fe0d1"
  pale-aqua-soft: "#b4eee3"
  aqua-fill: "#6fcfbd"
  aqua-fill-hover: "#8adfce"
  on-aqua: "#05241f"
  focus-frost: "#e9fffa"
  night-hover: "rgba(255,255,255,.06)"
  night-selected: "#2b2b31"
  night-divider: "#25252a"
  night-field-edge: "#5d5d65"
  night-page: "#0a0a0c"
  night-panel: "#141416"
  night-drawer: "#111113"
  night-modal: "#19191c"
  night-popover: "#232327"
  night-well: "#0d0d0f"
  night-key: "#1f1f23"
  night-key-lit: "#38383f"
  night-hairline: "#2b2b30"
  text-lit: "#e4e4e8"
  text-body: "#d2d2d6"
  text-secondary: "#a2a2a8"
  text-muted: "#8f8f96"
  text-disabled: "#62626a"
  amber-warning: "#e8a55b"
  coral-error: "#ee7570"
  green-success: "#5fb878"
  bits-8: "#3aa99f"
  bits-10: "#4f8ff0"
  bits-12: "#d062b8"
  day-page: "#dcdddd"
  day-panel: "#e9eaea"
  day-key: "#d9dada"
  day-key-lit: "#c3c5c5"
  day-teal: "#0b5c53"
  day-teal-fill: "#0f6f64"
  day-text: "#151617"
  day-text-secondary: "#484a4c"
  day-text-muted: "#56585a"
  day-text-lit: "#000000"
  day-well: "#d3d4d4"
  day-focus: "#062e29"
  day-hover: "rgba(0,0,0,.06)"
  day-warning: "#8f4700"
  day-error: "#c62828"
  day-success: "#217a36"
typography:
  display:
    fontFamily: "PGen Mesopic, Avenir Next, Segoe UI, system-ui, sans-serif"
    fontSize: "1.75rem"
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: "-0.02em"
  display-tablet:
    fontFamily: "PGen Mesopic, Avenir Next, Segoe UI, system-ui, sans-serif"
    fontSize: "1.5rem"
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: "-0.02em"
  headline:
    fontFamily: "PGen Mesopic, Avenir Next, Segoe UI, system-ui, sans-serif"
    fontSize: "1.1875rem"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.01em"
  headline-phone:
    fontFamily: "PGen Mesopic, Avenir Next, Segoe UI, system-ui, sans-serif"
    fontSize: "1.0625rem"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.01em"
  title:
    fontFamily: "PGen Mesopic, Avenir Next, Segoe UI, system-ui, sans-serif"
    fontSize: "1rem"
    fontWeight: 600
    fontFeature: "tnum"
  readout:
    fontFamily: "PGen Mesopic, Avenir Next, Segoe UI, system-ui, sans-serif"
    fontSize: "0.9375rem"
    fontWeight: 700
    fontFeature: "tnum"
  body:
    fontFamily: "PGen Mesopic, Avenir Next, Segoe UI, system-ui, sans-serif"
    fontSize: "0.875rem"
    fontWeight: 400
  label:
    fontFamily: "PGen Mesopic, Avenir Next, Segoe UI, system-ui, sans-serif"
    fontSize: "0.8125rem"
    fontWeight: 500
    lineHeight: 1.3
  hex:
    fontFamily: "Courier New, monospace"
    fontSize: "0.8125rem"
    fontWeight: 400
  caption:
    fontFamily: "PGen Mesopic, Avenir Next, Segoe UI, system-ui, sans-serif"
    fontSize: "0.75rem"
    fontWeight: 500
rounded:
  xs: "6px"
  inner: "8px"
  sm: "12px"
  nav: "14px"
  md: "16px"
  capsule: "18px"
  dock-key: "21px"
  lg: "22px"
  dock: "26px"
  pill: "999px"
spacing:
  tile-gap: "10px"
  card-gap: "12px"
  card-pad-desktop: "22px 24px 24px"
  card-pad-tablet: "13px 14px 18px"
  control-h: "36px"
  text-edge: "24px"
components:
  card:
    backgroundColor: "{colors.night-panel}"
    rounded: "{rounded.lg}"
    padding: "22px 24px 24px"
  setting-key:
    backgroundColor: "{colors.night-key}"
    textColor: "{colors.text-lit}"
    typography: "{typography.title}"
    rounded: "{rounded.md}"
    padding: "9px 6px 3px 14px"
  setting-key-open:
    backgroundColor: "{colors.night-key-lit}"
    textColor: "{colors.text-lit}"
    rounded: "{rounded.md}"
  button-primary:
    backgroundColor: "{colors.aqua-fill}"
    textColor: "{colors.on-aqua}"
    rounded: "{rounded.pill}"
    height: "36px"
  button-quiet:
    backgroundColor: "transparent"
    textColor: "{colors.text-secondary}"
    rounded: "{rounded.pill}"
  nav-item:
    textColor: "{colors.text-secondary}"
    rounded: "14px"
    padding: "9px 14px"
    height: "42px"
  nav-item-current:
    backgroundColor: "{colors.night-panel}"
    textColor: "{colors.text-lit}"
    rounded: "14px"
  status-readout:
    backgroundColor: "{colors.night-panel}"
    textColor: "{colors.text-secondary}"
    typography: "{typography.label}"
    rounded: "18px"
    padding: "4px 18px"
  note-well:
    backgroundColor: "{colors.night-well}"
    textColor: "{colors.text-secondary}"
    rounded: "{rounded.md}"
---

# Design System: PGenerator+ WebUI

<!-- Recorded 2026-11-12 from the Mesopic layer in
     usr/share/PGenerator/webui-layout.css ("Mesopic look"), which the
     maintainer chose and signed off on 2026-11-10. The tokens there are the
     source of truth; update this file when they change. -->

## Overview

**Creative North Star: "Mesopic"**

Mesopic vision is what the eye does between daylight and darkness, and that is
where a calibrator works: in a dimmed room, the display under test the
brightest thing in it, the phone or laptop held at arm's length. The interface
lives in that light. It is dark by default, low in chrome contrast, and lets
the picture on the TV be the only bright object. Hierarchy comes from tone
steps, not outlines: a well for what is read, a key for what is pressed, a lit
key for what is chosen.

The face is round and geometric (Gabarito, served by the Pi itself as
"PGen Mesopic", OFL 1.1), set bold for what the calibrator reads and medium
for labels, with tabular figures everywhere so codes and clocks never jitter.
Controls are soft keys and pills with their name inside. One pale aqua accent
marks what is current, chosen or about to be applied; amber, coral and green
are reserved for state.

The look is modern and bold, not technical. The rejected first redesign
("Service Manual") showed what this system is not: no monospace or typewriter
faces for UI text, no stencil or lettering faces, nothing retro or
manual-like.

**Key Characteristics:**
- Dark default that does not light the room; a working light theme in the same grammar.
- Tone steps instead of 1 px frames: well, key, lit key.
- One accent, used for current, chosen and pending; hue never carries state alone.
- Bold round type with tabular figures; nothing under 12 px.
- Calibration colour is data: nothing tints, blends or lies over it.

## Colors

A near-black neutral ladder with one pale aqua voice, and three state hues that appear only when something needs attention.

### Primary
- **Pale Aqua** (#8fe0d1): the accent. Current workspace icon, the ring of an open key, the pending dot after a changed setting's label, caret and links. Day theme: **Deep Teal** (#0b5c53).
- **Aqua Fill** (#6fcfbd): filled primary buttons and the switch's on state, with **On Aqua** (#05241f) text. Day theme: **Teal Fill** (#0f6f64).
- **Focus Frost** (#e9fffa): the 2 px keyboard focus ring, brighter than any surface so it never hides.

### Neutral
- **Night Page** (#0a0a0c): page, header and sidebar are one plane.
- **Night Panel** (#141416): a card, the status readout, the current nav item.
- **Night Well** (#0d0d0f): what is read, not pressed: notes, the self-test verdict, live diagnostics.
- **Night Key** (#1f1f23): a setting key, a field.
- **Night Key Lit** (#38383f): a key whose menu or tip is open, a chosen segment.
- **Night Modal / Popover** (#19191c / #232327): dialogs and tips, one step above the card.
- **Night Hairline** (#2b2b30): the one hairline left, between the signal and the rest of the readout.
- **Text Lit / Body / Secondary / Muted / Disabled** (#e4e4e8 / #d2d2d6 / #a2a2a8 / #8f8f96 / #62626a): values, body, supporting text, labels, disabled.
- Day theme: page #dcdddd, panel #e9eaea, key #d9dada, lit key #c3c5c5, text #151617, secondary #484a4c, lit text pure black.

### State and data
- **Amber Warning** (#e8a55b, day #8f4700): a value on the cable that differs from the setting, a reset on hover, a reboot on hover.
- **Coral Error** (#ee7570, day #c62828) and **Green Success** (#5fb878, day #217a36): failures and passes, always next to a word or a mark.
- **Bit-depth chips** (8 #3aa99f, 10 #4f8ff0, 12 #d062b8): the link depth, a data colour, not decoration.

### Named Rules
**The One Voice Rule.** Aqua is the only accent. It marks current, chosen or pending, never decoration.

**The Data Colour Rule.** A calibration colour (swatch, preview, chart patch) is shown exactly: no tint, filter, blend, opacity, gradient or translucent layer over it.

**The Palette Override Rule.** The Mesopic tokens apply only without `data-palette`. The other themes (Volt, Natrium, OLED …) set their own colours and inherit the Mesopic shapes, type and tone grammar.

## Typography

**Display Font:** PGen Mesopic (Gabarito; with Avenir Next, Segoe UI, system-ui)
**Body Font:** the same family
**Label/Mono Font:** none; figures are tabular in the one family

**Character:** One round geometric family in three weights: bold for what is read, semibold for values, medium for labels. Synthesis is off, so no faux bold or italic appears.

### Hierarchy
- **Display** (700, 1.75rem desktop / 1.5rem tablet, 1.15, -0.02em): the workspace title.
- **Headline** (700, 1.1875rem / 1.0625rem under 600 px, 1.2, -0.01em): a card title, the self-test title.
- **Readout** (700, 0.9375rem, tabular): the signal in the header.
- **Title** (600, 1rem / 0.9375rem under 600 px, tabular): the value inside a setting key.
- **Body** (400, 0.875rem): running text in cards and dialogs.
- **Label** (500, 0.8125rem, 1.3): field labels, the readback line, nav group labels in muted grey.
- **Caption** (500, 0.75rem): the smallest size; nothing goes under 12 px.
- **Hex** (Courier New, 0.8125rem): raw infoframe bytes and pairing codes only.

### Named Rules
**The No-Mono Rule.** No monospace, typewriter, stencil or lettering face for UI text. Hex dumps in the infoframe decoder are the one place a monospace stack remains.

**The Tabular Rule.** Every number uses tabular figures, so a changing code or clock never shifts its neighbours.

## Layout

Two layouts, chosen in Settings: **Desktop** (a 240 px rail of workspaces, cards in a column beside it, Live Information as a right-hand drawer) and **Tablet** for tablets and phones (a bottom dock of workspaces, one workspace at a time, Output first; the default at 800 px and below). Cards stack with a 12 px gap on Desktop, 10 px on Tablet.

Everything that starts a line starts on one edge: the logo glyph, the readout's text, the workspace title and the card text sit 24 px in. Setting keys sit in a grid with a 10 px gap; on a phone two keys to a row (one under 360 px; Resolution and Range take a full row from 360 to 411 px). The header is one row on Desktop; on Tablet the readout takes its own row under logo and power, and stays one line from 700 px.

Touch targets are 44 px on touch and at least 24 px under a fine pointer, grown away from the control below so neither steals the other's taps.

## Elevation & Depth

Flat by default. Depth is tonal: page, panel, key and lit key are four steps of the same neutral, and a dialog or tip is one step above the card. Shadows are kept for what floats above scrolling content: the Apply bar dock and dialogs. The Tablet dock has no drop shadow; a solid field in the page colour closes the gap under it, because nothing translucent may pass over a swatch.

### Named Rules
**The Tone-Step Rule.** A boundary is a change of tone, not a 1 px line. What is live or chosen among peers carries a 1.5 px inset ring (aqua, or amber when the cable differs).

## Shapes

Soft and round. Cards 22 px, keys and notes 16 px, desktop nav items 14 px, menus and inputs 12 px, a select inside a key 8 px, small marks 6 px. Everything pressed (buttons, segment switches, nav items on Tablet at 21 px) is a pill or a near-pill; the status readout is an 18 px capsule and the Tablet dock a 26 px one. Pressing scales to 0.97; reduced motion turns that and every transition off.

## Components

### Buttons
- **Shape:** full pill (999px), bold label.
- **Primary:** Aqua Fill with On Aqua text, 36 px tall.
- **Quiet:** transparent with secondary text (card resets); on hover a neutral fill and amber text, because a reset undoes work. Disabled stays transparent at half opacity.
- **Hover / Focus:** a 2 px Focus Frost ring for the keyboard; press scales to 0.97.

### Setting keys (signature component)
- **Style:** a Night Key tile with its label inside on top (muted, 0.8125rem) and its value below (lit, 1rem semibold), 16 px corners, no border.
- **Open:** the tile lights to Night Key Lit with a 1.5 px aqua inset ring while its menu or info tip is open.
- **Readback:** a line under the value says what is on the cable: a check (matches), a ring (read, not compared), an amber triangle and amber text with an amber ring around the key (differs), plain text while pending. The marks are explained once in a legend under the fields.
- **Pending:** an aqua dot after the label until the Apply bar applies the change.

### Cards / Containers
- **Corner Style:** 22px.
- **Background:** Night Panel on Night Page.
- **Shadow Strategy:** none (see Elevation).
- **Border:** none.
- **Internal Padding:** 22/24/24 px on Desktop, 13/14/18 px on Tablet.

### Inputs / Fields
- **Style:** Night Key fill, transparent border, 12 px corners.
- **Focus:** the key or field carries the focus ring, never the inner select.
- **Disabled:** a flatter fill and muted text, no border.

### Navigation
- **Desktop rail:** 42 px items with 14 px corners, secondary text in medium weight; the current item takes the panel fill, lit bold text and an aqua icon.
- **Tablet dock:** 50 px pill keys; the current one takes Night Key Lit, lit bold text and an aqua icon.

### Status readout
One capsule in the header: the signal leads in bold lit text, set off by the only hairline, then Pi, temperature, pattern, meter and warnings, each a dot, a label and a value. What the cable carries instead of the setting follows after "→ sent" in amber.

### Help marks
A drawn "i" in a ring at 15 px (20 px on touch) that opens a tip on click or hover; long Calman explanations live there, not in the card.

## Do's and Don'ts

### Do:
- **Do** build boundaries from the four tone steps (well, key, lit key, panel) before reaching for a line.
- **Do** keep aqua for current, chosen and pending; use amber only for a cable difference or a destructive hover.
- **Do** pair every state hue with a word or a mark, and keep forced-colours rules for new marks.
- **Do** start new lines on the 24 px edge and keep text at 12 px or more.
- **Do** put long explanations behind a help mark, and show what the cable carries in the field it concerns.

### Don't:
- **Don't** use monospace, typewriter, stencil or lettering faces for UI text, or anything retro or manual-like (the rejected "Service Manual" direction).
- **Don't** draw 1 px frames around tiles, tabs or panels.
- **Don't** add a second accent colour or a gradient to the chrome.
- **Don't** tint, blend, filter or overlay a calibration colour, and don't put a translucent layer or drop shadow where swatches scroll under it.
- **Don't** load fonts or scripts from the internet; the Pi serves everything itself.
