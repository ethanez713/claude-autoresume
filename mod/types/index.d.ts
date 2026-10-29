export type AutoresumeWait = {
  targetMs: number
  mode: 'reset' | 'backoff'
}

declare module 'claude-code' {
  interface PluginState {
    autoresume: {
      wait: Shaped<AutoresumeWait | null>
      failures: Shaped<number>
    }
  }
}
