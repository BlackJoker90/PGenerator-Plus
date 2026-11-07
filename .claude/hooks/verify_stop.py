#!/usr/bin/env python3
"""Stop hook: the fast checks of CLAUDE.md "Verify after a change" on the
files changed in this session, before a turn ends.

1. Syntax: a file changed in this session does not parse. Only checks that
   run nothing from the tree: WebUI JavaScript (compiled by vm.Script, not
   run), Python (ast and tokenize inside this process), shell (bash -n).
   The hook runs outside the Bash sandbox, so it never runs code a sandboxed
   command could have written: no Perl on the tree (perl -c runs BEGIN
   blocks and `use`), no git (the repo config can name commands:
   core.fsmonitor, filters), no symlinked files. Perl is left to 2.
2. Tests: a code file under usr/, src/, etc/ or the project's hook and pi
   scripts was changed in this turn after the last test run (a `prove` or a
   tools/repro_old_new.sh command in a Bash call of this session; text in
   quotes or a heredoc does not count); changed Perl files are named with
   the perl -c they still need. The transcript can lag at stop time, so it
   is read again once before the hint is given.

Both go into one block, once per turn: a stop with stop_hook_active goes
through, so a turn can end with an explained reason ("waiting for the
user", "half-done on purpose"). What is still open (files that do not
parse, code changed after the last test run) is then named in a
systemMessage for the user, as are checks that could not run (no node, a
timeout).

"Changed in this session" is an mtime after the transcript's first entry;
"this turn" starts at the first transcript entry of the hook's prompt_id.
Without a readable transcript nothing is checked. Python under usr/ and
pi_state.py (pgen-pi runs it on the Pi) are checked as Python 3.5:
ast.parse(feature_version=(3,5)), plus what ast on a new Python accepts
there and the Pi's Python 3.5.3 refuses (f-/t-strings, async generators,
await in comprehensions, parenthesised context managers with `as`, relaxed
decorators, a trailing comma after *args/**kwargs/keyword-only parameters,
`return 1, *a`, `a[*b]`, `continue` in finally, `from __future__ import
annotations`) and stdlib modules it lacks (PY35_MISSING_MODULES); each
case was checked against the Pi's python3.5 (t/data/py35_fixtures.json).
`async` as a name is refused although 3.5 takes it. py_compile on the Pi
stays the binding check.

Test reminders skip files that hold no code a test runs (NO_TEST_SUFFIXES:
CSS, HTML, Markdown, images); the release gate still runs every test,
t/webui_called_functions.t on the HTML handlers included.

An error of the hook itself goes to stderr (exit 1, non-blocking), so a
broken hook never holds a turn; settings.json maps a missing hook file
(python3 exits 2, which on Stop would block) to exit 1 as well.
"""
import ast, calendar, io, json, os, re, subprocess, sys, tempfile, time, tokenize

WALK = ("usr", "src", "etc", ".claude/hooks", ".claude/skills/pi/scripts")
CODE_PREFIXES = ("usr/", "src/", "etc/", ".claude/hooks/", ".claude/skills/pi/scripts/")
SYNTAX_PREFIXES = ("usr/", "etc/", ".claude/hooks/", ".claude/skills/pi/scripts/")
PI_PYTHON = (".claude/skills/pi/scripts/pi_state.py",)  # pgen-pi runs it on the Pi
# Changed alone, these ask for no test run (review 2026-11-07: 5 of 13
# reminders were for such files only).
NO_TEST_SUFFIXES = (".css", ".html", ".htm", ".md", ".png", ".svg", ".jpg", ".jpeg", ".gif", ".ico",
                    ".woff", ".woff2")
SKIP_DIRS = {".git", "__pycache__", "node_modules"}
TIMEOUT = 20
SEGMENT_SPLIT = re.compile(r"&&|\|\||[;|&\n()`]|\$\(")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
QUOTED = re.compile(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"")


def strip_text(command):
    """The command without heredoc bodies and quoted strings: `prove` in a
    commit message, an echo or a script fed to python is no test run."""
    lines, out, end = command.split("\n"), [], None
    for line in lines:
        if end is not None:
            if line.strip() == end:
                end = None
            continue
        m = HEREDOC.search(line)
        if m:
            end = m.group(2)
        out.append(line)
    # A quoted single word stays a word ('prove' -r t runs prove); quoted
    # text with spaces (a message, an echo) is text.
    return QUOTED.sub(lambda q: q.group(0)[1:-1] if re.match(r"^['\"][\w./-]+['\"]$", q.group(0)) else "''",
                      "\n".join(out))


