#!/usr/bin/env bash
set -euo pipefail

d=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
share=${XDG_DATA_HOME:-$HOME/.local/share}

link() {
    local src=$1 dst=$2
    mkdir -p "$(dirname "$dst")"
    if [[ -e $dst && ! -L $dst ]]; then
        mv "$dst" "$dst.bak.$(date +%s)"
        echo "moved $dst aside"
    fi
    ln -sfn "$src" "$dst"
}

link "$d/desktop.bashrc"    ~/.bashrc
link "$d/desktop.gitconfig" ~/.gitconfig
link "$d/desktop.tmux.conf" ~/.tmux.conf
link "$d/desktop.gdbinit"   ~/.gdbinit
link "$d/kitty.conf"        ~/.config/kitty/kitty.conf
link "$d/nvim"              ~/.config/nvim
link "$d/lsd"               ~/.config/lsd
link "$d/bat"               ~/.config/bat
command -v bat >/dev/null && bat cache --build >/dev/null
for f in CLAUDE.md settings.json statusline-command.sh hooks skills; do
    link "$d/claude/$f" ~/.claude/$f
done

if command -v plasmashell >/dev/null; then
    link "$d/kde/color-schemes/AmoledMatrix.colors" "$share/color-schemes/AmoledMatrix.colors"
    link "$d/kde/plasma/desktoptheme/amoled-matrix" "$share/plasma/desktoptheme/amoled-matrix"
    link "$d/kde/plasma/look-and-feel/org.amoledmatrix.desktop" \
         "$share/plasma/look-and-feel/org.amoledmatrix.desktop"
    link "$d/kde/aurorae/themes/AmoledMatrix" "$share/aurorae/themes/AmoledMatrix"
    link "$d/kde/konsole/AmoledMatrix.colorscheme" "$share/konsole/AmoledMatrix.colorscheme"
    link "$d/kde/konsole/AmoledMatrix.profile" "$share/konsole/AmoledMatrix.profile"
    if [[ -d /usr/share/icons/Papirus-Dark ]]; then
        python3 "$d/kde/icons/tint.py" --dest "$share/icons/AmoledMatrix"
    else
        echo "papirus-icon-theme missing; AmoledMatrix icons not generated"
    fi
fi
