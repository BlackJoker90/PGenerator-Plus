# rampecho (BlackJoker90's fork of PGenerator+)

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
- PGenerator 1.6 is the gold standard (reference implementation) for what
  goes on the cable, wherever a standard leaves room (see "Research, don't
  guess"). PiTPG (pitpgd) is not a reference: nothing is taken over from it
  unchecked. Compare anything PiTPG-derived against 1.6 (binary, templates,
  a readback), the standard and, where Calman drives a hardware generator,
  Calman's own packet; where they differ, 1.6 wins unless a standard or a
  readback proves otherwise, and name the difference. Where 1.6 departs
  from a standard, the maintainer decides (Dolby Vision metadata id: 0 as
  1.6, not stepping as ETSI 6.3.1). Decided exceptions to 1.6 (maintainer,
  2026-11-17): in a Calman session the DV packet is Calman's own (with
  `signal_color_space` 0), and the Standard DV infoframe follows the
  display's Dolby block (Amlogic's rule; 1.6 sends HDMI 1.4b with HDMI_VIC
  1 in every timing when a client sets 1.6's dv_interface to 1, its kernel
  value for that layout; our conf's dv_interface 1 is Low Latency), with
  PiTPG's two departures from that rule kept (maintainer, 2026-11-09 and
  2026-11-17): a 12-byte version 1 block always gets the Dolby form, and
  4K24/25/30 and 4096x2160p24 no HDMI_VIC. The metadata id is 0 in all
  three packet forms, PiTPG's included (2026-11-18). The Standard DV packet
  had taken over PiTPG's L4 block and start sequence, which neither 1.6 nor
  Calman send; outside Calman and PiTPG sessions it now sends 1.6's
  packet, checked against 1.6's templates by `t/renderer_dovi_metadata.t`
  (ChadB, 2026-11-17). Outside PiTPG sessions the tunnel codes and the
  metadata pixels are 1.6's: its matrix, 8-bit grid and packing, but
  rounded exactly (integer arithmetic on the GPU, not 1.6's float32,
  which a CPU model of its shader puts one Cb/Cr code off for ~0.03 % of
  the colours; 1.6 on the GPU is not read back), without 1.6's
  picture-path faults (fp16 texels 240..254, odd pixels paired with the
  next pair), with exactly 3072 metadata pixels (1.6's stray white one
  left out); PiTPG sessions keep PiTPG's arithmetic and parity embedding,
  also for a first draw without an apply. The Pi 5 renderer flavour has
  no 1.6 tunnel (`pg16_shaders` 0; its own tunnel is not read back). The
  WebUI's DV series codes, and every patch it sends, lie on 1.6's 8-bit
  grid whenever the cable
  carries that tunnel (`pg_dv_tunnel_pg16_grid`: Standard in the running
  renderer's start record when it runs in Dolby Vision, else the conf;
  no PiTPG packet, no full
  tunnel, a Pi 4; the Patch Companion gets the same codes),
  so a run records the code sent and a grey's target
  follows it (maintainer, 2026-11-18); a colour's target stays its
  reference colour, as at 8 bits in SDR, and a custom greyscale profile
  keeps its targets (`t/renderer_pg16_tunnel.t`, `t/pitpg_backend.t`,
  `t/webui_dv_tunnel_grid.t`, `t/meter_series_dv_tunnel_grid.t`,
  `t/webui_dv_grid_chart_targets.t`, `t/meter_saturation_series_steps.t`).

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

