#!/usr/bin/env python3
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

MAX_COLS = 100
MAX_COMMENT_LINES = 1
MAX_DOCSTRING_LINES = 5
LIMITS = (f"Limit {MAX_COMMENT_LINES} line, {MAX_COLS} chars;"
          f" docstring {MAX_DOCSTRING_LINES} lines.")
MAX_FILE = 1 << 20
WALK_CAP = 200000
SNAPSHOT_CAP = 20000
STOP_REPEATS = 2
STATE_TTL = 7 * 86400

C = dict(line=("//",), block=(("/*", "*/"),), strings=('"', "'"))
LANGS = {
    "c": C, "h": C, "cpp": C, "hpp": C, "cc": C,
    "js": dict(C, strings=('"', "'", "`")),
    "ts": dict(C, strings=('"', "'", "`")),
    "go": dict(C, strings=('"', "'", "`"), noesc=("`",)),
    "kt": dict(C, strings=('"""', '"', "'"), noesc=('"""',), nested=True),
    "rs": dict(C, strings=('"',), nested=True, char_lit=True),
    "py": dict(line=("#",), block=(), strings=('"""', "'''", '"', "'"),
              docstring=True),
    "sh": dict(line=("#",), block=(), strings=('"', "'"), noesc=("'",),
              hash_word_start=True),
    "lua": dict(line=("--",), block=(), strings=('"', "'"), lua=True),
}


def find_close(text, i, opener, closer, nested):
    depth = 1
    while i < len(text):
        if nested and text.startswith(opener, i):
            depth += 1
            i += len(opener)
        elif text.startswith(closer, i):
            depth -= 1
            i += len(closer)
            if depth == 0:
                return i
        else:
            i += 1
    return len(text)


def long_bracket(text, i):
    if text[i:i + 1] != "[":
        return None
    j = i + 1
    while text[j:j + 1] == "=":
        j += 1
    return j - i - 1 if text[j:j + 1] == "[" else None


def close_long(text, i, level):
    j = text.find("]" + "=" * level + "]", i + level + 2)
    return len(text) if j < 0 else j + level + 2


def scan(text, lang):
    units, code = [], set()
    n, i, ln = len(text), 0, 1
    if text.startswith("#!"):
        i = text.find("\n")
        i = n if i < 0 else i

    def span(j):
        nonlocal i, ln
        start = ln
        ln += text.count("\n", i, j)
        i = j
        return start, ln

    while i < n:
        c = text[i]
        if c == "\n":
            ln += 1
            i += 1
            continue
        if c in " \t\r\f\v":
            i += 1
            continue
        if lang.get("lua") and text.startswith("--", i):
            level = long_bracket(text, i + 2)
            if level is not None:
                units.append((*span(close_long(text, i + 2, level)), "comment"))
                continue
        hit = False
        for opener, closer in lang["block"]:
            if text.startswith(opener, i):
                j = find_close(text, i + len(opener), opener, closer,
                               lang.get("nested", False))
                units.append((*span(j), "comment"))
                hit = True
                break
        if hit:
            continue
        for marker in lang["line"]:
            if not text.startswith(marker, i):
                continue
            if lang.get("hash_word_start") and i > 0 and text[i - 1] not in " \t\n;(":
                continue
            j = text.find("\n", i)
            units.append((*span(n if j < 0 else j), "comment"))
            hit = True
            break
        if hit:
            continue
        if lang.get("lua"):
            level = long_bracket(text, i)
            if level is not None:
                s, e = span(close_long(text, i, level))
                code.update(range(s, e + 1))
                continue
        if lang.get("char_lit") and c == "'":
            j = text.find("'", i + 3) if text[i + 1:i + 2] == "\\" else (
                i + 2 if text[i + 2:i + 3] == "'" else -1)
            if j < 0:
                code.add(ln)
                i += 1
            else:
                s, e = span(j + 1)
                code.update(range(s, e + 1))
            continue
        for delim in lang["strings"]:
            if not text.startswith(delim, i):
                continue
            esc = delim not in lang.get("noesc", ())
            j = i + len(delim)
            while j < n and not text.startswith(delim, j):
                j += 2 if esc and text[j] == "\\" else 1
            j = min(j + len(delim), n)
            line_start = text.rfind("\n", 0, i) + 1
            doc = (lang.get("docstring") and len(delim) == 3
                   and text[line_start:i].strip() == "")
            s, e = span(j)
            if doc:
                units.append((s, e, "docstring"))
            else:
                code.update(range(s, e + 1))
            hit = True
            break
        if hit:
            continue
        code.add(ln)
        i += 1
    return units, code


