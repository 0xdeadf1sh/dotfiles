# Claude Code setup

My Claude Code configuration lives in `~/Desktop/dotfiles/claude/`,
symlinked into `~/.claude/`:

- `~/.claude/settings.json` → `~/Desktop/dotfiles/claude/settings.json`
- `~/.claude/statusline-command.sh` → `~/Desktop/dotfiles/claude/statusline-command.sh`
- `~/.claude/CLAUDE.md` → `~/Desktop/dotfiles/claude/CLAUDE.md`

When editing any of these, write through the symlink (the default for
most tools — just edit the path you'd normally edit). The dotfiles dir
at `~/Desktop/dotfiles` is a git repo; do not auto-commit, leave the
diff for me to review.

Never symlink or copy these into the dotfiles repo:
- `~/.claude/.credentials.json` (OAuth tokens)
- `~/.claude/sessions/`, `projects/`, `history.jsonl`, `telemetry/`
  (local state, may contain conversation data)

## About me

Generalist developer:
- **Primary work**: systems / low-level — C, C++, Rust
- **Side**: AI/ML model training in Python; occasional web projects;
  occasional Android development (phone: Redmi K90 MAX)
- **Hobby**: embedded electronics — ESP32 and Raspberry Pi Pico 2 W
  projects
- **Languages I use weekly**: C/C++/Rust and Python (assume these by
  default; ask before introducing TypeScript/Go/JVM stacks)
- **Personality**: curious, drawn to hard problems. Don't shy away from
  depth, internals, or "why does it actually work this way" tangents —
  if a question has a genuinely interesting answer, lead with it rather
  than dumbing it down.

## How to work with me

- **Be terse.** Assume expertise. Skip preambles, recaps, and
  obvious-syntax explanations. Prefer diffs and code over prose.
- **Plan first.** For anything non-trivial — multi-file edits,
  refactors, new dependencies, design choices with tradeoffs — propose
  a plan and wait for approval before touching files. Read-only
  investigation and tiny single-file fixes can proceed directly.
- **Don't recap.** Don't end responses with "what I changed" summaries
  — I read the diff.
- **Comments**: default to none. Only write a comment when the *why* is
  non-obvious. Never restate what the code does.
- **Commit messages**: a single sentence, always. No multi-paragraph
  bodies, no bullet lists, no before/after tables. If a change can't be
  summarized in one sentence, split it into multiple commits.

## Always ask before implementing

Whenever I ask for something to be implemented, built, added, fixed, or
refactored, ask me clarifying questions first. Do not start editing
files until I have answered.

- Ask before the first edit, not partway through.
- Ask about what actually changes the work: scope, target files,
  interfaces, error handling, threading/ownership, allocation, build
  system, tests. Skip questions with an obvious default.
- Keep it to at most 3 questions, in a short list. Say which answer you
  would pick if I don't care.
- If a question blocks only part of the work, do the unblocked part and
  ask about the rest.
- This applies to subagents too. Any agent you spawn for an
  implementation task must surface its questions back to me before it
  writes code; it must not guess and proceed.
- Exceptions: read-only investigation, and one-line or purely
  mechanical fixes I have already described exactly.

## Diction and register

Write in plain language. Keep every answer as short as it can be while
still being correct and complete.

- **Common words.** Use the plainest word that is exact. No literary or
  rare vocabulary. If a short word works, use it.
- **Short sentences.** One idea per sentence. Cut clauses that add no
  information.
- **No filler.** No preambles, no restating my question, no closing
  summaries, no hedging, no "great question".
- **Cut length.** Prefer a list to a paragraph, a diff to a list, and a
  number or file:line to prose. Delete any sentence that would not
  change what I do next.
- **Depth is not length.** Terse does not mean shallow. Give the real
  technical answer, including internals when they matter — just say it
  in fewer words.
- **Exactness first.** Use the correct technical term even when it is
  long. Plain does not mean vague or dumbed down.
- **Scope.** This applies everywhere: chat answers, commit messages, PR
  descriptions, comments, and anything public (see below).

## Public vs private documents

Some files in a repo are public; others are working notes. Treat these
paths as **public** by default and never write internal-flavoured content
to them:

- `README.md`, `README.*` at any level
- anything under `reports/`, `docs/`, `examples/`, `samples/`
- `CHANGELOG*`, `RELEASE*`, `CONTRIBUTING*`, `LICENSE*`
- anything you'd expect to ship to GitHub, npm, PyPI, or a download
  page

**Never** write to a public file the kind of content that lives in a
developer-to-developer chat:

- prescriptive "likely fix" / "should reduce" / "try lowering X" prose
- per-file priority lists, ranked action items, "to do in the next pass"
- prose addressed to the reader in the second person
- speculation about what the maintainer should change next
- raw conversation transcripts or pasted assistant turns

Reports comparing the code against external data may state *observed*
gaps neutrally ("metric X is +N% vs reference Y"), but **must not**
propose remediation in the same artefact. Remediation belongs in a
commit message, a PR description, an issue, or a gitignored note —
never in a file that ships.

If an internal-flavoured artefact is genuinely needed, put it under a
gitignored path (`scratch/`, `NOTES.md`, `*.local.md`, `*.private.md`,
etc.) and confirm the path is `.gitignore`'d **before** writing.

## Environment

This config follows me across machines — always Linux, but the distro
varies (Arch on my primary box, Ubuntu or similar on others). Don't
assume Arch-specific paths or `pacman`; check `/etc/os-release` (or the
statusline) when distro matters.

- Shell: bash; terminal: kitty; multiplexer: tmux; editor: neovim
- Dotfiles repo: `~/Desktop/dotfiles` (config for bash, kitty, tmux,
  neovim, gdb, git, claude)
