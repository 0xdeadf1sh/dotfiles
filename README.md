## dotfiles

Configuration for bash, tmux, kitty, neovim, gdb, git and Claude Code on x86_64 and aarch64 Linux.

## layout

| repo | target |
|---|---|
| `desktop.bashrc` | `~/.bashrc` |
| `desktop.gitconfig` | `~/.gitconfig` |
| `desktop.tmux.conf` | `~/.tmux.conf` |
| `desktop.gdbinit` | `~/.gdbinit` |
| `kitty.conf` | `~/.config/kitty/kitty.conf` |
| `nvim/` | `~/.config/nvim` |
| `claude/{CLAUDE.md,settings.json,statusline-command.sh,hooks,skills}` | `~/.claude/` |
| `git-hooks/` | `core.hooksPath` in `desktop.gitconfig` |
| `mouseless/config.yaml` | mouseless app config |
| `kde/{color-schemes,plasma/desktoptheme,plasma/look-and-feel,aurorae/themes,konsole}/*` | same path under `~/.local/share/` |
| `kde/icons/tint.py` | generates `~/.local/share/icons/AmoledMatrix` from Papirus-Dark |

The clone lives at `~/Desktop/dotfiles`; `desktop.gitconfig` hardcodes that path for `core.hooksPath`.

## packages

### Arch

```bash
sudo pacman -S --needed base-devel git git-lfs gnupg python tmux kitty gdb neovim \
    lsd bat ctags ripgrep curl unzip clang llvm pahole tree-sitter-cli \
    rustup nodejs npm wl-clipboard xclip ttf-jetbrains-mono-nerd papirus-icon-theme
rustup default stable
```

### Debian, Ubuntu, Armbian

```bash
sudo apt install build-essential git git-lfs gnupg python3 python3-venv tmux kitty gdb \
    lsd bat universal-ctags ripgrep curl unzip clang clangd llvm dwarves \
    nodejs npm wl-clipboard xclip papirus-icon-theme
mkdir -p ~/.local/bin && ln -sfn /usr/bin/batcat ~/.local/bin/bat
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
. ~/.cargo/env
cargo install --locked tree-sitter-cli
```

Neovim 0.12 or later, from the release tarball for the host architecture:

```bash
arch=$(uname -m | sed s/aarch64/arm64/)
curl -fLO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-$arch.tar.gz
sudo tar -C /opt -xzf nvim-linux-$arch.tar.gz
sudo ln -sfn /opt/nvim-linux-$arch/bin/nvim /usr/local/bin/nvim
```

JetBrainsMono Nerd Font:

```bash
mkdir -p ~/.local/share/fonts/JetBrainsMono
curl -fL https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz \
    | tar -xJ -C ~/.local/share/fonts/JetBrainsMono
fc-cache -f
```

## install

```bash
git clone https://github.com/0xdeadf1sh/dotfiles.git ~/Desktop/dotfiles
~/Desktop/dotfiles/install.sh
```

`install.sh` links every target in the layout table. A real file or directory already at a target is
renamed to `<target>.bak.<epoch>`. The KDE part runs only when `plasmashell` exists; it regenerates the
icon theme from the installed Papirus, so it is re-run after a `papirus-icon-theme` update.

The first Neovim start installs plugins, treesitter parsers and Mason tools.

## x86_64 and aarch64

- Mason ships `clangd` for x86_64 only; other hosts run the system `clangd`.
- `:Asm` adds Intel-syntax flags only when the compiler targets x86 (`cc -dumpmachine`, `rustc --print cfg`).
- `desktop.gdbinit` sets `disassembly-flavor intel`, an x86-only setting.
- `desktop.gitconfig` signs every commit with GPG key `5B31CC985F2862542D6DB9C0CF4DA9F3A45D9EF7`.

## license

```
© 2026 0xdeadf1.sh
Released to the public domain under CC0 1.0 Universal (CC0 1.0)
https://creativecommons.org/publicdomain/zero/1.0/
```