def runs_tests(command):
    """True if a segment of a shell command starts `prove` or the repro script."""
    for seg in SEGMENT_SPLIT.split(strip_text(command or "")):
        words = seg.split()
        while words and (ASSIGNMENT.match(words[0]) or words[0] in ("env", "time", "nice", "exec", "command", "nohup")):
            w = words.pop(0)
            # env -u NAME / env -i / env --: options before the command
            while w == "env" and words and words[0].startswith("-"):
                o = words.pop(0)
                if o in ("-u", "--unset", "-C", "--chdir", "-S", "--split-string") and words:
                    words.pop(0)
            if w == "nice" and words and words[0] == "-n" and len(words) > 1:
                words[:2] = []
        if not words:
            continue
        first = os.path.basename(words[0])
        if first == "prove" or first == "repro_old_new.sh":
            return True
        if first in ("bash", "sh") and len(words) > 1 and os.path.basename(words[1]) == "repro_old_new.sh":
            return True
    return False


def changed_since(root, since):
    """Regular files (not symlinks) under WALK with an mtime after `since`."""
    files = []
    for top in WALK:
        base = os.path.join(root, top)
        if os.path.islink(base) or not os.path.isdir(base):
            continue
        for d, dirs, names in os.walk(base):
            dirs[:] = [x for x in dirs if x not in SKIP_DIRS and not os.path.islink(os.path.join(d, x))]
            for n in names:
                p = os.path.join(d, n)
                try:
                    if os.path.islink(p) or not os.path.isfile(p) or os.path.getmtime(p) <= since:
                        continue
                except OSError:
                    continue
                files.append(os.path.relpath(p, root).replace(os.sep, "/"))
    return sorted(set(files))


def first_line(path):
    try:
        with open(path, "rb") as f:
            return f.readline(256).decode("latin-1")
    except OSError:
        return ""


def kind_of(rel, path):
    head = first_line(path)
    shebang = head if head.startswith("#!") else ""
    if rel.endswith(".pm") or re.search(r"perl", shebang):
        return "perl"
    if not rel.startswith(SYNTAX_PREFIXES):
        return None
    if rel.endswith(".js") and rel.startswith("usr/"):
        return "js"
    if rel.endswith(".py") or re.search(r"python", shebang):
        return "py35" if rel.startswith("usr/") or rel in PI_PYTHON else "py"
    if re.search(r"/(ba)?sh\b|env (ba)?sh\b", shebang):
        return "sh"
    return None


def run(cmd):
    # cwd outside the tree: nothing there is picked up by node or bash.
    p = subprocess.run(cmd, cwd=tempfile.gettempdir(), stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=TIMEOUT)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def first_error_line(text):
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return text.strip()


JS_PARSE = ("new (require('vm').Script)(require('fs').readFileSync(process.argv[1],'utf8'),"
            "{filename:process.argv[1]})")


def check_js(path):
    try:
        rc, out = run(["node", "-e", JS_PARSE, path])
    except FileNotFoundError:
        return ("note", "not checked, node not found")
    if rc == 0:
        return None
    lines = [l for l in out.splitlines() if "Error" in l]
    return ("error", (lines[0] if lines else first_error_line(out)).strip())


def check_py35(path):
    with open(path, "rb") as f:
        src = f.read()
    try:
        ast.parse(src, filename=path, feature_version=(3, 5))
    except SyntaxError as e:
        return ("error", "line %s: %s (Python 3.5)" % (e.lineno, e.msg))
    except ValueError as e:
        return ("error", str(e))
    # ast on a new Python accepts f-strings even with feature_version=(3,5).
    try:
        for t in tokenize.tokenize(io.BytesIO(src).readline):
            name = tokenize.tok_name.get(t.type, "")
            if name in ("FSTRING_START", "TSTRING_START"):
                return ("error", "line %d: f-/t-string, not Python 3.5" % t.start[0])
            if t.type == tokenize.STRING:
                m = re.match(r"([A-Za-z]*)['\"]", t.string)
                if m and re.search(r"[fFtT]", m.group(1)):
                    return ("error", "line %d: f-/t-string, not Python 3.5" % t.start[0])
    except (tokenize.TokenError, SyntaxError) as e:
        return ("error", "tokenize: %s" % e)
    try:
        tree = ast.parse(src, filename=path)
        found = py35_tree(tree, src.decode("utf-8", "replace")) or py35_tokens(src)
    except (SyntaxError, ValueError, tokenize.TokenError) as e:
        return ("error", "%s" % e)
    if found:
        return ("error", "line %d: %s, not Python 3.5" % found)
    return None


