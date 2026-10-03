export const LIME = '#00ff41'

const HEAD = 0xd8ffd8
const TERMINAL_DEFAULT = 0x01000000
const TRAIL = [0x00ff41, 0x00d936, 0x00b32c, 0x008f23, 0x006b1a, 0x004a12, 0x002e0b]

// Half-width katakana U+FF66..FF9D and digits: all width-1 BMP, as Raster requires.
const GLYPHS = [
  ...Array.from({ length: 0xff9d - 0xff66 + 1 }, (_, i) => 0xff66 + i),
  ...Array.from({ length: 10 }, (_, i) => 0x30 + i),
]

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

export function base64(bytes: Uint8Array): string {
  let out = ''
  for (let i = 0; i < bytes.length; i += 3) {
    const n = (bytes[i]! << 16) | ((bytes[i + 1] ?? 0) << 8) | (bytes[i + 2] ?? 0)
    out += B64[(n >> 18) & 63]! + B64[(n >> 12) & 63]!
    out += i + 1 < bytes.length ? B64[(n >> 6) & 63]! : '='
    out += i + 2 < bytes.length ? B64[n & 63]! : '='
  }
  return out
}

type Drop = { y: number; speed: number; length: number; glyphs: number[] }

export class Rain {
  private drops: Drop[] = []

  constructor(
    readonly columns: number,
    readonly rows: number,
    private random: () => number = Math.random,
  ) {
    for (let x = 0; x < columns; x++) {
      this.drops.push(this.spawn(-this.random() * rows * 3))
    }
  }

  private glyph(): number {
    return GLYPHS[Math.floor(this.random() * GLYPHS.length)]!
  }

  private spawn(y: number): Drop {
    const length = 2 + Math.floor(this.random() * TRAIL.length)
    return {
      y,
      speed: 0.25 + this.random() * 0.6,
      length,
      glyphs: Array.from({ length: this.rows + length }, () => this.glyph()),
    }
  }

  step(): void {
    for (let x = 0; x < this.columns; x++) {
      const drop = this.drops[x]!
      drop.y += drop.speed
      if (this.random() < 0.05) {
        drop.glyphs[Math.floor(this.random() * drop.glyphs.length)] = this.glyph()
      }
      if (drop.y - drop.length > this.rows) {
        this.drops[x] = this.spawn(-this.random() * this.rows * 2)
      }
    }
  }

  // Row-major [codePoint, fg, bg] little-endian u32 triplets, base64, per RasterProps.cells.
  cells(): string {
    const words = new Uint32Array(this.columns * this.rows * 3)
    for (let i = 0; i < this.columns * this.rows; i++) {
      words[i * 3] = 0x20
      words[i * 3 + 2] = TERMINAL_DEFAULT
    }
    for (let x = 0; x < this.columns; x++) {
      const drop = this.drops[x]!
      const head = Math.floor(drop.y)
      for (let k = 0; k < drop.length; k++) {
        const y = head - k
        if (y < 0 || y >= this.rows) continue
        const at = (y * this.columns + x) * 3
        words[at] = drop.glyphs[y % drop.glyphs.length]!
        words[at + 1] = k === 0 ? HEAD : TRAIL[Math.min(k - 1, TRAIL.length - 1)]!
      }
    }
    return base64(new Uint8Array(words.buffer))
  }
}
