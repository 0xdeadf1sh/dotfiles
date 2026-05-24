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

## Environment

This config follows me across machines — always Linux, but the distro
varies (Arch on my primary box, Ubuntu or similar on others). Don't
assume Arch-specific paths or `pacman`; check `/etc/os-release` (or the
statusline) when distro matters.

- Shell: bash; terminal: kitty; multiplexer: tmux; editor: neovim
- Dotfiles repo: `~/Desktop/dotfiles` (config for bash, kitty, tmux,
  neovim, gdb, git, claude)