# What the Pi's Python 3.5.3 refuses but ast.parse(feature_version=(3,5)) on
# a new Python accepts. Each case was compiled with the Pi's own python3.5
# (tools/image-targets/pi4-biasi/rootfs/usr/bin/python3.5 under qemu,
# 2026-11-07; t/python35_syntax.t holds the cases); the modules failed to
# import there.
PY35_MISSING_MODULES = ("secrets", "contextvars", "dataclasses", "graphlib", "zoneinfo", "tomllib",
                        "importlib.metadata", "importlib.resources")


def _own_nodes(node):
    """node's descendants, not entering nested functions, lambdas or classes."""
    for child in ast.iter_child_nodes(node):
        if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)):
            continue
        yield child
        for x in _own_nodes(child):
            yield x


def _bare_starred_tuple(node, text):
    """A tuple with *x and no parentheses of its own (return 1, *a; also
    return (1), *a). The tuple's source is taken by ast.get_source_segment,
    which counts offsets in UTF-8 bytes as ast does (a slice of the decoded
    line was off after a non-ASCII character, review 2026-11-07); its own
    parentheses are a ( at the start whose ) is the last token."""
    if not isinstance(node, ast.Tuple) or not any(isinstance(e, ast.Starred) for e in node.elts):
        return False
    seg = ast.get_source_segment(text, node) or ""
    if not seg.startswith("("):
        return True
    depth = 0
    try:
        toks = [t for t in tokenize.generate_tokens(io.StringIO(seg).readline)
                if t.type == tokenize.OP]
    except (tokenize.TokenError, SyntaxError):
        return True
    for i, t in enumerate(toks):
        if t.string in "([{":
            depth += 1
        elif t.string in ")]}":
            depth -= 1
            if depth == 0:
                return i != len(toks) - 1
    return True


def _dotted(node):
    while isinstance(node, ast.Attribute):
        node = node.value
    return isinstance(node, ast.Name)


def py35_tree(tree, text):
    """(line, what) of the first construct the AST shows Python 3.5 lacks."""
    for node in ast.walk(tree):
        if isinstance(node, ast.AsyncFunctionDef):
            for x in _own_nodes(node):
                if isinstance(x, (ast.Yield, ast.YieldFrom)):
                    return (x.lineno, "yield inside async def (async generator, 3.6)")
        if isinstance(node, (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)):
            for x in _own_nodes(node):
                if isinstance(x, ast.Await):
                    return (x.lineno, "await in a comprehension (3.6)")
        if isinstance(node, ast.Try) or type(node).__name__ == "TryStar":
            todo = list(node.finalbody)
            while todo:
                x = todo.pop()
                if isinstance(x, ast.Continue):
                    return (x.lineno, "continue in finally (3.8)")
                if isinstance(x, (ast.For, ast.AsyncFor, ast.While, ast.FunctionDef, ast.AsyncFunctionDef,
                                  ast.ClassDef, ast.Lambda)):
                    continue
                todo.extend(ast.iter_child_nodes(x))
        if isinstance(node, (ast.Return, ast.Yield)) and _bare_starred_tuple(node.value, text):
            return (node.lineno, "unparenthesised *x in return/yield (3.8)")
        # for x in 1, *a: / x += 1, *a: same 3.5 testlist as return
        # (Python 3.5.3 refuses both, t/data/py35_fixtures.json)
        if isinstance(node, (ast.For, ast.AsyncFor)) and _bare_starred_tuple(node.iter, text):
            return (node.lineno, "unparenthesised *x after for ... in (3.9)")
        if isinstance(node, ast.AugAssign) and _bare_starred_tuple(node.value, text):
            return (node.lineno, "unparenthesised *x in augmented assignment (3.9)")
        if isinstance(node, ast.Subscript):
            sl = node.slice.value if type(node.slice).__name__ == "Index" else node.slice
            if _bare_starred_tuple(sl, text) or isinstance(sl, ast.Starred):
                return (node.lineno, "*x in a subscript (3.11)")
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            for d in node.decorator_list:
                if not _dotted(d.func if isinstance(d, ast.Call) else d):
                    return (d.lineno, "decorator that is not a dotted name or call (3.9)")
        if isinstance(node, ast.ImportFrom) and node.module == "__future__" and \
                any(a.name == "annotations" for a in node.names):
            return (node.lineno, "from __future__ import annotations (3.7)")
        names = [a.name for a in node.names] if isinstance(node, ast.Import) else \
            [node.module or ""] + ["%s.%s" % (node.module, a.name) for a in node.names] \
            if isinstance(node, ast.ImportFrom) and not node.level else []
        for n in names:
            if any(n == m or n.startswith(m + ".") for m in PY35_MISSING_MODULES):
                return (node.lineno, "module %s (not in the Pi's Python 3.5 stdlib)" % n)
    return None


