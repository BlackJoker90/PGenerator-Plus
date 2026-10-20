# PGenerator+ (BlackJoker90 fork)

Raspberry Pi 4 HDMI pattern generator for display calibration. Perl daemon
(`usr/sbin/PGeneratord` → `usr/share/PGenerator/*.pm`), C++ openFrameworks
renderer (`src/`, prebuilt as `usr/sbin/PGeneratord` / `.dv`), WebUI
(`usr/share/PGenerator/webui-*.{html,css,js}`, served by `webui.pm`), helper
scripts in `usr/bin/`. The Pi runs Perl 5 and Python 3.5: no f-strings, no
newer stdlib in anything under `usr/`.

The fork's promise is the **signal on the cable**: codes must be bit-exact,
and that is proven by reading back the scanout, never assumed.

## Local-only material

`t/`, `tools/`, `docs/` and `TASKS.md` are ignored (`.gitignore` /
`.git/info/exclude`). They exist on the maintainer's machine, not in a clone.
Check before relying on them.

## Verify after a change

Run what applies and say what was and was not checked:

- `prove -r t` (code-value tests: bits, Calman scaling, G1 plates, playlists)
- Perl: `perl -I usr/share/PGenerator -c <file>` for scripts in `usr/bin`,
  `usr/sbin`; modules are checked by `tools/runtime/pgen_release_checks.sh`
  (`pgen_release_check_runtime_syntax`)
- WebUI JS: `node -e "new (require('vm').Script)(require('fs').readFileSync('usr/share/PGenerator/webui-app.js','utf8'))"`
- Python under `usr/bin`: must parse as Python 3.5
  (`ast.parse(src, feature_version=(3,5))`, or `py_compile` on the Pi)
- WebUI changes: look at the rendered page at phone (~390 px), tablet and
  desktop widths; the impeccable detector on changed UI files
- Signal, renderer or pattern changes: on the Pi at the HDMI output
  (`/verify` skill, the Signal Self-Test in Output, or `pgen_scanout`).
  Deploy scripts are not verification.

## Rules that bite

- **TV remote**: `pgen_cec_remote.py` only forwards keys to
  `POST /api/remote/key`; all menu/playlist logic is in webui.pm and
  `PGTVMenu.pm`. Patterns drawn by the menu run under
  `local $_tvmenu_drawing=1`; any other `webui_pattern` call marks the menu
  closed. Never kill the listener from a key handler (it is the caller).
- **Bit exactness**: prove codes with `/usr/bin/pgen_scanout x y w h`
  (4:2:2 reads R=Y; 4:4:4 reads R=Cb G=Cr B=Y; standard DV reads packed
  tunnel bytes). Renderer sources and the rebuilt binaries
  (`usr/sbin/PGeneratord`, `.dv`) are committed together.
- `clean_files` deletes every file directly in `/var/lib/PGenerator/` on each
  daemon start; persistent data goes in a subdirectory (e.g. `playlists/`).
- The daemon reads the WebUI files at start: a WebUI deploy needs
  `/etc/init.d/PGenerator restart`.
- Perl `glob` in scalar context is an iterator; use list context.
- Never POST `{}` or dummy bodies to settings endpoints (`/api/meter/settings`
  wiped settings once). Read the handler first; partial `/api/config` bodies
  are fine.
- Leaving Dolby Vision restores the pre-DV range/depth/format
  (`pre_dv_*`); the self-test marks its switches with `selftest:1` so they
  do not overwrite those.

## Working on the Pi

- Before probes or restarts: `sh /root/pi_calman_busy.sh`. On BUSY, do not
  touch the device; ask. (It also counts "Calman G1:" log lines, so a
  recent G1 plate can show BUSY without a Calman connection.)
- Deploy safely: diff the Pi's file against the branch first, back up to
  `/root/pgen-backups/`, upload, guard against empty files, compare md5.
- OLED: test on screen with dim windows (20 IRE, 10 %), not full white.
- Give the user's signal settings back at the end of a test.
- Without a display the renderer waits; forcing the connector on without
  an EDID crashes the renderer on mode switches.

## Git and releases

- Push only with `git push fork main` (fork = BlackJoker90). `origin` is
  upstream BigShoots: never push there.
- Releases are OTA packages (`tools/release-ota.sh`); a flashable image
  only for boot/base-system changes. The release script refuses untracked
  runtime files: `git add` new files first.
- Commits, pushes, releases, reboots and deploys need the maintainer's OK.
- Code comments, commit messages and repo docs are in English.
