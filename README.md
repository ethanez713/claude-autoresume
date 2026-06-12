# claude-autoresume

Auto-wait + auto-resume for an interactive Claude Code session that hits the
5-hour rate limit — **100% local**, no third-party code, only `claude` itself
talks to Anthropic.

When the limit pauses your session in place, a tmux-side monitor reads the
**reset time straight from your status line's `rate_limits.resets_at` signal**,
shows a countdown, and sends `continue the above workflow` + Enter into the same
session when the window resets. No relaunch, same conversation/context.

## How it works (one paragraph)

`claude` runs inside a tmux pane. A background monitor polls the pane to detect
the paused-at-limit state, then waits until the reset time (taken from a state
file that the patched `~/.claude/statusline.py` writes every render) and drives
the un-pause with `tmux send-keys`. See **[PLAN.md](PLAN.md)** for the full spec.

## Status

Scaffold + implementation plan only. Build it by following **[PLAN.md](PLAN.md)**
(§9 TODO). The detection regex and exact resume keystrokes are finalized against a
real limit (PLAN.md §6) — the operator triggers one during implementation.

## One-time setup

See **PLAN.md §4**. In short: install `tmux` (≥2.1), `cp config.example.sh config.sh`,
`mkdir -p ~/.claude/autoresume && chmod 700 ~/.claude/autoresume`, apply the
fail-soft status-line patch (keeps a `.bak`), `chmod +x bin/*`.

## Usage (once built)

```bash
bin/cc-run            # launches claude in tmux + the monitor, attaches you
# ...work normally; walk away. On a limit it waits + auto-resumes.
# Ctrl-b then X       # stop retrying (cancel)
```

## Security

No network calls outside `claude`→Anthropic. No deps beyond bash + tmux + python
stdlib. send-keys is guarded by a foreground check so it can never inject into a
shell. State files are `0600` in a `0700` dir and gitignored. Full requirements in
PLAN.md §8.
