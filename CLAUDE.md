# PGenerator+ (BlackJoker90 fork)

Raspberry Pi 4 HDMI pattern generator for display calibration. Perl daemon
(`usr/sbin/PGeneratord` → `usr/share/PGenerator/*.pm`), C++ openFrameworks
renderer (`src/`, prebuilt as `usr/sbin/PGeneratord` / `.dv`), WebUI
(`usr/share/PGenerator/webui-*.{html,css,js}`, served by `webui.pm`), helper
scripts in `usr/bin/`. The Pi runs Perl 5 and Python 3.5: no f-strings, no
newer stdlib in anything under `usr/`.

The fork's promise is the **signal on the cable**: codes must be bit-exact,
and that is proven by reading back the scanout, never assumed. This is the
top priority, above any feature, in SDR, HDR10, HLG and Dolby Vision alike:
- Bit-exact: codes, ranges, matrices, bit depths.
- Standards-compliant: the signalling follows the standards:
  - BT.709, BT.2020 and BT.2100 for colour;
  - ST 2084 and ST 2086 for HDR10, ARIB STD-B67 for HLG;
  - CTA-861 for the AVI and DRM infoframes;
  - ETSI GS CCM 001 for the Dolby Vision metadata.
- Where a standard is silent, PGenerator 1.6 is the reference (see
  "Research, don't guess").

## Research, don't guess

- Never state a spec value, packet field, device or client behaviour, or
  code path from memory or plausibility. Look it up, above all when unsure:
  the code, the Pi's logs, a readback at the cable, or a primary source
  (standard, vendor document, reference implementation).
- Name the source of each statement. Mark what could not be confirmed and
  say where you searched.
- A test only proves what it actually varied: confirm the setting under
  test took effect (log, conf, readback) before drawing a conclusion. In
  DV, for example, Calman's `CONF_LEVEL:Range` is ignored by design.

## Local-only material

`t/`, `tools/`, `docs/` and `TASKS.md` are ignored (`.gitignore` /
`.git/info/exclude`). They exist on the maintainer's machine, not in a clone.
Check before relying on them.

## TASKS.md stays current

Tick an item yourself as soon as the test that proves it passes, in the
same step, without being asked: `- [x] … (evidence: t/x.t, commit, readback)`,
including duplicates of the item elsewhere in the file. An item that is
only implemented, or tested locally but not on the Pi, stays open with the
level it reached. Before ending a session, check every open box against
git log and the code and tick what is proven. In a worktree, TASKS.md is
the main checkout's copy.

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
- Robustness, as its own pass next to the HDMI check (a scanout does not
  find a lost conf write, a unit test does not prove a code on the cable):
  invalid input, concurrent access, and the safeguard itself failing
  (restore fails, packet unreadable, body complete but not valid JSON).
  Ask it of every function the change touches and of every place sharing
  the pattern: each return value (open, print, close, rename, sudo), each
  step of a multi-step write.
  Test behaviour, not code text: send the request and read the response
  and the state (`t/config_post_behaviour.t`); the renderer's pattern
  parser is `pattern_parse.h`, built under ASan/UBSan by
  `t/renderer_pattern_parse.t`.
- A fix is closed when its repro fails against the old code and passes
  against the new: run the test against `git archive HEAD` unpacked into
  `$TMPDIR`, never by stashing in the shared checkout.
- Earlier claims are hypotheses: a ticked box in `TASKS.md`, a "checked"
  in a commit message or report, from any session. Build on one only once
  a test in `t/` proves it; turn a check you rely on into such a test.
- Removing code: prove with a test that no caller is left, indirect ones
  included (HTML `on…=""` handlers, string-built names, `&{"main::$name"}`,
  sudo actions, port-85 templates). `t/webui_called_functions.t` covers the
  page JS.
- Independent review before a code change is reported done: a fresh agent
  (same model) gets the diff, the code it touches and this file, and none
  of the reasoning behind the change. It reports each finding as confirmed
  (repro) or plausible (code path); verify each one, fix or answer it, and
  report what the review found.

Report each change at its level, and name the levels still missing:
implemented / tested locally / repro fails on the old code / independently
reviewed / confirmed on the Pi. The release refuses to run without `t/` or
`prove`.

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

Everything goes through `.claude/skills/pi/scripts/pgen-pi` (the `pi`
skill). The hooks in `.claude/settings.json` enforce the rules below:
`pi_guard.py` refuses raw ssh, a written-out password, dummy bodies,
unbacked system writes and unchecked probes; `pi_stop.py` stops the end of
a turn while a snapshot is open.

- Before probes or restarts: `pgen-pi busy`, as its own step (runs
  `.claude/skills/pi/scripts/pi_calman_busy.sh` on the Pi, the only copy;
  `tools/pi_calman_busy.sh` must stay identical, t/pi_calman_busy.t). It
  counts only client traffic and prints the
  log line behind each reason; read that line before telling the user the
  Pi is in use (an older copy on the Pi matched every "Calman" log line):
  - In use: an established socket from a foreign peer on 85/2100/2101, or
    client traffic (`Calman RAW:`/`UPGCI:`/RPC, `INIT` without a close)
    from a foreign peer within the last minutes.
  - Not in use: `Calman G1: basic_alignment …` (the alignment plate drawn
    at every daemon start), `Calman GCI: suppressed save …` (written by
    WebUI/API config posts), and our own probes (`peer=127.0.0.1` or the
    Mac's IP).
  If a real session is found, do not touch the device; ask. If it is
  still unclear after checking, ask and say what you found.
- Deploy safely: `pgen-pi deploy` (names the Pi file's version against
  the branch and stops on another branch's, backs up to
  `/root/pgen-backups/`, guards against empty files, compares md5, writes a
  restore.sh).
- OLED: test on screen with dim windows (20 IRE, 10 %), not full white.
- Give the user's signal settings back at the end of a test: `pgen-pi
  snapshot` before, `pgen-pi restore` after.
- Without a display the renderer waits; forcing the connector on without
  an EDID crashes the renderer on mode switches.

## Git and releases

- Push only with `git push fork main` (fork = BlackJoker90). `origin` is
  upstream BigShoots: never push there.
- Releases are OTA packages (`tools/release-ota.sh`); a flashable image
  only for boot/base-system changes. The release script refuses untracked
  runtime files: `git add` new files first.
- README follows the product without being asked: when something
  fundamental is added or changed (a new setting, workspace, card, endpoint,
  signal mode or behaviour a user would notice), update `README.md` in the
  same piece of work: the fork-vs-original table, the workspace table, the
  API list, and new or retaken screenshots (`screenshots/`, Volt theme,
  1280x800, Desktop layout, GET-only, no real reboots or setting POSTs).
  It reaches GitHub with the release that ships the feature, so the README
  never describes something users cannot install yet.
- Commits, pushes, releases, reboots and deploys need the maintainer's OK.
- Code comments, commit messages and repo docs are in English.