def py35_tokens(src):
    """(line, what) of a trailing comma after *args/**kwargs/keyword-only
    parameters in a def or lambda, or `with (a as b)`."""
    toks = [t for t in tokenize.tokenize(io.BytesIO(src).readline)
            if t.type not in (tokenize.NL, tokenize.COMMENT, tokenize.ENCODING)]
    for i, t in enumerate(toks):
        if t.type != tokenize.NAME or t.string not in ("def", "lambda", "with"):
            continue
        j = i + 1
        if t.string == "def":
            j += 1  # the name
            if j >= len(toks) or toks[j].string != "(":
                continue
            j += 1
            close, depth = ")", 1
        elif t.string == "lambda":
            close, depth = ":", 1
        else:
            if j >= len(toks) or toks[j].string != "(":
                continue
            j += 1
            close, depth = ")", 1
        star = False
        prev = None
        while j < len(toks):
            s = toks[j].string
            if toks[j].type == tokenize.OP and s in "([{" and s:
                depth += 1
            elif toks[j].type == tokenize.OP and s in ")]}" and s:
                depth -= 1
            if (depth == 0 and s == close) or (close == ":" and depth == 1 and s == ":"):
                break
            if depth == 1:
                if t.string == "with" and toks[j].type == tokenize.NAME and s == "as":
                    return (t.start[0], "parenthesised context managers with `as` (3.9)")
                # a parameter that starts with * or ** (not a product in a default)
                if s in ("*", "**") and (prev is None or prev.string in ("(", ",")):
                    star = True
            prev = toks[j]
            j += 1
        if t.string != "with" and star and prev is not None and prev.string == ",":
            return (t.start[0], "trailing comma after *args, **kwargs or keyword-only parameters (3.6)")
    return None


def check_py(path):
    with open(path, "rb") as f:
        src = f.read()
    try:
        ast.parse(src, filename=path)
    except SyntaxError as e:
        return ("error", "line %s: %s" % (e.lineno, e.msg))
    except ValueError as e:
        return ("error", str(e))
    return None


def check_sh(path):
    # /bin/sh is bash on the Pi image (see the release check).
    rc, out = run(["bash", "-n", path])
    return ("error", first_error_line(out) or "bash -n exited %d" % rc) if rc != 0 else None


CHECKS = {"js": check_js, "py35": check_py35, "py": check_py, "sh": check_sh}


def syntax(root, files):
    """([(file, message)] parse errors, [text] checks that could not run, [perl files])."""
    errors, notes, perl = [], [], []
    for rel in files:
        path = os.path.join(root, rel)
        kind = kind_of(rel, path)
        if kind == "perl":
            perl.append(rel)
            continue
        if not kind:
            continue
        try:
            res = CHECKS[kind](path)
        except subprocess.TimeoutExpired:
            res = ("note", "not checked, timed out after %ds" % TIMEOUT)
        except OSError as e:
            res = ("note", "not checked, %s" % e)
        if res and res[0] == "error":
            errors.append((rel, res[1]))
        elif res:
            notes.append("%s: %s" % (rel, res[1]))
    return errors, notes, perl


