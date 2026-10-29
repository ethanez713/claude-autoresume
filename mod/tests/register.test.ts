import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const T0 = Date.parse('2026-10-28T12:00:00Z')
const HOUR = 3600_000
const CLAIM = '/busy/_tmp_tmux-1000_default__3.mod'

type World = {
  submitted: string[]
  statuses: (string | undefined)[]
  writes: Map<string, string>
  usage: { kind: string; percentUsed: number; resetsAt?: string }[]
}

// Everything beneath the mod: config read through bash, the pane's tmux
// variables, the claim file, the usage figures and the prompt box.
function world(on: On, resumeText = 'continue'): World {
  const w: World = { submitted: [], statuses: [], writes: new Map(), usage: [] }
  const settings = [resumeText, '30', '95', '2 4 8', '', '/busy', ''].join('\x1f') + '\x1f'
  mock.env(on, { TMUX: '/tmp/tmux-1000/default,123,0', TMUX_PANE: '%3' })
  on('process.run', (_, e) => {
    const isConfig = e.argv.some(arg => arg.includes('CCAR_RESUME_TEXT'))
    const stdout = isConfig ? settings : ''
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false } }
  })
  on('fs.write', (_, e) => {
    w.writes.set(e.path, e.text)
    return { value: undefined }
  })
  on('session.usage', () => ({
    value: { startedAt: T0, context: {}, rateLimits: w.usage, cost: undefined },
  }))
  on('command.register', () => ({ value: { command: 'autoresume-cancel' } }))
  on('ui.status', (_, e) => {
    w.statuses.push(e.text)
    return { value: undefined }
  })
  on('ui.log', () => ({ value: undefined }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('prompt.submit', (_, e) => {
    w.submitted.push(e.text)
    return { text: e.text }
  })
  on('classic.StopFailure', () => ({}))
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
  return w
}

const START = { cwd: '/', surface: 'terminal', isInteractive: true } as const
const at = (ms: number) => new Date(ms).toISOString()

test('given a spent five-hour window, when a turn stops on the limit, then the resume is sent only after the reset', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on)
  w.usage = [{ kind: 'five_hour', percentUsed: 100, resetsAt: at(T0 + 2 * HOUR) }]
  await $.session.start(START)
  expect(w.writes.get(CLAIM)?.startsWith('watch\t')).toBe(true)

  await $.classic.StopFailure({ error: 'rate_limit' })
  await clock.settle()
  expect(w.writes.get(CLAIM)?.startsWith('parked\t')).toBe(true)
  expect(w.writes.has('/busy/.activity')).toBe(true)
  expect(w.statuses.at(-1)).toBe('⏳ resume in 2h01m')

  await clock.advance(2 * HOUR)
  expect(w.submitted).toEqual([])
  await clock.advance(60_000)
  expect(w.submitted).toEqual(['continue'])
  expect(w.writes.get(CLAIM)?.startsWith('watch\t')).toBe(true)
  expect(w.statuses.at(-1)).toBeUndefined()
})

test('given both windows spent, when a turn stops on the limit, then the later seven-day reset is the one waited for', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on)
  w.usage = [
    { kind: 'five_hour', percentUsed: 100, resetsAt: at(T0 + HOUR) },
    { kind: 'seven_day', percentUsed: 97.5, resetsAt: at(T0 + 30 * HOUR) },
  ]
  await $.session.start(START)
  await $.classic.StopFailure({ error: 'rate_limit' })
  await clock.settle()
  expect(w.statuses.at(-1)).toBe('⏳ resume in 30h01m')

  await clock.advance(2 * HOUR)
  expect(w.submitted).toEqual([])
})

test('given a pending resume, when the person starts a turn, then no resume is sent', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on)
  w.usage = [{ kind: 'five_hour', percentUsed: 100, resetsAt: at(T0 + 600_000) }]
  await $.session.start(START)
  await $.classic.StopFailure({ error: 'rate_limit' })
  await clock.settle()

  await $.turn.start({ text: 'carry on', turnId: 't1' })
  await clock.advance(HOUR)
  expect(w.submitted).toEqual([])
})

test('given no window at the limit, when stops come back to back, then the retry backs off', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on)
  await $.session.start(START)

  await $.classic.StopFailure({ error: 'rate_limit' })
  await clock.settle()
  expect(w.statuses.at(-1)).toBe('⏳ retry in 2m')
  await clock.advance(2 * 60_000)
  expect(w.submitted).toEqual(['continue'])

  await $.classic.StopFailure({ error: 'rate_limit' })
  await clock.settle()
  expect(w.statuses.at(-1)).toBe('⏳ retry in 4m')
})

test('given other API errors or a subagent stop, when time passes, then nothing is resumed', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on)
  await $.session.start(START)
  await $.classic.StopFailure({ error: 'overloaded' })
  await $.classic.StopFailure({ error: 'rate_limit', agent_id: 'a1' })
  await clock.advance(HOUR)
  expect(w.submitted).toEqual([])
  expect(w.writes.get(CLAIM)?.startsWith('watch\t')).toBe(true)
})

test('given a pending resume, when /autoresume-cancel runs, then no resume is sent', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on)
  await $.session.start(START)
  await $.classic.StopFailure({ error: 'rate_limit' })
  await clock.settle()

  const ran = await $.command.run({ command: 'autoresume-cancel', args: '' })
  expect(ran.text).toBe('Cancelled the pending resume.')
  await clock.advance(HOUR)
  expect(w.submitted).toEqual([])
})

test('given a resume text with a leading slash, when the window opens, then the slash is dropped', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const w = world(on, '/resume the above workflow')
  await $.session.start(START)
  await $.classic.StopFailure({ error: 'rate_limit' })
  await clock.advance(3 * 60_000)
  expect(w.submitted).toEqual(['resume the above workflow'])
})
