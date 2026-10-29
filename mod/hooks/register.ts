import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { AutoresumeWait } from '../types'
import {
  DEFAULT_SETTINGS,
  formatCountdown,
  paneKey,
  parseSettings,
  planWait,
  readSettingsScript,
  resumePrompt,
} from './plan'
import type { Settings } from './plan'

type Engine = EngineInterface

const waitAtom = atom(
  { plugin: 'autoresume', key: 'wait' } as const,
  null as AutoresumeWait | null,
  { shape: 'wait-1' },
)
const failuresAtom = atom({ plugin: 'autoresume', key: 'failures' } as const, 0, {
  shape: 'failures-1',
})

const TICK_MS = 30_000
const HEARTBEAT_MS = 60_000
const HOST_RESYNC_MS = 10 * 60_000
// A tick that lands this late means the machine slept: the WSL guest clock
// can come back behind the host's, so re-read the host clock at once.
const SUSPEND_GAP_MS = 90_000

let settings: Settings = DEFAULT_SETTINGS
let claimPath: string | undefined
let claimState: string | undefined
let label = 'mod'
let tick: Timer | undefined
let heartbeat: Timer | undefined
let clockOffsetMs = 0
let lastHostSyncMs = -Infinity
let lastTickMs: number | undefined
let resuming = false

async function log($: Engine, text: string) {
  $.ui.log(`autoresume: ${text}`, { to: 'debug' })
  if (!settings.logPath) return
  await $.process
    .run(['bash', '-c', 'printf "%s %s\\n" "$(date "+%F %T")" "$1" >>"$2"', '_', `${label}: ${text}`, settings.logPath])
    .catch(() => undefined)
}

async function loadSettings($: Engine) {
  const repo = `${$.plugin.root}/..`
  const ran = await $.process.run(['bash', '-c', readSettingsScript, '_', repo]).catch(() => undefined)
  settings = ran?.exitCode === 0 ? parseSettings(ran.stdout) : DEFAULT_SETTINGS
}

async function locateClaim($: Engine) {
  const tmux = await $.env.get('TMUX')
  const pane = await $.env.get('TMUX_PANE')
  if (!tmux || !pane || !settings.busyDir) return
  claimPath = `${settings.busyDir}/${paneKey(tmux, pane)}.mod`
  label = `mod[${pane}]`
}

// The monitor leaves a pane to this mod while the file is fresh, and shows
// the hourglass while it reads "parked". The .activity stamp wakes a monitor
// that is in its quiet wait so the glyph follows a state change.
async function writeClaim($: Engine) {
  if (!claimPath) return
  const state = (await read($, waitAtom)) ? 'parked' : 'watch'
  const sec = Math.floor((await $.clock.now()) / 1000)
  try {
    await $.fs.write(claimPath, `${state}\t${sec}\n`)
    if (state !== claimState) await $.fs.write(`${settings.busyDir}/.activity`, '')
    claimState = state
  } catch {
    // The monitor falls back to its own detection when the claim goes stale.
  }
}

async function trueNow($: Engine, forceSync: boolean): Promise<number> {
  const local = await $.clock.now()
  if (settings.hostTimeCmd && (forceSync || local - lastHostSyncMs >= HOST_RESYNC_MS)) {
    lastHostSyncMs = local
    const ran = await $.process
      .run(['bash', '-c', settings.hostTimeCmd], { timeoutMs: 15_000 })
      .catch(() => undefined)
    const hostSec = Number(ran?.stdout.trim())
    if (ran?.exitCode === 0 && Number.isFinite(hostSec) && hostSec > 0) {
      clockOffsetMs = hostSec * 1000 - local
    }
  }
  return local + clockOffsetMs
}

function stopTick($: Engine) {
  tick?.cancel()
  tick = undefined
  lastTickMs = undefined
  $.ui.status(undefined)
}

function armTick($: Engine) {
  tick?.cancel()
  lastTickMs = undefined
  tick = $.clock.every(TICK_MS, () => void onTick($))
  void onTick($)
}

async function onTick($: Engine) {
  const wait = await read($, waitAtom)
  if (!wait) return stopTick($)
  const local = await $.clock.now()
  const slept = lastTickMs !== undefined && local - lastTickMs > SUSPEND_GAP_MS
  lastTickMs = local
  const now = await trueNow($, slept)
  if (now >= wait.targetMs) return resume($)
  const verb = wait.mode === 'reset' ? 'resume' : 'retry'
  $.ui.status(`⏳ ${verb} in ${formatCountdown(wait.targetMs - now)}`)
}

async function setWait($: Engine, wait: AutoresumeWait | null) {
  await update($, waitAtom, () => wait)
  await writeClaim($)
}

async function clearWait($: Engine, why: string) {
  if (!(await read($, waitAtom))) return
  stopTick($)
  await setWait($, null)
  await log($, `pending resume dropped: ${why}`)
}

async function latch($: Engine) {
  const failures = await update($, failuresAtom, n => n + 1)
  const now = await trueNow($, true)
  const { rateLimits } = await $.session.usage()
  const wait = planWait(rateLimits, now, failures, settings)
  await setWait($, wait)
  const inMs = formatCountdown(wait.targetMs - now)
  await log($, `limit stop #${failures}; ${wait.mode === 'reset' ? 'resume at the reset' : 'retry'} in ${inMs}`)
  armTick($)
}

async function resume($: Engine) {
  if (resuming) return
  resuming = true
  try {
    stopTick($)
    await setWait($, null)
    await log($, 'window open: submitting the resume prompt')
    await $.prompt.submit({ text: resumePrompt(settings.resumeText) })
  } finally {
    resuming = false
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await loadSettings($)
    await locateClaim($)
    await $.command.register({
      name: 'autoresume-cancel',
      description: 'Cancel the resume this session is waiting to send after the usage limit',
    })
    heartbeat?.cancel()
    heartbeat = $.clock.every(HEARTBEAT_MS, () => void writeClaim($))
    await writeClaim($)
    if (await read($, waitAtom)) armTick($)
    return next(e)
  })

  on('classic.StopFailure', async ($, e, next) => {
    const result = await next(e)
    if (e.error === 'rate_limit' && e.agent_id === undefined) await latch($)
    return result
  })

  // Any main-loop turn means the session is moving again: the person resumed
  // by hand, or this mod's own prompt started.
  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) await clearWait($, 'a turn started')
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined && e.reason === 'answer') await update($, failuresAtom, () => 0)
    return next(e)
  })

  on('command.run', { command: 'autoresume-cancel' }, async $ => {
    const had = await read($, waitAtom)
    await clearWait($, 'cancelled with /autoresume-cancel')
    return { text: had ? 'Cancelled the pending resume.' : 'No resume is pending.' }
  })

  on('session.end', async ($, e, next) => {
    await clearWait($, `session ${e.reason}`)
    await update($, failuresAtom, () => 0)
    if (e.reason !== 'clear') {
      heartbeat?.cancel()
      if (claimPath) await $.process.run(['rm', '-f', claimPath]).catch(() => undefined)
    }
    return next(e)
  })
}
