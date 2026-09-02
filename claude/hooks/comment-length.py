#!/usr/bin/env python3
import json
import os
import sys

MAX_COLS = 80
MAX_COMMENT_LINES = 1
MAX_DOCSTRING_LINES = 3

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


def main():
    inp = json.load(sys.stdin)
    ti = inp.get("tool_input") or {}
    path = ti.get("file_path") or ""
    lang = LANGS.get(os.path.splitext(path)[1][1:].lower())
    if not lang:
        return
    tool = inp.get("tool_name")
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            src = f.read()
    except OSError:
        src = None
    label = os.path.relpath(path) if not os.path.relpath(path).startswith("..") else path
    if tool == "Write":
        text = ti.get("content") or ""
    elif tool == "Edit":
        old, new = ti.get("old_string") or "", ti.get("new_string") or ""
        if src is not None and old and old in src:
            text = apply_edit(src, old, new, bool(ti.get("replace_all")))
        else:
            text, label = new, "new_string"
    else:
        return
    pre = set()
    if src is not None:
        old_viol, old_lines = check(src, lang)
        pre = {old_lines[l - 1] for s, e, _ in old_viol for l in range(s, e + 1)}
    viol, lines = check(text, lang)
    viol = [v for v in viol
            if not all(lines[l - 1] in pre for l in range(v[0], v[1] + 1))]
    if not viol:
        return
    where = [f"{label}:{s}" + (f"-{e}" if e != s else "") + f" {msg}"
             for s, e, msg in viol]
    reason = (f"Comment too long. Limit {MAX_COMMENT_LINES} line, {MAX_COLS} chars;"
              f" docstring {MAX_DOCSTRING_LINES} lines.\n" + "\n".join(where))
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason}}))


if __name__ == "__main__":
    main()
