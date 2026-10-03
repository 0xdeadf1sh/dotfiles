#!/usr/bin/env python3
import colorsys
import io
import re
import struct
import urllib.request
import zipfile
import zlib
from pathlib import Path

DEFAULT_URL = 'https://raw.githubusercontent.com/desktop-app/lib_ui/master/ui/colors.palette'
NIGHT_URL = ('https://raw.githubusercontent.com/telegramdesktop/tdesktop/dev/'
             'Telegram/Resources/night.tdesktop-theme')
OUT = Path(__file__).with_name('matrix.tdesktop-theme')

ACCENT = '20c84a'
HIGH = 'e0ffe8'
# Night's windowBg; at or below it becomes #000000, anything above starts at FLOOR.
BLACK_POINT = '17212b'
FLOOR = '03240d'

ENTRY = re.compile(r'^\s*([A-Za-z]\w*)\s*:\s*([^;]+);', re.M)
HEX = re.compile(r'#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$')


def fetch(url):
    with urllib.request.urlopen(url) as r:
        return r.read()


def value(v):
    # "#hex | key" is palette-source only; theme files take one value, and key follows the theme.
    v = v.split('|')[-1].strip()
    return v.lower() if v.startswith('#') else v


def parse(text):
    return {k: value(v) for k, v in ENTRY.findall(text)}


def to_linear(c):
    c /= 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def to_srgb(c):
    c = c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055
    return round(min(max(c, 0.0), 1.0) * 255)


def rgb(h):
    return [int(h[i:i + 2], 16) for i in (0, 2, 4)]


def luminance(lin):
    r, g, b = lin
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


ACC = [to_linear(c) for c in rgb(ACCENT)]
ACC_Y = luminance(ACC)
HI = [to_linear(c) for c in rgb(HIGH)]
BLACK_Y = luminance([to_linear(c) for c in rgb(BLACK_POINT)])
FLOOR_Y = luminance([to_linear(c) for c in rgb(FLOOR)])


def keeps_hue(c):
    h, s, v = colorsys.rgb_to_hsv(*(x / 255 for x in c))
    return s >= 0.3 and v >= 0.25 and not 0.5 <= h <= 0.72


def tint(value):
    m = HEX.match(value)
    if not m:
        return value
    c = rgb(m[1])
    if keeps_hue(c):
        return value
    y = luminance([to_linear(x) for x in c])
    y = 0.0 if y <= BLACK_Y else FLOOR_Y + (y - BLACK_Y) / (1 - BLACK_Y) * (1 - FLOOR_Y)
    if y <= ACC_Y:
        out = [a * y / ACC_Y for a in ACC]
    else:
        t = (y - ACC_Y) / (1 - ACC_Y)
        out = [a + (h - a) * t for a, h in zip(ACC, HI)]
    return '#' + ''.join(f'{to_srgb(x):02x}' for x in out) + (m[2] or '')


def black_png():
    def chunk(kind, data):
        return (struct.pack('>I', len(data)) + kind + data
                + struct.pack('>I', zlib.crc32(kind + data)))
    ihdr = struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', zlib.compress(b'\0\0\0\0')) + chunk(b'IEND', b''))


def main():
    palette = parse(fetch(DEFAULT_URL).decode())
    with zipfile.ZipFile(io.BytesIO(fetch(NIGHT_URL))) as z:
        palette.update(parse(z.read('colors.tdesktop-theme').decode()))
    colors = ''.join(f'{k}: {tint(v)};\n' for k, v in palette.items())
    with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED) as z:
        for name in ('colors.tdesktop-theme', 'background.png'):
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, colors if name.startswith('colors') else black_png())


if __name__ == '__main__':
    main()
