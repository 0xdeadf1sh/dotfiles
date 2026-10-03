#!/usr/bin/env python3
import argparse
import os
import re
import shutil
import subprocess
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

HEX = re.compile(r'(?<=[:="\s])#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b')
TEXT_CLASS = re.compile(r'class="ColorScheme-Text"')


def to_linear(c):
    c /= 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def to_srgb(c):
    c = c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055
    return round(min(max(c, 0.0), 1.0) * 255)


def luminance(rgb):
    r, g, b = rgb
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def make_tint(accent):
    acc = [to_linear(int(accent[i:i + 2], 16)) for i in (0, 2, 4)]
    acc_y = luminance(acc)
    cache = {}

    def tint(m):
        h = m.group(1).lower()
        if len(h) == 3:
            h = ''.join(c * 2 for c in h)
        if h not in cache:
            y = luminance([to_linear(int(h[i:i + 2], 16)) for i in (0, 2, 4)])
            if y <= acc_y:
                out = [c * y / acc_y for c in acc]
            else:
                t = (y - acc_y) / (1 - acc_y)
                out = [c + (1 - c) * t for c in acc]
            cache[h] = '#' + ''.join(f'{to_srgb(c):02x}' for c in out)
        return cache[h]

    return tint


def tint_file(job):
    src, dst, accent = job
    svg = Path(src).read_text(encoding='utf-8', errors='surrogateescape')
    # PositiveText: green normally, dark green on a selected row.
    svg = TEXT_CLASS.sub('class="ColorScheme-PositiveText"', svg)
    svg = HEX.sub(make_tint(accent), svg)
    Path(dst).write_text(svg, encoding='utf-8', errors='surrogateescape')


def write_index(src, dst, name):
    out = []
    for line in (src / 'index.theme').read_text().splitlines():
        if line.startswith('Name='):
            line = f'Name={name}'
        elif line.startswith('Comment='):
            line = f'Comment={src.name} tinted green'
        out.append(line)
    (dst / 'index.theme').write_text('\n'.join(out) + '\n')


def main():
    ap = argparse.ArgumentParser(description='Tint an SVG icon theme to one accent color.')
    ap.add_argument('--base', type=Path, default=Path('/usr/share/icons/Papirus'))
    ap.add_argument('--src', type=Path, default=Path('/usr/share/icons/Papirus-Dark'))
    ap.add_argument('--dest', type=Path, default=Path.home() / '.local/share/icons/AmoledMatrix')
    ap.add_argument('--accent', default='00ff66', help='RRGGBB')
    ap.add_argument('--name', default='AMOLED Matrix')
    args = ap.parse_args()

    src = args.src.resolve()
    stage = args.dest.with_name(args.dest.name + '.new')
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)

    base = args.base.resolve()
    jobs = {}

    def clear(d):
        if d.is_symlink() or d.is_file():
            d.unlink()
        elif d.is_dir():
            shutil.rmtree(d)

    def walk(sdir, ddir, rel, overlay):
        ddir.mkdir(exist_ok=True)
        for e in os.scandir(sdir):
            s, d, r = Path(e.path), ddir / e.name, rel / e.name
            if e.is_symlink():
                if overlay and s.resolve() == (base / r).resolve():
                    continue
                clear(d)
                os.symlink(os.readlink(s), d)
            elif e.is_dir():
                if d.is_symlink():
                    d.unlink()
                walk(s, d, r, overlay)
            elif e.name.endswith('.svg'):
                if d.is_symlink():
                    d.unlink()
                jobs[str(d)] = str(s)
            elif rel != Path('.'):
                clear(d)
                shutil.copy2(s, d)

    walk(base, stage, Path('.'), False)
    walk(src, stage, Path('.'), True)

    with ProcessPoolExecutor() as pool:
        work = [(s, d, args.accent) for d, s in jobs.items()]
        list(pool.map(tint_file, work, chunksize=256))
    write_index(src, stage, args.name)

    if args.dest.is_symlink() or args.dest.is_file():
        args.dest.unlink()
    old = args.dest.with_name(args.dest.name + '.old')
    if args.dest.exists():
        args.dest.rename(old)
    stage.rename(args.dest)
    shutil.rmtree(old, ignore_errors=True)

    if shutil.which('gtk-update-icon-cache'):
        subprocess.run(['gtk-update-icon-cache', '-qf', str(args.dest)], check=False)
    print(f'{len(jobs)} icons -> {args.dest}')


if __name__ == '__main__':
    main()
