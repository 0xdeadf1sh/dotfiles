#!/usr/bin/env python3
"""Rich animated statusline for Claude Code.

Reads the statusline JSON event on stdin and emits a single ANSI-decorated line.
Pulls live context usage from the transcript JSONL, then fills the remaining
terminal width with a flowing color-wave keyed off wall-clock time. The
animation advances each time Claude Code redraws the statusline (typing,
tool calls, response chunks); there is no background tick.
"""
from __future__ import annotations
import json, os, sys, subprocess, math, time, re, shutil, unicodedata
from pathlib import Path

# --- ANSI ---------------------------------------------------------------
RESET  = "\033[0m"
BOLD   = "\033[1m"
DIM    = "\033[2m"
GREEN  = "\033[38;5;114m"
CYAN   = "\033[38;5;110m"
YELLOW = "\033[38;5;180m"
PURPLE = "\033[38;5;176m"
GRAY   = "\033[38;5;245m"
RED    = "\033[38;5;167m"

# --- Nerd Font icons (replace with plain text if you don't have a Nerd Font)
USER_ICON   = "🐟"
DISTRO_ICON = "🐧"
DIR_ICON    = "📁"
GIT_ICON    = "🌿"
MODEL_ICON  = "✨"
EFFORT_ICON = "⚡"
SUB_ICON    = "💎"
API_ICON    = "🔑"
CLOUD_ICON  = "☁️ "
PLUG_ICON   = "🔌"
MEM_ICON    = "🧠"
SKILL_ICON  = "🧰"
CTX_ICON    = "📊"

CONTEXT_WINDOWS = {
    "claude-opus-4-8":   1_000_000,
    "claude-opus-4-7":   1_000_000,
    "claude-opus-4-6":   1_000_000,
    "claude-sonnet-4-6": 1_000_000,
    "claude-sonnet-4-5":   200_000,
    "claude-haiku-4-5":    200_000,
}
DEFAULT_WINDOW = 200_000


def context_window(model_id: str, used: int | None = None) -> int:
    """Resolve the context window for a model id. A trailing `[1m]` (e.g.
    `claude-opus-4-8[1m]`) is the 1M-beta marker and overrides everything;
    otherwise strip any `[...]` suffix and look up the base id. As a final
    safety net, if observed usage already exceeds the looked-up window the
    window must really be the 1M tier — so we never render a >100% bar."""
    if model_id.endswith("[1m]"):
        return 1_000_000
    base = model_id.split("[", 1)[0]
    win = CONTEXT_WINDOWS.get(base, DEFAULT_WINDOW)
    if used is not None and used > win:
        return 1_000_000
    return win

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def visible_len(s: str) -> int:
    """Display-cell width of `s`, ignoring ANSI escapes and counting
    East-Asian wide / fullwidth glyphs (incl. most emoji) as 2 cells."""
    plain = ANSI_RE.sub("", s)
    n = 0
    for ch in plain:
        if unicodedata.east_asian_width(ch) in ("W", "F"):
            n += 2
        else:
            n += 1
    return n


def read_input() -> dict:
    try:
        return json.load(sys.stdin)
    except Exception:
        return {}


def git_branch(cwd: str) -> str | None:
    if not cwd or not os.path.isdir(cwd):
        return None
    try:
        for args in (["symbolic-ref", "--short", "HEAD"],
                     ["rev-parse", "--short", "HEAD"]):
            r = subprocess.run(["git", "-C", cwd, *args],
                               capture_output=True, text=True, timeout=0.5)
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.strip()
    except Exception:
        pass
    return None


def context_tokens(transcript_path: str) -> int | None:
    if not transcript_path or not os.path.isfile(transcript_path):
        return None
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 65536))
            tail = f.read().decode("utf-8", errors="replace")
        for line in reversed(tail.splitlines()):
            if '"usage"' not in line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            usage = (rec.get("message") or {}).get("usage") or rec.get("usage")
            if not isinstance(usage, dict):
                continue
            total = (usage.get("input_tokens", 0)
                     + usage.get("cache_read_input_tokens", 0)
                     + usage.get("cache_creation_input_tokens", 0))
            if total > 0:
                return total
    except Exception:
        return None
    return None


