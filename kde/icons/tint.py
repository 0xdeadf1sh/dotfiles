#!/usr/bin/env python3
import argparse
import glob
import importlib.util
import os
import re
import shutil
import subprocess
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

HEX = re.compile(r'(?<=[:="\s])#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b')
TEXT_CLASS = re.compile(r'class="ColorScheme-Text"')
ICON_EXT = re.compile(r'\.(png|svg|svgz|xpm)$')
FALLBACK_DIR = 'fallback/apps'
FALLBACK_INDEX = f"""
[{FALLBACK_DIR}]
Context=Applications
Size=48
MinSize=8
MaxSize=512
Type=Scalable
"""


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

    def tint(rgb):
        if rgb not in cache:
            y = luminance([to_linear(c) for c in rgb])
            if y <= acc_y:
                out = [c * y / acc_y for c in acc]
            else:
                t = (y - acc_y) / (1 - acc_y)
                out = [c + (1 - c) * t for c in acc]
            cache[rgb] = tuple(to_srgb(c) for c in out)
        return cache[rgb]

    return tint


def tint_svg(src, dst, accent):
    tint = make_tint(accent)

    def sub(m):
        h = m.group(1)
        if len(h) == 3:
            h = ''.join(c * 2 for c in h)
        return '#%02x%02x%02x' % tint(tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)))

    svg = Path(src).read_text(encoding='utf-8', errors='surrogateescape')
    # PositiveText: green normally, dark green on a selected row.
    svg = TEXT_CLASS.sub('class="ColorScheme-PositiveText"', svg)
    svg = HEX.sub(sub, svg)
    Path(dst).write_text(svg, encoding='utf-8', errors='surrogateescape')


def tint_png(src, dst, accent):
    from PIL import Image

    tint = make_tint(accent)
    im = Image.open(src).convert('RGBA')
    raw = bytearray(im.tobytes())
    for i in range(0, len(raw), 4):
        if raw[i + 3]:
            raw[i:i + 3] = bytes(tint((raw[i], raw[i + 1], raw[i + 2])))
    Image.frombytes('RGBA', im.size, bytes(raw)).save(dst)


def tint_job(job):
    src, dst, accent = job
    (tint_png if src.endswith('.png') else tint_svg)(src, dst, accent)


def data_dirs():
    home = Path(os.environ.get('XDG_DATA_HOME') or Path.home() / '.local/share')
    sys_dirs = os.environ.get('XDG_DATA_DIRS') or '/usr/local/share:/usr/share'
    dirs = [home, *map(Path, filter(None, sys_dirs.split(':'))),
            Path('/var/lib/flatpak/exports/share'), home / 'flatpak/exports/share']
    return [d for d in dict.fromkeys(dirs) if d.is_dir()]


def launcher_icons(dirs):
    names = set()
    for d in dirs:
        for f in (d / 'applications').glob('**/*.desktop'):
            for line in f.read_text(errors='replace').splitlines():
                if line.startswith('Icon='):
                    name = line[5:].strip()
                    if name and '/' not in name:
                        names.add(ICON_EXT.sub('', name))
                    break
    return names


def find_original(name, dirs):
    pngs = []
    esc = glob.escape(name)
    for d in dirs:
        for p in sorted((d / 'icons/hicolor').glob(f'*/apps/{esc}.svg')):
            return p
        svg = d / 'pixmaps' / f'{name}.svg'
        if svg.is_file():
            return svg
        for p in (d / 'icons/hicolor').glob(f'*/apps/{esc}.png'):
            size = p.parent.parent.name.split('x')[0]
            pngs.append((int(size) if size.isdigit() else 48, p))
        png = d / 'pixmaps' / f'{name}.png'
        if png.is_file():
            pngs.append((48, png))
    if not pngs:
        return None
    # Largest up to 256px; 512 and 1024 originals only add tint time.
    small = [x for x in pngs if x[0] <= 256]
    return max(small)[1] if small else min(pngs)[1]


def write_index(src, dst, name, fallback):
    out = []
    for line in (src / 'index.theme').read_text().splitlines():
        if line.startswith('Name='):
            line = f'Name={name}'
        elif line.startswith('Comment='):
            line = f'Comment={src.name} tinted green'
        elif line.startswith('Directories=') and fallback:
            line += f',{FALLBACK_DIR}'
        out.append(line)
    text = '\n'.join(out) + '\n'
    (dst / 'index.theme').write_text(text + (FALLBACK_INDEX if fallback else ''))


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
    have = set()

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
                if not e.is_dir():
                    have.add(ICON_EXT.sub('', e.name))
                if overlay and s.resolve() == (base / r).resolve():
                    continue
                clear(d)
                os.symlink(os.readlink(s), d)
            elif e.is_dir():
                if d.is_symlink():
                    d.unlink()
                walk(s, d, r, overlay)
            elif e.name.endswith('.svg'):
                have.add(e.name[:-4])
                if d.is_symlink():
                    d.unlink()
                jobs[str(d)] = str(s)
            elif rel != Path('.'):
                clear(d)
                shutil.copy2(s, d)

    walk(base, stage, Path('.'), False)
    walk(src, stage, Path('.'), True)

    has_pil = importlib.util.find_spec('PIL') is not None
    dirs = data_dirs()
    fallback = stage / FALLBACK_DIR
    skipped = []
    for name in sorted(launcher_icons(dirs) - have):
        orig = find_original(name, dirs)
        if orig is None:
            continue
        if orig.suffix == '.png' and not has_pil:
            skipped.append(name)
            continue
        fallback.mkdir(parents=True, exist_ok=True)
        jobs[str(fallback / f'{name}{orig.suffix}')] = str(orig)

    with ProcessPoolExecutor() as pool:
        work = [(s, d, args.accent) for d, s in jobs.items()]
        list(pool.map(tint_job, work, chunksize=64))
    n_fallback = len(list(fallback.iterdir())) if fallback.is_dir() else 0
    write_index(src, stage, args.name, n_fallback > 0)

    if args.dest.is_symlink() or args.dest.is_file():
        args.dest.unlink()
    old = args.dest.with_name(args.dest.name + '.old')
    if args.dest.exists():
        args.dest.rename(old)
    stage.rename(args.dest)
    shutil.rmtree(old, ignore_errors=True)

    if shutil.which('gtk-update-icon-cache'):
        subprocess.run(['gtk-update-icon-cache', '-qf', str(args.dest)], check=False)
    print(f'{len(jobs)} icons ({n_fallback} app fallbacks) -> {args.dest}')
    if skipped:
        print(f'pillow missing, PNG icons left untinted: {" ".join(skipped)}')


if __name__ == '__main__':
    main()
