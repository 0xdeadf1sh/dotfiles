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
| `kde/sddm/amoled-matrix/` | copied to `/usr/share/sddm/themes/amoled-matrix` |
| `kde/icons/tint.py` | generates `~/.local/share/icons/AmoledMatrix` from Papirus-Dark, plus tinted copies of installed apps' own icons that Papirus lacks |
| `firefox/{user.js,chrome}` | each install's default profile in `profiles.ini` |
| `chromium/matrix-theme/` | `--load-extension` line in `~/.config/chromium-flags.conf` |
| `darkreader/matrix.json` | none; imported by hand in Dark Reader |

The clone lives at `~/Desktop/dotfiles`; `desktop.gitconfig` hardcodes that path for `core.hooksPath`.

## packages

### Arch

```bash
sudo pacman -S --needed base-devel git git-lfs gnupg python tmux kitty gdb neovim \
    lsd bat ctags ripgrep curl unzip clang llvm pahole tree-sitter-cli \
    rustup nodejs npm wl-clipboard xclip ttf-jetbrains-mono-nerd papirus-icon-theme python-pillow
rustup default stable
```

### Debian, Ubuntu, Armbian

```bash
sudo apt install build-essential git git-lfs gnupg python3 python3-venv tmux kitty gdb \
    lsd bat universal-ctags ripgrep curl unzip clang clangd llvm dwarves \
    nodejs npm wl-clipboard xclip papirus-icon-theme python3-pil
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
icon theme from the installed Papirus, so it is re-run after a `papirus-icon-theme` update. It also
sets the AMOLED Matrix splash screen. When `/usr/share/sddm/themes` exists, it copies the SDDM theme there
and sets `Current=amoled-matrix` (in `/etc/sddm.conf` when it already has that key, otherwise in
`/etc/sddm.conf.d/theme.conf`); this step uses `sudo`. The script runs as the normal
user and exits under root.

The first Neovim start installs plugins, treesitter parsers and Mason tools.

## browsers

- Firefox: `install.sh` links `user.js` and `chrome/` into the profile named by each `[Install*]`
  section of `profiles.ini`, under `~/.config/mozilla/firefox`, `~/.mozilla/firefox` or the snap
  path. A profile exists only after the first Firefox start. `user.js` enables `userChrome.css` and
  `userContent.css`, forces dark pages, and sets the blank-page color to black. In the built-in PDF
  viewer, `userContent.css` colors the toolbar and sidebar and color-inverts pages and thumbnails;
  images keep their approximate hue.
- Chromium: `install.sh` writes `--load-extension=<repo>/chromium/matrix-theme` to
  `~/.config/chromium-flags.conf`, which the Arch launcher reads. On other distros the theme is loaded
  once from `chrome://extensions` → Developer mode → Load unpacked. The theme colors the frame, tabs,
  toolbar, omnibox and new tab page; menus, focus rings and the new tab search box keep Chromium's colors.
- Dark Reader: Settings → Advanced → Import Settings → `darkreader/matrix.json`, once per browser. The
  file sets the theme colors and turns off dark-site detection, so sites with their own dark theme also
  get the matrix colors; site lists stay as they are.

## console colors

These kernel parameters make the default console text `#00ff41` (palette entry 7) and bright white
`#c0ffd0` (entry 15), including kernel messages at boot:

```
vt.default_red=0,170,0,170,0,170,0,0,85,255,85,255,85,255,85,192
vt.default_grn=0,0,170,85,0,0,170,255,85,85,255,255,85,85,255,255
vt.default_blu=0,0,0,0,170,170,170,65,85,85,85,85,255,255,255,208
```

- systemd-boot: appended to the `options` line in `/boot/loader/entries/<entry>.conf`.
- GRUB: appended to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, followed by `sudo update-grub`
  (Debian, Ubuntu) or `sudo grub-mkconfig -o /boot/grub/grub.cfg` (Arch).

`cat /proc/cmdline` shows the parameters after a reboot.

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
