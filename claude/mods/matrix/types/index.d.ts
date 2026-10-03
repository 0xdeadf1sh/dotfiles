export type Tally = Record<string, number>

declare module 'claude-code' {
  interface PluginState {
    matrix: { tallies: Record<string, Tally>; frame: number }
  }
}
