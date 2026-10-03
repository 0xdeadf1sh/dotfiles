import type { Tally } from '../types'

export const SPIN = 'ｱｲｳｴｵｶｷｸｹｺ'

export function agentInput(input: unknown): { type: string; description: string } {
  const o = (typeof input === 'object' && input !== null ? input : {}) as Record<string, unknown>
  const str = (v: unknown, d: string) => (typeof v === 'string' && v !== '' ? v : d)
  return { type: str(o.subagent_type, 'general-purpose'), description: str(o.description, '') }
}

export function tallyLine(tally: Tally | undefined): string {
  if (tally === undefined) return ''
  return Object.entries(tally)
    .sort((a, b) => b[1] - a[1])
    .map(([tool, n]) => `${tool}×${n}`)
    .join(' ')
}
