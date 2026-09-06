#!/usr/bin/env python3
import json
import re
import shlex
import sys

WRAPPERS = {"doas", "env", "command", "builtin", "exec", "nohup", "time",
            "nice", "ionice", "stdbuf", "timeout", "xargs"}
OPT_WITH_ARG = {
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "-n", "-p"},
    "env": {"-u", "-C", "-S", "--unset", "--chdir"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "stdbuf": {"-i", "-o", "-e"},
}
POSITIONAL = {"timeout": 1}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish"}
SPLIT = re.compile(r"\s*(?:&&|\|\||;|\||\n)\s*")
ROOT_DIRS = {"bin", "boot", "dev", "etc", "home", "lib", "lib64", "opt",
             "proc", "root", "sbin", "srv", "sys", "usr", "var"}

WHOLE = [
    ("fork bomb", r":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"),
    ("pipe download to shell",
     r"\b(?:curl|wget)\b[^|]*\|\s*(?:sudo\s+)?(?:env\s+\S+\s+)?(?:ba|z|da|k|fi)?sh\b"),
    ("write to block device", r">\s*/dev/(?:sd|nvme|hd|vd|xvd|mmcblk|disk|mapper/)"),
    ("read credentials",
     r"\.claude/\.credentials\.json|\.ssh/id_\w+\b(?!\.pub)|\.gnupg/"),
    ("clear shell history", r"\.bash_history|\bhistory\s+-c\b"),
]

SEGMENT = [
    ("sudo", r"^(?:sudo|su|doas|pkexec)\b"),
    ("disk format tool",
     r"^(?:shred|wipefs|mkfs(?:\.\w+)?|fdisk|sfdisk|cfdisk|gdisk|sgdisk|parted)\b"),
    ("dd to device", r"^dd\b.*\bof=/dev/(?!null\b|stdout\b|stderr\b|tty|fd/)"),
    ("power state", r"^(?:shutdown|reboot|poweroff|halt|telinit)\b"),
    ("power state", r"^init\s+[06]\b"),
    ("power state",
     r"^systemctl\s+(?:poweroff|reboot|halt|kexec|suspend|hibernate)\b"),
    ("kill all processes", r"^kill\s+(?:-\S+\s+)*-1\b"),
    ("kill all processes",
     r"^killall\s+(?:-\S+\s+)*-(?:9|KILL|s\s+(?:SIG)?KILL)\b"),
    ("remove crontab", r"^crontab\s+(?:-\S+\s+)*-r\b"),
    ("flush firewall", r"^iptables\s+(?:-\S+\s+)*-F\b"),
    ("flush firewall", r"^nft\s+flush\s+ruleset\b"),
    ("flush firewall", r"^ufw\s+disable\b"),
    ("account change",
     r"^(?:passwd|chpasswd|userdel|usermod|useradd|groupdel|visudo)\b"),
    ("recursive chmod on root",
     r"^chmod\b(?=.*\s-[a-zA-Z]*R\b).*\s(?:/|~|\$HOME|\.)/?(?:\s|$)"),
    ("recursive chown", r"^chown\b(?=.*(?:\s-[a-zA-Z]*R\b|\s--recursive\b))"),
    ("chattr", r"^chattr\b"),
    ("truncate root", r"^truncate\b.*\s-s\s*0\b.*\s/(?:\s|$)"),
    ("git force push",
     r"^git\s+push\b(?=.*(?:\s--force(?:\s|$)|\s-[a-zA-Z]*f[a-zA-Z]*(?:\s|$)|\s\+\S))"),
    ("git reset --hard", r"^git\s+reset\b.*\s--hard\b"),
    ("git clean -f", r"^git\s+clean\b(?=.*(?:\s-[a-zA-Z]*f|\s--force\b))"),
    ("git discard worktree", r"^git\s+checkout\s+(?:.*\s)?--\s+\.(?:\s|$)"),
    ("git discard worktree",
     r"^git\s+restore\b(?!.*--staged(?!.*(?:--worktree|\s-W\b))).*\s\.(?:\s|$)"),
    ("git branch -D", r"^git\s+branch\s+(?:.*\s)?-D\b"),
    ("git stash drop", r"^git\s+stash\s+(?:drop|clear)\b"),
    ("git reflog expire", r"^git\s+reflog\s+expire\b"),
    ("git gc --prune=now", r"^git\s+gc\b.*--prune=now"),
    ("git filter-branch", r"^git\s+filter-branch\b"),
    ("git update-ref -d", r"^git\s+update-ref\s+(?:.*\s)?-d\b"),
]
WHOLE_RX = [(n, re.compile(p, re.I)) for n, p in WHOLE]
SEGMENT_RX = [(n, re.compile(p)) for n, p in SEGMENT]


def tokens(seg):
    try:
        return shlex.split(seg)
    except ValueError:
        return [t.strip("\"'") for t in seg.split()]


def strip_wrappers(argv):
    while argv:
        head = argv[0]
        if head not in WRAPPERS and not re.match(r"^\w+=", head):
            break
        argv = argv[1:]
        while argv and argv[0].startswith("-"):
            opt = argv.pop(0)
            if opt in OPT_WITH_ARG.get(head, ()) and argv:
                argv.pop(0)
        argv = argv[POSITIONAL.get(head, 0):]
    return argv


def dangerous_rm_target(t):
    t = t.rstrip("*")
    if t in ("", "/", "~", "$HOME", "${HOME}", ".", "..", "./", "../"):
        return True
    t = t.rstrip("/")
    if t in ("", "~", "$HOME", "${HOME}", ".", ".."):
        return True
    if t.startswith("/"):
        parts = t[1:].split("/")
        if len(parts) == 1 and parts[0] in ROOT_DIRS:
            return True
        if len(parts) == 2 and parts[0] == "home":
            return True
    return False


def rm_check(argv):
    flags = [a for a in argv[1:] if a.startswith("-")]
    args = [a for a in argv[1:] if not a.startswith("-")]
    if "--no-preserve-root" in flags:
        return "rm --no-preserve-root"
    recursive = any(f == "--recursive" or
                    (not f.startswith("--") and re.search(r"[rR]", f))
                    for f in flags)
    if recursive:
        for a in args:
            if dangerous_rm_target(a):
                return f"recursive rm on {a}"
    return None


def check_segment(seg):
    for name, rx in SEGMENT_RX:
        if rx.search(seg):
            return name
    argv = strip_wrappers(tokens(seg))
    if not argv:
        return None
    if argv[0] != seg.split()[0]:
        joined = shlex.join(argv)
        for name, rx in SEGMENT_RX:
            if rx.search(joined):
                return name
    if argv[0] == "rm":
        return rm_check(argv)
    if argv[0] in SHELLS and "-c" in argv:
        i = argv.index("-c")
        if i + 1 < len(argv):
            return check_command(argv[i + 1])
    if argv[0] == "eval":
        return check_command(" ".join(argv[1:]))
    return None


def check_command(cmd):
    for name, rx in WHOLE_RX:
        if rx.search(cmd):
            return name
    for seg in SPLIT.split(cmd):
        seg = seg.strip()
        if seg:
            hit = check_segment(seg)
            if hit:
                return hit
    return None


def main():
    try:
        inp = json.load(sys.stdin)
    except ValueError:
        return
    if inp.get("tool_name") != "Bash":
        return
    cmd = (inp.get("tool_input") or {}).get("command") or ""
    hit = check_command(cmd)
    if hit:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": f"deny-commands hook: {hit}"}}))


if __name__ == "__main__":
    main()