- `prove -j16 -Q --state=slow,save --statefile=t/.prove-state -r t`
  (code-value tests: bits, Calman scaling, G1 plates, playlists): the full
  suite as the release gate runs it, slowest files first from the timings
  every such run saves in `t/.prove-state`. 2026-11-19: 124 s (-j8 in name
  order 194-206 s; serial it outlasts a 600 s Bash call). Never put
  `--state=slow` next to a single test: it runs every test the state
  names. `-v` only on a failing file.
  The Bash sandbox lacks what some tests need (ptys, `/usr/bin/time -l`,
  headless Chrome and WebKit, listening sockets, the process list). There
  they skip that part and print `# t/<file>: sandbox: <what>; rerun
  unsandboxed` on stderr (`t/lib/PGTestSandbox.pm`). Outside the sandbox a
  missing pty or `time -l` stays a failure, but a browser, socket or
  process list that is missing or does not start skips there too, as does
  a test without a tool it needs (a C/C++ compiler or its sanitizers,
  python3, node, git, expect, the libdrm headers), and prints
  `# t/<file>: skipped: <what>`. The release gate refuses a run with a
  `sandbox:` line, and one with a `skipped:` line unless
  `PGEN_ALLOW_SKIPPED=1` (all of them) or `PGEN_ALLOW_SKIPPED_REASONS`
  (a Perl regex on the reason) accepts it. After a sandboxed run, rerun
  unsandboxed every file that printed `sandbox:` and every red file
  before calling a red
  real or a green complete; a change is covered only once its tests ran
  (no `sandbox:` or `skipped:` line from them: browser tests for the
  WebUI, the compiled renderer tests for the renderer).
  `t/repo_links.t` and `t/python35_syntax.t` (the Python 3.5 check of
  the tracked tree) need `.git` (`git ls-files`): a copy without it skips
  that part and says so on stderr. The main checkout runs them for main;
  for a worktree's change, `git init` the copy and `git add -f` the
  worktree's `git ls-files` (main's tree is other code). If prove dies in
  `YAMLish/Reader.pm` before the first test, `t/.prove-state` is damaged:
  delete it (the release gate moves it aside itself).
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
  (same model; the `pgen-reviewer` agent in `.claude/agents/`) gets the diff, the code it touches and this file, and none
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
`pi_guard.py` (on Bash and Monitor commands) refuses raw ssh, a
written-out password, dummy bodies,
system writes outside `pgen-pi deploy` and unchecked probes; `pi_stop.py` stops the end of
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

- Nothing ever goes to a repo other than BlackJoker90/rampecho: no
  push, PR, issue, comment or release. `origin` is upstream BigShoots.
  Push only with `git push fork main`.
- The repository was BlackJoker90/PGenerator-Plus until 2026-11-15. GitHub
  redirects the old name, and devices on 2.13.x update through that
  redirect: never create a repository of the old name again.
- Every `gh` write names the repo (`-R BlackJoker90/rampecho`; `gh
  repo edit`, `sync`, `delete` and the like take it as argument).
  `pi_guard.py` refuses what it can read as going elsewhere, in Bash and
  Monitor commands only;
  it is a net for slips, not a proof.
- T3's PR button does not run gh: it posts to the GitHub API and takes the
  target from `GH_REPO`, then the `remote.*.gh-resolved` mark, then the
  remote names, where `origin` beats `fork` (read in its app bundle). The
  missing mark is the likely way BigShoots #61 was opened. A new clone
  needs `gh repo set-default BlackJoker90/rampecho`, which sets the
  mark, and `git remote set-url --push origin
  PUSH-DISABLED-only-BlackJoker90-fork`, also in
  `vendor/ArgyllCMS_ICC4.4` (its remote is BigShoots/ArgyllCMS_ICC4.4).
- Releases are OTA packages (`tools/release-ota.sh`); a flashable image
  only for boot/base-system changes or when the maintainer asks. The
  release script refuses untracked runtime files: `git add` new files first.

- README follows the product without being asked: when something
  fundamental is added or changed (a new setting, workspace, card, endpoint,
  signal mode or behaviour a user would notice), update `README.md` in the
  same piece of work: the fork-vs-original table, the workspace table, the
  API list, and new or retaken screenshots (`screenshots/`, Glow theme,
  1280x800, Desktop layout, GET-only, no real reboots or setting POSTs).
  It reaches GitHub with the release that ships the feature, so the README
  never describes something users cannot install yet.
- Commits, pushes, releases, reboots and deploys need the maintainer's OK.
- Code comments, commit messages and repo docs are in English.

## Building a flashable image

