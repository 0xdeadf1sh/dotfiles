import { expect, test } from 'claude-code/testing'

import { agentInput, tallyLine } from './agents'
import { parse, plain, tableLines } from './markdown'
import { base64, Rain } from './rain'

const BAND = {
  hasSurvey: false,
  isWorking: false,
  maxRows: 10,
  bodyColumns: 40,
  scroll: { offset: 0, bodyRows: 10 },
  view: {},
}

test('base64 matches the standard alphabet and padding', () => {
  expect(base64(new Uint8Array([0x4d, 0x61, 0x6e]))).toBe('TWFu')
  expect(base64(new Uint8Array([0x4d, 0x61]))).toBe('TWE=')
  expect(base64(new Uint8Array([0x4d]))).toBe('TQ==')
})

test('a frame holds columns * rows cells, all width-1 glyphs', () => {
  const rain = new Rain(7, 3)
  for (let i = 0; i < 50; i++) rain.step()
  const encoded = rain.cells()
  expect(encoded.length).toBe(Math.ceil((7 * 3 * 12) / 3) * 4)
})

const REPLY = [
  '# Title',
  'Some **bold**, `code` and [link](https://x.dev).',
  '- one',
  '  2. two',
  '',
  '```rust',
  'fn main() {}',
  '```',
  '| a | long header |',
  '|---|:---:|',
  '| `x` | y |',
].join('\n')

test('parse splits headings, lists, fences and tables', () => {
  expect(parse(REPLY).map(b => b.kind)).toEqual([
    'heading', 'paragraph', 'item', 'item', 'blank', 'code', 'table',
  ])
  expect(parse('```py\nopen fence').at(-1)).toEqual({ kind: 'code', language: 'py', source: 'open fence' })
})

test('table columns align to the widest cell, markup stripped', () => {
  expect(tableLines(['a', 'long header'], [['`x`', 'y']].map(r => r.map(plain)))).toEqual([
    'a  long header',
    '─  ───────────',
    'x  y          ',
  ])
})

test('a reply draws code through Code and text in greens', async $ => {
  const reply = await $.ui.mount({
    plugin: 'matrix',
    surface: 'terminal',
    component: 'AssistantMessage',
    props: { text: REPLY, isFirstOfReply: true },
  })
  expect((await reply.find({ type: 'Code' }))?.props).toMatchObject({ language: 'rust', source: 'fn main() {}' })
  expect((await reply.find({ type: 'Text', text: /^Title$/ }))?.props).toMatchObject({ color: '#00ff41', bold: true })
  expect(await reply.find({ type: 'Text', text: /^x {2}y/ })).toBeDefined()
})

test('the band draws a 3-row Raster as wide as the band', async $ => {
  const band = await $.ui.mount({
    plugin: 'matrix',
    surface: 'terminal',
    component: 'AbovePrompt',
    props: BAND,
  })
  const raster = await band.find({ type: 'Raster', key: 'rain' })
  expect(raster?.props).toMatchObject({ columns: 40, rows: 3 })
})

test('agentInput falls back on missing fields', () => {
  expect(agentInput({ subagent_type: 'Explore', description: 'find x' })).toEqual({ type: 'Explore', description: 'find x' })
  expect(agentInput(null)).toEqual({ type: 'general-purpose', description: '' })
})

test('tallyLine orders tools by count', () => {
  expect(tallyLine({ Bash: 1, Read: 3 })).toBe('Read×3 Bash×1')
  expect(tallyLine(undefined)).toBe('')
})

test('a finished Agent row draws type, description and a check', async $ => {
  const row = await $.ui.mount({
    plugin: 'matrix',
    surface: 'terminal',
    component: 'ToolUse',
    props: {
      tool_use_id: 't1',
      tool: 'Agent',
      input: { subagent_type: 'Explore', description: 'find x', prompt: 'p' },
      isRunning: false,
      isErrored: false,
      isInterrupted: false,
    },
  })
  expect(await row.find({ type: 'Text', text: /^✓$/ })).toBeDefined()
  expect((await row.find({ type: 'Text', text: /^ Explore$/ }))?.props).toMatchObject({ color: '#00ff41' })
  expect(await row.find({ type: 'Text', text: /^find x$/ })).toBeDefined()
})

test('the hint keeps its text in dim green', async $ => {
  const hint = await $.ui.mount({
    plugin: 'matrix',
    surface: 'terminal',
    component: 'PromptHint',
    props: { isDraft: false, isWorking: false, hint: '? for shortcuts' },
  })
  expect((await hint.find({ type: 'Text', text: /^\? for shortcuts$/ }))?.props).toMatchObject({ color: '#2e7d32' })
})

test('mode labels draw lime, joined', async $ => {
  const modes = await $.ui.mount({
    plugin: 'matrix',
    surface: 'terminal',
    component: 'SessionMode',
    props: { modes: ['auto mode on', 'fast'] },
  })
  expect((await modes.find({ type: 'Text', text: /^auto mode on · fast$/ }))?.props).toMatchObject({ color: '#00ff41' })
})