def check(text, lang):
    units, code = scan(text, lang)
    lines = text.split("\n")
    runs = []
    for s, e, kind in sorted(units):
        full = kind == "comment" and not any(l in code for l in range(s, e + 1))
        if full and runs and runs[-1][3] and runs[-1][1] + 1 == s:
            runs[-1][1] = e
        else:
            runs.append([s, e, kind, full])
    out, seen = [], set()
    for s, e, kind, _ in runs:
        limit = MAX_DOCSTRING_LINES if kind == "docstring" else MAX_COMMENT_LINES
        if e - s + 1 > limit:
            out.append((s, e, f"{kind} {e - s + 1} lines, limit {limit}"))
        for l in range(s, e + 1):
            width = len(lines[l - 1].rstrip("\r"))
            if width > MAX_COLS and l not in seen:
                seen.add(l)
                out.append((l, l, f"{kind} line {width}/{MAX_COLS} chars"))
    return sorted(out), lines


def apply_edit(src, old, new, replace_all):
    out, pos = [], 0
    while True:
        j = src.find(old, pos)
        if j < 0:
            break
        out.append(src[pos:j])
        out.append(new)
        pos = j + len(old)
        if not replace_all:
            break
    out.append(src[pos:])
    return "".join(out)


EXT_RE = re.compile(r"\.(?:" + "|".join(LANGS) + r")(?![\w.])", re.I)
NONLIT_RE = re.compile(r"[$`*?{}\[\]]")
DEVS = {"/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty", "/dev/fd/1", "/dev/fd/2"}
PRUNE = {"node_modules", "target", "build", "dist", "out", "__pycache__", "venv",
         "CMakeFiles", "vendor", "third_party", "Pods", "zig-out", "zig-cache", "bazel-out"}


def lang_for(path):
    return LANGS.get(os.path.splitext(path)[1][1:].lower())


def read(path):
    try:
        if os.path.getsize(path) > MAX_FILE:
            return None
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def viol_lines(text, lang):
    viol, lines = check(text, lang)
    return {lines[l - 1] for s, e, _ in viol for l in range(s, e + 1)}


def new_viol(text, lang, pre):
    viol, lines = check(text, lang)
    return [v for v in viol
            if not all(lines[l - 1] in pre for l in range(v[0], v[1] + 1))]


def label(path):
    rel = os.path.relpath(path)
    return path if rel.startswith("..") else rel


def fmt(lbl, viol):
    return [f"{lbl}:{s}" + (f"-{e}" if e != s else "") + f" {msg}" for s, e, msg in viol]


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason}}))


def block(reason):
    print(json.dumps({"decision": "block", "reason": reason}))


