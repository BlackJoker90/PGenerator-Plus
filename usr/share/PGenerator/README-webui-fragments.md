# Web UI fragments

The `webui.html`, `webui-*.html`, `webui-*.css`, and `webui-*.js` files in this directory are
the byte-sensitive inputs to the server-side Web UI assembler in `webui.pm`.
They are deliberately stored as separate files so front-end changes have
normal editor and diff boundaries while the server continues to emit one
HTML response.

Do not run Prettier, ESLint `--fix`, a formatter-on-save rule, or a tabs-to-
spaces conversion over these files. Their bytes are covered by
`t/webui_html_golden.t`; changing whitespace, line endings, or placeholder
lines changes the rendered response. `icc_profile.html` is spliced into the
same hashed page, so it is exactly as byte-sensitive as the ten fragments;
`icc_profile.css`, `icc_profile.js`, and `hcfr_chc.js` are served verbatim
from `/assets/` and must not be reformatted either.

`webui-colour-math.js` opens with `'use strict';` and is concatenated into
the SAME inline `<script>` block as `webui-app.js` and `webui-workspace.js`,
so the directive governs all three fragments. Any new code in those files
must be strict-mode clean: no undeclared assignments, no `with`, no
block-scoped function declarations relied on across blocks.

The checked-in `t/slice_webui.pl` script was the one-shot extraction
mechanism for the initial split. It asserts against the pre-split heredoc
layout, so it can only run against a tree from before the refactor; on the
current tree it dies by design. The golden hash below is the standing
guarantee.

After an intentional front-end change, refresh the golden hash and commit it
together with the fragment change:

```bash
prove -v t/webui_html_golden.t
```

The failing comparison prints `got: '<new hash>'` next to the expected value.
Confirm the diff you are landing is the only change, then write the new hash
into `t/webui_html_golden.sha256` (single line, no trailing spaces) and re-run
the test to see it pass.

`webui-layout.css` ends with two sections. "Mesopic look" is the look every
theme but Glow has, drawn as a layer over `webui-theme.css`,
`icc_profile.css` and the rest of `webui-layout.css`. It relies on coming
after all of them, so new layout rules go above it. "Glow look" follows it
and is described below. Dark and Light take its colour tokens; the colour themes
(`data-palette`) keep their own and take the type and structure. High
Contrast has one tone for every surface and therefore keeps drawn lines
(the last rules of the section).

The Glow theme is the default and has a layout of its own. It is a skin, not
a palette: the page carries `data-skin="glow"` on `<html>`, `data-theme="dark"`
and no `data-palette`, so it stands on the Dark theme's Mesopic rules. The
theme ids, the skins and the default are listed twice, in the inline script
of `webui.html` (which runs before the stylesheet, against a flash) and in
`PG_THEMES`, `PG_THEME_SKINS` and `PG_THEME_DEFAULT` in `webui-app.js`;
`t/webui_glow_theme.t` holds the two together with the buttons in Settings.
Its rules are the section "Glow look" at the end of `webui-layout.css`, each
starting with `:root[data-skin="glow"][data-theme="dark"]`. What it draws
beyond the page's markup (the ST 2084 curve in HDR Metadata, the Self-Test
ring, the playlists as cards, the port in use as a line of text) is built by
the script at the end of `webui-workspace.js`, from what the page already
holds; every other theme hides those pieces and the script puts the Calman
settings back where the markup has them. A piece added there must show real
state or start a real action: no sample controls.

The typefaces live in `fonts/`: `meso.woff2` (Gabarito, licence
`meso-OFL.txt`) for every theme but Glow, and for Glow `glow.woff2` (Plus
Jakarta Sans, `glow-OFL.txt`) and `glow-display.woff2` (Sora,
`glow-display-OFL.txt`). They are served by `webui.pm` at `/assets/fonts/<name>`, the
address the stylesheet's relative `url("fonts/meso.woff2")` resolves to,
because the stylesheet itself is served from `/assets/`. The names in
`%_webui_font_assets` are the whole allowlist. A font is cached by the
browser for a week without a validator: a changed face ships under a new
file name. A font that is missing, empty or cut short (its WOFF2 header
names the file's length) is answered with 404: the page falls back to the
system face, and the daemon logs a missing font at start
(`t/webui_font_asset.t`).

The loader reads every fragment with Perl's `<:raw>` layer. Keep UTF-8 source
bytes and LF endings intact, and do not add banner comments inside fragments.
Migration notes and explanations belong here instead.

Before publishing an OTA archive, verify that the cumulative overlay contains
all ten exact fragment paths with content, plus the four page assets the
served UI also reads from disk (`icc_profile.html`, `icc_profile.css`,
`icc_profile.js`, `hcfr_chc.js`):

```bash
perl t/check_webui_package.pl <release>.tar.gz
```