def iso_time(s):
    m = re.match(r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?Z?$", s or "")
    if not m:
        return None
    t = calendar.timegm(tuple(int(x) for x in m.groups()[:6]))
    return t + (float(m.group(7)) if m.group(7) else 0.0)


def transcript_times(path, prompt_id):
    """(session start, turn start, start of the last test run) as epoch
    seconds; None for what the transcript does not show."""
    start, turn, last_run = None, None, None
    if not path or not os.path.isfile(path):
        return None, None, None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            ts = iso_time(d.get("timestamp"))
            if ts is None:
                continue
            if start is None or ts < start:
                start = ts
            if prompt_id and d.get("promptId") == prompt_id and (turn is None or ts < turn):
                turn = ts
            if d.get("type") != "assistant":
                continue
            content = (d.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for c in content:
                if (isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == "Bash"
                        and runs_tests(str((c.get("input") or {}).get("command", "")))):
                    if last_run is None or ts > last_run:
                        last_run = ts
    return start, turn, last_run


def main_checkout(root):
    """The main checkout of a worktree (read from .git, without running git)."""
    dotgit = os.path.join(root, ".git")
    try:
        if os.path.isfile(dotgit):
            with open(dotgit) as f:
                m = re.match(r"gitdir:\s*(.+)", f.read().strip())
            gitdir = os.path.join(root, m.group(1)) if m else None
            with open(os.path.join(gitdir, "commondir")) as f:
                common = os.path.normpath(os.path.join(gitdir, f.read().strip()))
            return os.path.dirname(common)
    except (OSError, TypeError, AttributeError):
        pass
    return root


def listed(items, limit=8):
    return ", ".join(items[:limit]) + (" (+%d more)" % (len(items) - limit) if len(items) > limit else "")


def main():
    data = json.load(sys.stdin)
    root = os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or os.getcwd())
    active = bool(data.get("stop_hook_active"))
    transcript, prompt_id = data.get("transcript_path"), data.get("prompt_id")
    start, turn, last_run = transcript_times(transcript, prompt_id)
    if start is None:
        return
    files = changed_since(root, start)
    if not files:
        return
    errors, notes, _ = syntax(root, files)

    def stale_now():
        since = max(turn or start, last_run or 0)
        return [f for f in files if f.startswith(CODE_PREFIXES) and not f.lower().endswith(NO_TEST_SUFFIXES)
                and os.path.getmtime(os.path.join(root, f)) > since]
    stale = stale_now()
    if stale and not errors:
        time.sleep(1)  # the transcript is written asynchronously
        start, turn, last_run = transcript_times(transcript, prompt_id)
        stale = stale_now() if start is not None else []

    out, messages, reasons = {}, [], []
    if errors:
        reasons.append("files changed in this session do not parse (CLAUDE.md \"Verify after a change\"):\n  "
                       + "\n  ".join("%s: %s" % e for e in errors)
                       + "\nFix them. If the turn has to end with them broken, say why in the reply and stop again.")
    if stale:
        # Also next to a parse error: the fix is one more change to test.
        perl = [f for f in stale if kind_of(f, os.path.join(root, f)) == "perl"]
        repro = os.path.join(main_checkout(root), "tools", "repro_old_new.sh")
        reasons.append(
            "code changed in this turn after the last test run: %s. "
            "Run `prove -r t` on a fresh copy (in a worktree: the tree plus the main checkout's t/, "
            "see .claude/agents/pgen-reviewer.md), and for a fix `bash %s t/<test>.t` "
            "(fails on the old code, passes on the new).%s "
            "If tests just ran or do not apply, say so in the reply and stop again."
            % (listed(stale), repro,
               (" Perl, not parsed by this hook: `perl -I usr/share/PGenerator -c` for scripts, "
                "pgen_release_check_runtime_syntax for modules: %s." % listed(perl)) if perl else ""))
    if reasons and not active:
        out = {"decision": "block", "reason": "verify_stop: " + "\n\nverify_stop: ".join(reasons)}
    else:
        if errors:
            messages.append("still do not parse: " + "; ".join("%s: %s" % e for e in errors))
        if stale:
            messages.append("no test run after the last change to " + listed(stale))
    messages.extend(notes)
    if messages:
        out["systemMessage"] = "verify_stop: " + "; ".join(messages)
    if out:
        print(json.dumps(out))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        sys.stderr.write("verify_stop error: %s: %s\n" % (type(e).__name__, e))
        sys.exit(1)