def detect_distro() -> str | None:
    """Return NAME from /etc/os-release, or None."""
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("NAME="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    except Exception:
        pass
    return None


def detect_provider() -> tuple[str, str, str]:
    """Return (icon, label, ansi_color) for how Claude Code is connected."""
    base = os.environ.get("ANTHROPIC_BASE_URL", "").strip()
    if base:
        from urllib.parse import urlparse
        try:
            host = urlparse(base).hostname or base
        except Exception:
            host = base
        if host and "anthropic.com" not in host.lower():
            return PLUG_ICON, host, "\x1b[1;38;5;215m"
    if os.environ.get("CLAUDE_CODE_USE_BEDROCK"):
        return CLOUD_ICON, "Bedrock", "\x1b[1;38;5;215m"
    if os.environ.get("CLAUDE_CODE_USE_VERTEX"):
        return CLOUD_ICON, "Vertex", "\x1b[1;38;5;215m"
    if os.environ.get("ANTHROPIC_API_KEY"):
        return API_ICON, "API", "\x1b[1;38;5;110m"
    if (Path.home() / ".claude" / ".credentials.json").is_file():
        return SUB_ICON, "Subscription", "\x1b[1;38;5;213m"
    return SUB_ICON, "Subscription", "\x1b[1;38;5;213m"


def count_memories(cwd: str) -> int:
    """Count `.md` memory files in the project's memory dir (excluding the index)."""
    if not cwd:
        return 0
    encoded = cwd.replace("/", "-")
    if not encoded.startswith("-"):
        encoded = "-" + encoded
    memdir = Path.home() / ".claude" / "projects" / encoded / "memory"
    if not memdir.is_dir():
        return 0
    return sum(
        1 for p in memdir.iterdir()
        if p.is_file() and p.suffix == ".md" and p.name != "MEMORY.md"
    )


def count_skills(cwd: str) -> int:
    """Count custom skills (user, project, plugin). Built-in skills are
    embedded in the Claude Code binary and not counted here."""
    roots = (
        Path.home() / ".claude" / "skills",
        Path(cwd) / ".claude" / "skills" if cwd else None,
        Path.home() / ".claude" / "plugins" / "cache",
    )
    seen: set[str] = set()
    for root in roots:
        if root is None or not root.is_dir():
            continue
        for skill_md in root.rglob("SKILL.md"):
            seen.add(str(skill_md.parent.resolve()))
    return len(seen)


def fmt_tokens(n: int) -> str:
    if n >= 1_000_000: return f"{n/1_000_000:.1f}M"
    if n >= 1_000:     return f"{n/1_000:.1f}k"
    return str(n)


def ctx_color(pct: float) -> str:
    if pct >= 80: return RED
    if pct >= 50: return YELLOW
    return GREEN


# Effort scales green → red with intensity; "max" gets the bold-red treatment.
EFFORT_COLORS = {
    "low":    GREEN,
    "medium": CYAN,
    "high":   YELLOW,
    "xhigh":  PURPLE,
    "max":    "\x1b[1;38;5;203m",
}


def effort_color(level: str) -> str:
    return EFFORT_COLORS.get(level, GRAY)


# --- Pacman animation ---------------------------------------------------
# Stateless: every visible thing is a pure function of (width, time.time()).
# Pacman triangle-waves across [0, width-1]; the last time he visited each
# cell determines whether the dot/fruit is currently eaten.

STATE_FILE = Path.home() / ".claude" / ".statusline-pacman.state"


def next_frame() -> int:
    """Persistent monotonic counter — one increment per statusline redraw.

    The statusline hook does not fire on a timer; it fires on discrete events.
    Driving the animation off wall-clock time means most "frames" are skipped.
    Driving it off this counter means each redraw advances pacman one step.
    """
    try:
        n = int(STATE_FILE.read_text().strip())
    except Exception:
        n = 0
    n = (n + 1) & 0x7FFFFFFF
    try:
        STATE_FILE.write_text(str(n))
    except Exception:
        pass
    return n

PAC_YELLOW  = "\x1b[1;38;5;226m"  # bright pacman
TRAIL_YEL   = "\x1b[38;5;221m"    # consumed-road yellow
DOT_DIM     = "\x1b[2;38;5;245m"  # available-road grey
CHERRY_RED  = "\x1b[1;38;5;203m"  # uneaten heart
CHERRY_DIM  = "\x1b[2;38;5;203m"  # eaten heart (single-cell fallback)


def _is_heart(i: int) -> bool:
    """Whether road cell `i` carries a heart rather than a plain dot."""
    return (i + 7) % 23 == 0


def pacman_fill(width: int, pct: float, frame: int) -> str:
    """Render a road of `width` cells where pacman's position reflects the
    context-usage percentage. Behind = consumed; ahead = available. The
    `frame` counter drives the chomp animation only — position is purely
    a function of `pct`."""
    if width <= 1:
        return ""
    span = width - 1
    pct = max(0.0, min(100.0, pct))
    pac_x = int(round(pct / 100.0 * span))

    # Chomp: alternate open/closed each redraw so he still looks alive
    # even when pct doesn't change.
    chomp_open = (frame % 2 == 0)
    pac_glyph = "ᗧ" if chomp_open else "●"

    # `💔` is a 2-cell emoji while every other road glyph is 1 cell, so a
    # broken heart consumes the column to its right to keep the road's total
    # display width exactly `width` — otherwise it eats into the SAFETY margin
    # and the TUI truncates the line.
    out = []
    i = 0
    while i < width:
        if i == pac_x:
            out.append(f"{PAC_YELLOW}{pac_glyph}{RESET}")
        elif i < pac_x:  # behind = consumed
            if _is_heart(i) and i + 1 < width and i + 1 != pac_x:
                out.append("💔")
                i += 1  # the emoji visually covers this next column too
            elif _is_heart(i):
                out.append(f"{CHERRY_DIM}♥{RESET}")  # no room to break it
            else:
                out.append(f"{TRAIL_YEL}•{RESET}")
        else:  # ahead = available
            if _is_heart(i):
                out.append(f"{CHERRY_RED}♥{RESET}")
            else:
                out.append(f"{DOT_DIM}·{RESET}")
        i += 1
    return "".join(out)


def _ioctl_cols(target) -> int | None:
    """Return columns from a TIOCGWINSZ ioctl on an open fd or path."""
    try:
        import fcntl, struct, termios
        if isinstance(target, str):
            with open(target, "rb") as t:
                raw = fcntl.ioctl(t, termios.TIOCGWINSZ, b"\0" * 8)
        else:
            raw = fcntl.ioctl(target, termios.TIOCGWINSZ, b"\0" * 8)
        _, cols, _, _ = struct.unpack("hhhh", raw)
        return cols if cols > 0 else None
    except Exception:
        return None


def _walk_proc_ttys():
    """Yield pts/tty device paths held open by us or any ancestor."""
    seen = set()
    pid = os.getpid()
    for _ in range(20):  # depth limit
        for fd in (0, 1, 2):
            try:
                tgt = os.readlink(f"/proc/{pid}/fd/{fd}")
            except Exception:
                continue
            if tgt in seen:
                continue
            seen.add(tgt)
            if "/dev/pts/" in tgt or tgt.startswith("/dev/tty"):
                yield tgt
        try:
            with open(f"/proc/{pid}/stat", "rb") as f:
                # stat format: pid (comm) state ppid ...
                # comm can contain spaces/parens — find last ')'.
                line = f.read().decode("latin-1")
                rparen = line.rfind(")")
                fields = line[rparen + 2:].split()
                ppid = int(fields[1])  # field index after state
        except Exception:
            break
        if ppid <= 1 or ppid == pid:
            break
        pid = ppid


def term_width(data: dict) -> tuple[int, str]:
    """Return (cols, source) — source identifies which fallback resolved."""
    # 1. Claude Code's JSON payload (if it ever exposes width).
    w = data.get("terminal_width") or data.get("term_width")
    if isinstance(w, int) and w > 0:
        return w, "json"
    # 2. ioctl on /dev/tty.
    cols = _ioctl_cols("/dev/tty")
    if cols:
        return cols, "/dev/tty"
    # 3. ioctl on our own std fds.
    for fd in (0, 1, 2):
        cols = _ioctl_cols(fd)
        if cols:
            return cols, f"fd:{fd}"
    # 4. Walk the parent chain — find any ancestor that has a /dev/pts/* open.
    for path in _walk_proc_ttys():
        cols = _ioctl_cols(path)
        if cols:
            return cols, f"proc:{path}"
    # 5. $COLUMNS env.
    env = os.environ.get("COLUMNS")
    if env and env.isdigit():
        return int(env), "$COLUMNS"
    # 6. Last resort.
    try:
        return shutil.get_terminal_size((120, 24)).columns, "shutil"
    except Exception:
        return 120, "default"


def main() -> None:
    data = read_input()
    cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd") or os.getcwd()
    model = data.get("model") or {}
    model_name = model.get("display_name") or ""
    model_id = model.get("id") or ""
    transcript = data.get("transcript_path") or ""

    user = os.environ.get("USER") or os.environ.get("LOGNAME") or "user"
    dirname = Path(cwd).name or cwd
    branch = git_branch(cwd)
    distro = detect_distro()
    prov_icon, prov_label, prov_color = detect_provider()

    sep = f"{DIM}{GRAY} · {RESET}"
    parts = [f"{BOLD}{GREEN}{USER_ICON}  {user}{RESET}"]
    if distro:
        parts.append(f"{BOLD}{CYAN}{DISTRO_ICON}  {distro}{RESET}")
    parts.append(f"{BOLD}{CYAN}{DIR_ICON}  {dirname}{RESET}")
    if branch:
        parts.append(f"{BOLD}{YELLOW}{GIT_ICON}  {branch}{RESET}")
    if model_name:
        parts.append(f"{BOLD}{PURPLE}{MODEL_ICON}  {model_name}{RESET}")
    effort = (data.get("effort") or {}).get("level")
    if effort:
        parts.append(f"{BOLD}{effort_color(effort)}{EFFORT_ICON}  {effort}{RESET}")
    parts.append(f"{BOLD}{prov_color}{prov_icon}  {prov_label}{RESET}")

    mem_n = count_memories(cwd)
    skill_n = count_skills(cwd)
    parts.append(f"{BOLD}{PURPLE}{MEM_ICON}  {mem_n}{RESET}")
    parts.append(f"{BOLD}{YELLOW}{SKILL_ICON}  {skill_n}{RESET}")

    used = context_tokens(transcript)
    window = context_window(model_id, used)
    pct = (used / window * 100) if used is not None else 0.0
    if used is not None:
        col = ctx_color(pct)
        parts.append(
            f"{BOLD}{col}{CTX_ICON}  {fmt_tokens(used)}/{fmt_tokens(window)} "
            f"({pct:.0f}%){RESET}"
        )

    content = sep.join(parts)
    width, _src = term_width(data)
    # Claude Code's TUI reserves a few right-edge cells for its own chrome /
    # overflow indicator. Without this margin the line is truncated to "…".
    SAFETY = 4
    GAP = 1  # single breathing space between content and road
    fill_w = max(0, width - visible_len(content) - GAP - SAFETY)
    fill = pacman_fill(fill_w, pct, next_frame())
    sys.stdout.write(content + (" " * GAP) + fill)


if __name__ == "__main__":
    main()