Pi 4 images are built in the Parallels VM `pgen-build` by
`tools/image-build/run-in-vm.sh` (background: `tools/BUILD-IMAGE-PI4.md`).
It builds the working tree of `MAC_REPO` (default: the main checkout)
onto the v2.12.1 base in `/root/pgbase`, runs `prove` as root, fscks the
result, checks version, renderer, `drm_override.so` and the patched
`vc4.ko` (md5 hard-coded in the script: update it with the module),
compresses with xz, copies the `.img.xz` and `_sha256.txt` to
`$MAC_REPO/build/` and deletes the copies in the VM.

- An image of a released version is built from that tag, never from
  `main`: `git clone` the main checkout (a clone, not a worktree: the
  script needs a `.git` directory) to `/Users/fabio/pgen-image-<ver>`,
  `git checkout v<ver>`, `git remote set-url --push origin PUSH-DISABLED`,
  then copy in the local-only `tools/`, `build/runtime-cache/` and `t/`.
- `t/` is not versioned: run the full suite (`prove -j16 -Q
  --state=slow,save --statefile=t/.prove-state -r t`) in the clone first. A
  red file there is acceptable only if it tests code after the tag (birth
  time `stat -f %SB` after the release's `publishedAt`, and a later commit
  it belongs to); remove those from the clone's `t/` and name them. Any
  other red stops the build.
- Start it detached and poll the log:
  `prlctl exec pgen-build 'MAC_REPO=/media/psf/Home/pgen-image-<ver> nohup bash /media/psf/Home/pgen-image-<ver>/tools/image-build/run-in-vm.sh > /root/image-build-<ver>.log 2>&1 &'`
  Wait for `^ERROR` or `] Done: ` in the log (a `pgrep -f run-in-vm`
  watcher matches its own command line and never ends). `t/` runs there
  as root on Linux: a test that needs macOS or a non-root user skips
  there, it does not fail. The VM has no headless Chrome or Playwright,
  no clang and no expect: run-in-vm.sh (and run-in-vm-pi5.sh) accept
  exactly those skip reasons (`VM_SKIP_REASONS`, passed as
  `PGEN_ALLOW_SKIPPED_REASONS`), so the build goes on and the log lists
  those files under "Warning: tests skipped parts this machine cannot
  run"; the Mac's release gate runs them. Any other skip stops the
  build (an inherited `PGEN_ALLOW_SKIPPED=1` or
  `PGEN_RELEASE_PREFLIGHT_DONE=1` is dropped there;
  `PGEN_SKIP_RELEASE_CHECKS=1` still skips every check, with a warning).
  `t/pg_v4l2_runtime.t` and `t/pg_drm_player_runtime.t` run only
  there (Linux, `libdrm-dev` installed in the VM since 2026-11-19; the
  scripts refuse to start without it; the target builds use their
  chroots, not these headers).
  The log must end in "Output image OK" and "Done", and must not say
  "node not found" (nodejs is installed in the VM since 2026-11-16; the
  release checks parse the WebUI JS with it).
- GitHub limits assets to 2 GiB: split the `.img.xz` into `.001` (1992294400
  bytes) and `.002`, write `<name>.img.xz.sha256` for the joined file, upload
  the three with `gh release upload v<ver> -R BlackJoker90/rampecho`, then
  compare sizes and GitHub's per-asset sha256 digest with the local parts.
- Notes: add a "Flashing the image" section (join, check, flash; Export /
  Import System Settings) with `gh release edit --notes-file`; on a release
  that is not "latest" pass `--latest=false`.
- From 3.0.2 the image boots without the initramfs: the builder runs
  `update-migrations.d/3.0.2-boot-no-initramfs.sh` on it (the script OTA
  devices run), and `run-in-vm.sh` checks `root=PARTUUID`, the commented
  initramfs line and that `/boot/loader/boot_dir` (the WebUI's copy of the
  boot files) equals the boot partition. An image of an older tag keeps
  the initramfs.
- An image serves its MAJOR.MINOR family: the updater only offers updates
  within it (`same_ota_family`), so a device of another family re-flashes.
- Afterwards: the VM copy is gone (the script deletes it); the Mac copies in
  `build/` and the clone are deleted on the maintainer's word.
