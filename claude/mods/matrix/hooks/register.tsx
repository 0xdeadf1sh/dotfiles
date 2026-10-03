import type { Register } from 'claude-code'

import { parse, tableLines, type Span } from './markdown'
import { LIME, Rain } from './rain'

const BAND_ROWS = 3
const FRAME_MS = 83

const GREEN = {
  heading: LIME,
  body: '#3fbf5f',
  bold: '#b8ffc8',
  code: '#3dffb0',
  link: '#00e5a0',
  dim: '#2e7d32',
}

export const register: Register = on => {
  let rain: Rain | undefined
  let bandId: string | undefined

  on('session.start', ($, e, next) => {
    $.clock.every(FRAME_MS, () => {
      if (rain === undefined || bandId === undefined) return
      rain.step()
      void $.ui.blit({ requestId: bandId, key: 'rain', cells: rain.cells() })
    })
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => {
    if (e.surface !== 'terminal' || e.props.hasSurvey) {
      bandId = undefined
      return next(e)
    }
    const columns = Math.min(512, e.props.bodyColumns)
    // One row is the top margin that mirrors the engine's gap below the band.
    const rows = Math.min(BAND_ROWS, e.props.maxRows - 1)
    if (columns < 1 || rows < 1) return next(e)
    if (rain === undefined || rain.columns !== columns || rain.rows !== rows) {
      rain = new Rain(columns, rows)
    }
    bandId = e.requestId
    const { Box, Raster } = $.ui.resolve(e)
    return (
      <Box marginTop={1}>
        <Raster key="rain" columns={columns} rows={rows} cells={rain.cells()} />
      </Box>
    )
  })

  on('ui.render', { component: 'UserMessage' }, ($, e, next) => {
    if (e.props.isExpanded || e.props.origin.kind !== 'composer') return next(e)
    const { Text } = $.ui.resolve(e)
    return <Text color={LIME} bold>{'> ' + e.props.text}</Text>
  })

  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    const { Box, Text, Code } = $.ui.resolve(e)

    const spans = (list: Span[], base: string) =>
      list.map(s => {
        switch (s.kind) {
          case 'text': return <Text color={base}>{s.text}</Text>
          case 'bold': return <Text color={GREEN.bold} bold>{s.text}</Text>
          case 'italic': return <Text color={base} italic>{s.text}</Text>
          case 'code': return <Text color={GREEN.code}>{s.text}</Text>
          case 'link': return <Text color={GREEN.link} underline>{s.text}</Text>
        }
      })

    const blocks = parse(e.props.text).map(b => {
      switch (b.kind) {
        case 'blank': return <Text> </Text>
        case 'rule': return <Text color={GREEN.dim}>{'─'.repeat(40)}</Text>
        case 'heading': return <Text color={GREEN.heading} bold>{spans(b.spans, GREEN.heading)}</Text>
        case 'paragraph': return <Text color={GREEN.body}>{spans(b.spans, GREEN.body)}</Text>
        case 'item':
          return (
            <Text color={GREEN.body}>
              <Text color={GREEN.dim}>{' '.repeat(b.indent) + b.marker + ' '}</Text>
              {spans(b.spans, GREEN.body)}
            </Text>
          )
        case 'quote':
          return (
            <Text color={GREEN.body} italic>
              <Text color={GREEN.dim}>{'│ '}</Text>
              {spans(b.spans, GREEN.body)}
            </Text>
          )
        case 'code': return <Code source={b.source} language={b.language} />
        case 'table': {
          const [head, rule, ...body] = tableLines(b.header, b.rows)
          return (
            <Box flexDirection="column">
              <Text color={GREEN.heading} bold wrap="truncate-end">{head}</Text>
              <Text color={GREEN.dim} wrap="truncate-end">{rule}</Text>
              {body.map(row => <Text color={GREEN.body} wrap="truncate-end">{row}</Text>)}
            </Box>
          )
        }
      }
    })

    return (
      <Box flexDirection="row">
        <Text color={LIME}>{e.props.isFirstOfReply ? '● ' : '  '}</Text>
        <Box flexDirection="column" flexGrow={1}>{blocks}</Box>
      </Box>
    )
  })
}