class State:
    def __init__(self, path):
        self.dir = path
        self.fresh = not os.path.isdir(path)
        for sub in ("baseline", "bash"):
            os.makedirs(os.path.join(path, sub), exist_ok=True)
        if self.fresh:
            self.write("start", str(time.time()))

    @staticmethod
    def root():
        base = os.environ.get("XDG_RUNTIME_DIR")
        if not base:
            base = os.path.join(tempfile.gettempdir(), f"claude-hooks-{os.getuid()}")
        return os.path.join(base, "claude-hooks")

    @classmethod
    def for_session(cls, session_id):
        name = re.sub(r"[^\w.-]", "_", session_id or "nosession")
        return cls(os.path.join(cls.root(), name))

    def path(self, *parts):
        return os.path.join(self.dir, *parts)

    def write(self, name, text):
        with open(self.path(name), "w") as f:
            f.write(text)

    def read(self, name):
        try:
            with open(self.path(name)) as f:
                return f.read()
        except OSError:
            return None

    def start(self):
        try:
            return float(self.read("start") or "")
        except ValueError:
            return time.time()

    @staticmethod
    def key(path):
        return hashlib.sha1(os.path.realpath(path).encode()).hexdigest()

    def baseline(self, path):
        raw = self.read(os.path.join("baseline", self.key(path)))
        if raw is None:
            return None
        try:
            return set(json.loads(raw))
        except ValueError:
            return None

    def set_baseline(self, path, lines):
        try:
            fd = os.open(self.path("baseline", self.key(path)),
                         os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            return False
        with os.fdopen(fd, "w") as f:
            json.dump(sorted(lines), f)
        return True

    def touch(self, paths):
        if not paths:
            return
        with open(self.path("touched"), "a") as f:
            f.write("".join(os.path.realpath(p) + "\n" for p in paths))

    def touched(self):
        return sorted({l for l in (self.read("touched") or "").split("\n") if l})

    def stamp(self, tool_use_id):
        now = str(time.time())
        self.write(os.path.join("bash", "last"), now)
        if tool_use_id:
            self.write(os.path.join("bash", re.sub(r"[^\w.-]", "_", tool_use_id)), now)

    def stamped(self, tool_use_id):
        names = ["last"]
        if tool_use_id:
            names.insert(0, re.sub(r"[^\w.-]", "_", tool_use_id))
        for name in names:
            try:
                t = float(self.read(os.path.join("bash", name)) or "")
            except ValueError:
                continue
            if name != "last":
                try:
                    os.unlink(self.path("bash", name))
                except OSError:
                    pass
            return t
        return self.start()

    def stop_repeat(self, fp):
        try:
            data = json.loads(self.read("stop") or "{}")
        except ValueError:
            data = {}
        n = data.get("n", 0) + 1 if data.get("fp") == fp else 1
        self.write("stop", json.dumps({"fp": fp, "n": n}))
        return n


def git_head(path):
    d, name = os.path.split(path)
    try:
        r = subprocess.run(["git", "-C", d, "show", f"HEAD:./{name}"],
                           capture_output=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None


def baseline(state, path, lang):
    b = state.baseline(path) if state else None
    if b is not None:
        return b
    head = git_head(path)
    return viol_lines(head, lang) if head is not None else set()


def record(state, path, lang):
    if state is None or state.baseline(path) is not None:
        return
    src = read(path)
    state.set_baseline(path, viol_lines(src, lang) if src is not None else set())


def walk(root, since, deadline, cap=WALK_CAP):
    out, n, stack = [], 0, [root]
    while stack:
        try:
            it = os.scandir(stack.pop())
        except OSError:
            continue
        with it:
            for e in it:
                n += 1
                if n > cap or time.monotonic() > deadline:
                    return out
                if e.name.startswith("."):
                    continue
                try:
                    if e.is_dir(follow_symlinks=False):
                        if e.name not in PRUNE:
                            stack.append(e.path)
                    elif lang_for(e.name) and e.is_file(follow_symlinks=False):
                        st = e.stat(follow_symlinks=False)
                        if st.st_mtime >= since and st.st_size <= MAX_FILE:
                            out.append(e.path)
                except OSError:
                    pass
    return out


def check_files(state, paths, deadline):
    out, skipped = [], 0
    for p in paths:
        if time.monotonic() > deadline:
            skipped += 1
            continue
        lang = lang_for(p)
        src = read(p) if lang else None
        if src is None:
            continue
        out += fmt(label(p), new_viol(src, lang, baseline(state, p, lang)))
    if skipped:
        out.append(f"({skipped} files not checked, time budget)")
    return out


CMDPOS = (r"(?:^|[;|&(){}\n`]|\$\(|\b(?:sudo|doas|xargs|env|time|nohup|exec|command|nice"
          r"|ionice|stdbuf|unbuffer|timeout[ \t]+\S+)[ \t]+(?:-\S+[ \t]+)*)[ \t]*"
          r"(?:\w+=\S*[ \t]+)*")
ARGS = r"((?:[ \t]+[^\s|;&<>()]+)*)"


def cmd_re(names):
    return re.compile(CMDPOS + r"(" + names + r")\b" + ARGS)


REDIR_RE = re.compile(r"(?<![<>|=-])(?:\d*|&)(?:>>|>\|?)[ \t]*([^\s;|&()<>]*)")
INPLACE = [
    (re.compile(r"\bsed\b(?:[ \t]+[^\s|;&]+)*?[ \t]+(?:-[nErszubl]*i[^\s|;&]*|--in-place\S*)"),
     "sed -i"),
    (re.compile(r"\bperl\b(?:[ \t]+[^\s|;&]+)*?[ \t]+-[acnpsStTuUvwWXl0-9]*i[^\s|;&]*"),
     "perl -i"),
    (re.compile(r"\bruby\b(?:[ \t]+[^\s|;&]+)*?[ \t]+-[acdlnpsvwWy]*i[^\s|;&]*"), "ruby -i"),
    (re.compile(r"\b[gmn]?awk\b(?:[ \t]+[^\s|;&]+)*?[ \t]+(?:-i\S*|--inplace|--include\S*)"),
     "awk -i"),
    (re.compile(r"\bgit\b(?:[ \t]+-[Cc][ \t]+\S+|[ \t]+-\S+)*[ \t]+(?:apply|am)\b"), "git apply"),
    (cmd_re(r"sponge|ed|ex|patch|eval|vim?|nvim|gvim|vimdiff|view|emacs|nano|micro|hx|helix"
            r"|joe|pico"), "in-place editor"),
    (re.compile(r"\bgit\b(?:[ \t]+-[Cc][ \t]+\S+|[ \t]+-\S+)*[ \t]+(?:commit|merge|push|rebase)"
                r"\b[^|;&\n]*(?<!\S)(?:--no-verify|-[a-zA-Z]*n[a-zA-Z]*)(?!\S)"),
     "git hook bypass"),
    (re.compile(r"\bgit\b[^|;&\n]*(?:-c[ \t]*core\.hooksPath|\bconfig\b[^|;&\n]*(?:--unset\S*"
                r"[^|;&\n]*hooksPath|hooksPath[ \t]+\S))|\bGIT_CONFIG_\w+=[^|;&\n]*hooksPath"),
     "git hook bypass"),
]
TEE_RE = re.compile(r"\btee\b" + ARGS)
COPY_RE = cmd_re(r"cp|mv|rsync|ln|install|scp|rename")
FETCH_RE = cmd_re(r"curl|wget|aria2c|fetch|https?|httpie")
OUT_RE = re.compile(r"(?:(?<=\s)(?:-o|-O|--output(?:-document)?|--out)[=\s]*|\bof=)"
                    r"([^\s|;&<>()]+)")
INTERP = (r"python[0-9.]*|pypy[0-9.]*|perl[0-9.]*|ruby|jruby|node|nodejs|bun|deno|tsx|ts-node"
          r"|lua[0-9.]*|luajit|php[0-9.]*|[gmn]?awk|Rscript|julia|tclsh|expect|osascript|groovy"
          r"|scala|elixir|swift|ghci?|runghc|ocaml|raku|guile|racket")
INTERP_RE = cmd_re(INTERP)
INLINE_FLAG = re.compile(r"^(?:-[a-zA-Z]*[ceEpr][a-zA-Z]*|--?(?:eval|print)|-|eval)$")
NO_EXT_RULE = re.compile(r"^(?:perl|[gmn]?awk)")
WRITE_RE = re.compile(
    r"\bopen\s*\(|\.write\w*\s*\(|write_(?:text|bytes)|writeFile|\bPath\s*\(|shutil|pathlib"
    r"|\bos\.\w*(?:write|open|dup|exec|spawn|fork|rename|replace|remove|unlink|link|system"
    r"|popen|truncate|makedirs|mkdir|chdir)|subprocess|fileinput|inplace|extract"
    r"|\bio\.(?:open|output|popen)|\bFile\.|\bIO\.(?:write|binwrite|open|popen)|\bfs\.|\bDeno\."
    r"|child_process|print\s*>|printf\s*>|>\s*[\"']|\bsystem\s*\(|\bexec\w*\s*\(|\bspawn|\bpopen"
    r"|tempfile|mkstemp|savetxt|to_csv|\bdump\s*\(|\bsed\b|\btee\b|file:write|file_put_contents"
    r"|\bfopen|\bfwrite|__import__|importlib|getattr\s*\(|\beval\s*\(|builtins|ctypes|mmap")


def bad_target(t):
    t = t.strip("\"'")
    return bool(EXT_RE.search(t) or NONLIT_RE.search(t))


def same_ext(a, b):
    return os.path.splitext(a)[1].lower() == os.path.splitext(b)[1].lower()


def snip(s):
    s = " ".join(s.split())
    return s if len(s) <= 60 else s[:57] + "..."


def bash_deny(cmd):
    for m in REDIR_RE.finditer(cmd):
        t = m.group(1)
        if not t:
            if cmd[m.end():m.end() + 1] == "(":
                return "process substitution", m.group(0) + "("
            continue
        if t.startswith("&"):
            if re.fullmatch(r"&(?:\d+|-)", t):
                continue
            t = t[1:]
        t = t.strip("\"'")
        if t in DEVS:
            continue
        if EXT_RE.search(t):
            return "redirect to source file", m.group(0)
        if NONLIT_RE.search(t):
            return "redirect to unresolved path", m.group(0)
    for rx, name in INPLACE:
        m = rx.search(cmd)
        if m:
            return name, m.group(0)
    for m in TEE_RE.finditer(cmd):
        if any(bad_target(a) for a in m.group(1).split()):
            return "tee to source file", m.group(0)
    for m in COPY_RE.finditer(cmd):
        args = [a for a in m.group(2).split() if not a.startswith("-")]
        if len(args) < 2:
            continue
        dest, srcs = args[-1], args[:-1]
        if NONLIT_RE.search(dest) or (
                EXT_RE.search(dest) and not all(same_ext(s, dest) for s in srcs)):
            return "copy into source file", m.group(0)
    for m in FETCH_RE.finditer(cmd):
        if EXT_RE.search(m.group(2)):
            return "download to source file", m.group(0)
    for m in OUT_RE.finditer(cmd):
        if bad_target(m.group(1)):
            return "output flag to source file", m.group(0)
    for m in INTERP_RE.finditer(cmd):
        name, args = m.group(1), m.group(2).split()
        seg = re.split(r"[|;&\n]", cmd[m.start(1):], maxsplit=1)[0]
        piped = "|" in cmd[m.start():m.start(1)]
        stdin = piped or ("<" in seg and "<<" not in seg)
        flagged = any(INLINE_FLAG.match(a) for a in args)
        if stdin and not name.endswith("awk"):
            return f"{name} runs code from stdin", snip(seg)
        if not (name.endswith("awk") or flagged or "<<" in seg):
            continue
        w = WRITE_RE.search(cmd)
        if w:
            return f"{name} inline code writes", w.group(0)
        if not NO_EXT_RULE.match(name):
            e = EXT_RE.search(cmd)
            if e:
                return f"{name} inline code names source file", cmd[max(0, e.start() - 20):e.end()]
    return None


TOKEN_RE = re.compile(r"""[^\s"'`;|&<>()=,]+""")


def named_paths(cmd, cwd):
    out = set()
    for tok in TOKEN_RE.findall(cmd):
        if not EXT_RE.search(tok) or "$" in tok:
            continue
        p = os.path.normpath(os.path.join(cwd, os.path.expanduser(re.sub(r":\d+.*$", "", tok))))
        if any(c in p for c in "*?["):
            out.update(x for x in glob.glob(p)[:500] if lang_for(x))
        elif lang_for(p):
            out.add(p)
        if len(out) > 500:
            break
    return out


def edit_text(tool, ti, src):
    if tool == "Write":
        return ti.get("content") or "", None
    if tool == "Edit":
        old, new = ti.get("old_string") or "", ti.get("new_string") or ""
        if src is not None and old and old in src:
            return apply_edit(src, old, new, bool(ti.get("replace_all"))), None
        return new, "new_string"
    text = src or ""
    for e in ti.get("edits") or []:
        old = e.get("old_string") or ""
        if old:
            text = apply_edit(text, old, e.get("new_string") or "", bool(e.get("replace_all")))
    return text, None


def on_pre_edit(state, tool, ti, cwd):
    path = ti.get("file_path") or ""
    lang = lang_for(path)
    if not path or not lang:
        return
    path = os.path.normpath(os.path.join(cwd, os.path.expanduser(path)))
    src = read(path)
    record(state, path, lang)
    if state:
        state.touch([path])
    text, lbl = edit_text(tool, ti, src)
    pre = viol_lines(src, lang) if src is not None else set()
    viol = new_viol(text, lang, pre)
    if viol:
        deny(f"Comment too long. {LIMITS}\n" + "\n".join(fmt(lbl or label(path), viol)))


def inherit_copies(state, cmd, cwd):
    for m in COPY_RE.finditer(cmd):
        args = [a for a in m.group(2).split() if not a.startswith("-")]
        if len(args) < 2 or not lang_for(args[-1]) or NONLIT_RE.search(m.group(2)):
            continue
        dest = os.path.normpath(os.path.join(cwd, os.path.expanduser(args[-1])))
        if os.path.exists(dest):
            continue
        lines = set()
        for s in args[:-1]:
            s = os.path.normpath(os.path.join(cwd, os.path.expanduser(s)))
            lines |= baseline(state, s, lang_for(dest))
        state.set_baseline(dest, lines)


def on_pre_bash(state, ti, cwd, tool_use_id):
    cmd = ti.get("command") or ""
    if state:
        state.stamp(tool_use_id)
        inherit_copies(state, cmd, cwd)
        for p in named_paths(cmd, cwd):
            record(state, p, lang_for(p))
    hit = bash_deny(cmd)
    if hit:
        deny(f"Bash write to source denied ({hit[0]}: `{snip(hit[1])}`). Edit source files with"
             f" the Edit/Write tools only; read with Read/Grep. Comment rule: {LIMITS}")


def on_post_bash(state, ti, cwd, tool_use_id):
    if state is None:
        return
    t0 = state.stamped(tool_use_id)
    deadline = time.monotonic() + 20
    files = {os.path.realpath(p) for p in named_paths(ti.get("command") or "", cwd)
             if os.path.isfile(p)}
    files.update(os.path.realpath(p) for p in walk(cwd, t0 - 1, deadline))
    files = sorted(files)
    state.touch(files)
    out = check_files(state, files, deadline)
    if out:
        block(f"That command introduced over-long comments. {LIMITS} Fix now:\n" + "\n".join(out))


def on_stop(state):
    if state is None:
        return
    deadline = time.monotonic() + 50
    files = [p for p in state.touched() if os.path.isfile(p)]
    out = check_files(state, files, deadline)
    if not out:
        return
    fp = hashlib.sha1("\n".join(out).encode()).hexdigest()
    if state.stop_repeat(fp) > STOP_REPEATS:
        return
    block(f"Cannot stop: over-long comments introduced this session. {LIMITS} Fix:\n"
          + "\n".join(out))


def spawn_snapshot(state, cwd):
    if state is None or state.read("snapshot") is not None:
        return
    state.write("snapshot", "started")
    try:
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "--snapshot", state.dir, cwd],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
    except OSError:
        pass


def snapshot(state_dir, root):
    try:
        os.nice(10)
    except OSError:
        pass
    state = State(state_dir)
    deadline = time.monotonic() + 120
    for p in walk(root, 0, deadline)[:SNAPSHOT_CAP]:
        if time.monotonic() > deadline:
            break
        if state.baseline(p) is not None:
            continue
        src = read(p)
        if src is not None:
            state.set_baseline(p, viol_lines(src, lang_for(p)))
    state.write("snapshot", "done")


def prune_state(root):
    try:
        names = os.listdir(root)
    except OSError:
        return
    cutoff = time.time() - STATE_TTL
    for name in names:
        d = os.path.join(root, name)
        try:
            if os.path.getmtime(d) < cutoff:
                shutil.rmtree(d, ignore_errors=True)
        except OSError:
            pass


def on_session_start(inp, state, cwd):
    if state is None:
        return
    if inp.get("source") in ("resume", "clear") and not state.fresh:
        shutil.rmtree(state.dir, ignore_errors=True)
        state = State(state.dir)
    prune_state(State.root())
    spawn_snapshot(state, cwd)


def main():
    if len(sys.argv) > 3 and sys.argv[1] == "--snapshot":
        snapshot(sys.argv[2], sys.argv[3])
        return
    inp = json.load(sys.stdin)
    ev = inp.get("hook_event_name")
    tool = inp.get("tool_name")
    ti = inp.get("tool_input") or {}
    cwd = inp.get("cwd") or os.getcwd()
    try:
        state = State.for_session(inp.get("session_id"))
    except OSError:
        state = None
    if ev == "SessionStart":
        on_session_start(inp, state, cwd)
        return
    if state and state.fresh:
        spawn_snapshot(state, cwd)
    if ev == "PreToolUse" and tool == "Bash":
        on_pre_bash(state, ti, cwd, inp.get("tool_use_id"))
    elif ev == "PreToolUse" and tool in ("Write", "Edit", "MultiEdit"):
        on_pre_edit(state, tool, ti, cwd)
    elif ev == "PostToolUse" and tool == "Bash":
        on_post_bash(state, ti, cwd, inp.get("tool_use_id"))
    elif ev in ("Stop", "SubagentStop"):
        on_stop(state)


if __name__ == "__main__":
    main()
