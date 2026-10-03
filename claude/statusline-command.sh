#!/usr/bin/env python3
"""Claude Code statusline: `label:value` segments, ending in a context-usage bar."""
from __future__ import annotations
import json, os, sys, subprocess, re, shutil, unicodedata
from pathlib import Path

RESET  = "\033[0m"
BOLD   = "\033[1m"
WHITE  = "\033[38;5;231m"
GREEN  = "\033[38;5;46m"
LIME   = "\033[38;5;120m"
YELLOW = "\033[38;5;184m"
MID    = "\033[38;5;34m"
DARK   = "\033[38;5;28m"
RED    = "\033[38;5;196m"

LABEL = MID
VALUE = LIME

CONTEXT_WINDOW = 1_000_000
MIN_BAR_WIDTH = 10
# Claude Code's TUI reserves a few right-edge cells; without this margin the line becomes "…".
SAFETY = 4

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def visible_len(s: str) -> int:
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
               for ch in ANSI_RE.sub("", s))


def _ioctl_cols(target) -> int | None:
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


def _ancestor_ttys():
    """Yield ttys open on fds 0-2 of us or any ancestor; Claude Code pipes our stdio."""
    seen = set()
    pid = os.getpid()
    for _ in range(20):
        for fd in (0, 1, 2):
            try:
                tgt = os.readlink(f"/proc/{pid}/fd/{fd}")
            except Exception:
                continue
            if tgt not in seen and ("/dev/pts/" in tgt or tgt.startswith("/dev/tty")):
                seen.add(tgt)
                yield tgt
        try:
            with open(f"/proc/{pid}/stat", "rb") as f:
                line = f.read().decode("latin-1")
            ppid = int(line[line.rfind(")") + 2:].split()[1])
        except Exception:
            break
        if ppid <= 1 or ppid == pid:
            break
        pid = ppid


def term_width(data: dict) -> int:
    w = data.get("terminal_width") or data.get("term_width")
    if isinstance(w, int) and w > 0:
        return w
    for target in ("/dev/tty", 0, 1, 2, *_ancestor_ttys()):
        cols = _ioctl_cols(target)
        if cols:
            return cols
    env = os.environ.get("COLUMNS")
    if env and env.isdigit():
        return int(env)
    return shutil.get_terminal_size((120, 24)).columns


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


def detect_provider() -> str:
    base = os.environ.get("ANTHROPIC_BASE_URL", "").strip()
    if base:
        from urllib.parse import urlparse
        try:
            host = urlparse(base).hostname or base
        except Exception:
            host = base
        if host and "anthropic.com" not in host.lower():
            return host
    if os.environ.get("CLAUDE_CODE_USE_BEDROCK"):
        return "bedrock"
    if os.environ.get("CLAUDE_CODE_USE_VERTEX"):
        return "vertex"
    if os.environ.get("ANTHROPIC_API_KEY"):
        return "api"
    return "sub"


def glucose() -> str | None:
    """`t1dmkd prompt` without its readline \\x01 \\x02 fences, or None."""
    try:
        r = subprocess.run(["t1dmkd", "prompt"],
                           capture_output=True, text=True, timeout=0.5)
    except Exception:
        return None
    if r.returncode != 0 or not r.stdout:
        return None
    return r.stdout.translate({1: None, 2: None})


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


EFFORT_COLORS = {
    "low":    DARK,
    "medium": MID,
    "high":   LIME,
    "xhigh":  GREEN,
    "max":    WHITE,
}


def bar(pct: float, color: str, width: int) -> str:
    filled = int(round(max(0.0, min(100.0, pct)) / 100.0 * width))
    return f"{color}{'▰' * filled}{DARK}{'▱' * (width - filled)}{RESET}"


def seg(label: str, value: str, color: str = VALUE) -> str:
    return f"{LABEL}{label}:{RESET}{color}{value}{RESET}"


def main() -> None:
    data = read_input()
    cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd") or os.getcwd()
    model_name = (data.get("model") or {}).get("display_name") or ""
    transcript = data.get("transcript_path") or ""

    user = os.environ.get("USER") or os.environ.get("LOGNAME") or "user"
    branch = git_branch(cwd)
    distro = detect_distro()

    parts = [seg("uid", user)]
    if distro:
        parts.append(seg("os", distro))
    parts.append(seg("cwd", Path(cwd).name or cwd, f"{BOLD}{WHITE}"))
    if branch:
        parts.append(seg("ref", branch))
    if model_name:
        parts.append(seg("llm", model_name))
    effort = (data.get("effort") or {}).get("level")
    if effort:
        parts.append(seg("nice", effort, EFFORT_COLORS.get(effort, VALUE)))
    bg = glucose()
    if bg:
        parts.append(f"{LABEL}bg:{RESET}{bg}{RESET}")
    else:
        parts.append(seg("link", detect_provider()))
    parts.append(seg("mem", str(count_memories(cwd))))
    parts.append(seg("lib", str(count_skills(cwd))))

    sep = f"{DARK} | {RESET}"
    used = context_tokens(transcript)
    if used is not None:
        pct = used / CONTEXT_WINDOW * 100
        col = ctx_color(pct)
        head = f"{LABEL}ctx:{RESET}"
        tail = f" {col}{fmt_tokens(used)}/{fmt_tokens(CONTEXT_WINDOW)} {pct:.0f}%{RESET}"
        taken = visible_len(sep.join(parts + [head + tail]))
        width = max(MIN_BAR_WIDTH, term_width(data) - taken - SAFETY)
        parts.append(head + bar(pct, col, width) + tail)

    sys.stdout.write(sep.join(parts))


if __name__ == "__main__":
    main()
