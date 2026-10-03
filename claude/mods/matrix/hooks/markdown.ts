export type Span =
  | { kind: 'text'; text: string }
  | { kind: 'bold'; text: string }
  | { kind: 'italic'; text: string }
  | { kind: 'code'; text: string }
  | { kind: 'link'; text: string; href: string }

export type Block =
  | { kind: 'blank' }
  | { kind: 'rule' }
  | { kind: 'heading'; level: number; spans: Span[] }
  | { kind: 'paragraph'; spans: Span[] }
  | { kind: 'item'; indent: number; marker: string; spans: Span[] }
  | { kind: 'quote'; spans: Span[] }
  | { kind: 'code'; language: string | undefined; source: string }
  | { kind: 'table'; header: string[]; rows: string[][] }

const INLINE = /(`[^`]+`)|(\*\*[^*]+\*\*|__[^_]+__)|(\[[^\]]+\]\([^)\s]+\))|(\*[^*\s][^*]*\*|_[^_\s][^_]*_)/g

export function inline(text: string): Span[] {
  const spans: Span[] = []
  let last = 0
  for (const m of text.matchAll(INLINE)) {
    const at = m.index ?? 0
    if (at > last) spans.push({ kind: 'text', text: text.slice(last, at) })
    const s = m[0]
    if (m[1]) spans.push({ kind: 'code', text: s.slice(1, -1) })
    else if (m[2]) spans.push({ kind: 'bold', text: s.slice(2, -2) })
    else if (m[3]) {
      const close = s.indexOf('](')
      spans.push({ kind: 'link', text: s.slice(1, close), href: s.slice(close + 2, -1) })
    } else spans.push({ kind: 'italic', text: s.slice(1, -1) })
    last = at + s.length
  }
  if (last < text.length) spans.push({ kind: 'text', text: text.slice(last) })
  return spans
}

export function plain(text: string): string {
  return inline(text).map(s => s.text).join('')
}

const TABLE_RULE = /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/

function cells(line: string): string[] {
  return line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map(c => plain(c.trim()))
}

export function parse(source: string): Block[] {
  const lines = source.split('\n')
  const blocks: Block[] = []
  let i = 0
  while (i < lines.length) {
    const line = lines[i]!
    const fence = /^\s*(```+|~~~+)\s*([\w+#.-]*)/.exec(line)
    if (fence) {
      const close = fence[1]!
      const body: string[] = []
      i++
      while (i < lines.length && !lines[i]!.trim().startsWith(close)) body.push(lines[i++]!)
      i++
      blocks.push({ kind: 'code', language: fence[2] || undefined, source: body.join('\n') })
      continue
    }
    if (line.includes('|') && i + 1 < lines.length && TABLE_RULE.test(lines[i + 1]!)) {
      const header = cells(line)
      const rows: string[][] = []
      i += 2
      while (i < lines.length && lines[i]!.includes('|') && lines[i]!.trim() !== '') {
        rows.push(cells(lines[i++]!))
      }
      blocks.push({ kind: 'table', header, rows })
      continue
    }
    i++
    if (line.trim() === '') {
      blocks.push({ kind: 'blank' })
      continue
    }
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) {
      blocks.push({ kind: 'rule' })
      continue
    }
    const heading = /^(#{1,6})\s+(.*)$/.exec(line)
    if (heading) {
      blocks.push({ kind: 'heading', level: heading[1]!.length, spans: inline(heading[2]!) })
      continue
    }
    const item = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(line)
    if (item) {
      const marker = /\d/.test(item[2]!) ? item[2]! : '•'
      blocks.push({ kind: 'item', indent: item[1]!.length, marker, spans: inline(item[3]!) })
      continue
    }
    const quote = /^\s*>\s?(.*)$/.exec(line)
    if (quote) {
      blocks.push({ kind: 'quote', spans: inline(quote[1]!) })
      continue
    }
    blocks.push({ kind: 'paragraph', spans: inline(line) })
  }
  return blocks
}

export function tableLines(header: string[], rows: string[][]): string[] {
  const width = header.length
  const all = [header, ...rows].map(r => Array.from({ length: width }, (_, c) => r[c] ?? ''))
  const widths = Array.from({ length: width }, (_, c) => Math.max(...all.map(r => r[c]!.length)))
  const line = (r: string[]) => r.map((cell, c) => cell.padEnd(widths[c]!)).join('  ')
  return [line(all[0]!), widths.map(w => '─'.repeat(w)).join('  '), ...all.slice(1).map(line)]
}
