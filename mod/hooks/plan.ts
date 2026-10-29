import type { SessionRateLimit } from 'claude-code'

import type { AutoresumeWait } from '../types'

export type Settings = {
  resumeText: string
  marginMs: number
  limitPct: number
  backoffMinutes: number[]
  hostTimeCmd: string
  busyDir: string
  logPath: string
}

export const DEFAULT_SETTINGS: Settings = {
  resumeText: 'continue',
  marginMs: 30_000,
  limitPct: 95,
  backoffMinutes: [2, 4, 8, 16, 30],
  hostTimeCmd: '',
  busyDir: '',
  logPath: '',
}

// Field order is the printf order in readSettingsScript.
export function parseSettings(stdout: string): Settings {
  const [text, margin, pct, backoff, hostCmd, busyDir, logPath] = stdout.split('\x1f')
  const num = (raw: string | undefined, fallback: number) => {
    const n = Number(raw)
    return raw !== undefined && raw.trim() !== '' && Number.isFinite(n) ? n : fallback
  }
  const steps = (backoff ?? '')
    .split(/\s+/)
    .map(Number)
    .filter(n => Number.isFinite(n) && n > 0)
  return {
    resumeText: text?.trim() ? text : DEFAULT_SETTINGS.resumeText,
    marginMs: num(margin, 30) * 1000,
    limitPct: num(pct, DEFAULT_SETTINGS.limitPct),
    backoffMinutes: steps.length > 0 ? steps : DEFAULT_SETTINGS.backoffMinutes,
    hostTimeCmd: hostCmd ?? '',
    busyDir: busyDir ?? '',
    logPath: logPath ?? '',
  }
}

export const readSettingsScript = [
  'cfg="${CCAR_CONFIG:-$1/config.sh}"',
  '[ -f "$cfg" ] || cfg="$1/config.example.sh"',
  'source "$cfg" >/dev/null 2>&1',
  'printf "%s\\x1f" "${CCAR_RESUME_TEXT:-continue}" "${CCAR_RESET_MARGIN_SECONDS:-30}"' +
    ' "${CCAR_LIMIT_PCT:-95}" "${CCAR_BACKOFF_MINUTES:-2 4 8 16 30}" "${CCAR_HOST_TIME_CMD-}"' +
    ' "${CCAR_BUSY_DIR:-${CCAR_STATE_DIR:-$HOME/.claude/autoresume}/busy}" "${CCAR_LOG-}"',
].join('\n')

// The latest reset among the windows at the limit is the one that binds: a
// five-hour reset is no use while the seven-day window is still spent. With
// no such window (a transient 429, or figures that already rolled over) the
// wait backs off by how many limit stops ran back to back.
export function planWait(
  rateLimits: readonly SessionRateLimit[],
  nowMs: number,
  failures: number,
  settings: Settings,
): AutoresumeWait {
  const resets = rateLimits
    .filter(w => w.percentUsed >= settings.limitPct && w.resetsAt !== undefined)
    .map(w => Date.parse(w.resetsAt ?? ''))
    .filter(ms => Number.isFinite(ms) && ms > nowMs)
  if (resets.length > 0) {
    return { targetMs: Math.max(...resets) + settings.marginMs, mode: 'reset' }
  }
  const steps = settings.backoffMinutes
  const minutes = steps[Math.min(Math.max(failures - 1, 0), steps.length - 1)] ?? 2
  return { targetMs: nowMs + minutes * 60_000, mode: 'backoff' }
}

// A leading slash would make the resume run as a slash command.
export function resumePrompt(text: string): string {
  return text.replace(/^\s*\/+/, '')
}

// Same key the monitor and cc-busy-hook derive: "<socket>:<pane id>" with
// everything outside [A-Za-z0-9._-] folded to "_".
export function paneKey(tmux: string, pane: string): string {
  const socket = tmux.split(',')[0] ?? ''
  return `${socket}:${pane}`.replace(/[^A-Za-z0-9._-]/g, '_')
}

export function formatCountdown(ms: number): string {
  const minutes = Math.max(0, Math.ceil(ms / 60_000))
  const h = Math.floor(minutes / 60)
  return h > 0 ? `${h}h${String(minutes % 60).padStart(2, '0')}m` : `${minutes}m`
}
