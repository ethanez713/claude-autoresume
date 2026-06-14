# claude-autoresume

Auto-wait + auto-resume for an interactive Claude Code session that hits the
5-hour rate limit — **100% local**, no third-party code, only `claude` itself
talks to Anthropic.

When the account limit pauses your sessions, a single tmux-side monitor reads
your status line's **`used_percentage` + `resets_at` signal**, shows a countdown,
and sends `continue the above workflow` + Enter into **every** paused window when
the window resets. No relaunch, same conversations/context.

## How it works (one paragraph)

`claude` is aliased to `bin/cc-run`. **Inside tmux** it runs Claude in your
current pane (no new server, no nesting); **outside tmux** it falls back to
building a private-socket session and attaching. Either way it records the pane
in a small registry and starts one background monitor. The monitor watches every
registered pane (across your own tmux server and the fallback alike), gates on the
authoritative `used_percentage` written to a state file by the patched
`~/.claude/statusline.py` (so on-screen text can't fool it), waits until
`resets_at`, then drives the un-pause across all panes with `tmux send-keys`.
See **[PLAN.md](PLAN.md)** for the full design.

## Status

**Built and in daily use.** All mechanics dry-run validated (detection
false-positive veto, usage-trigger, viewport-independent multi-pane resume,
bottom-anchored fallback, sleep/wake, cancel, native passthrough, per-dir
windows). One item still needs a real limit to finalize — see **PLAN.md §9**:
confirming `CCAR_RESUME_TEXT` un-pauses claude and whether a menu needs
`CCAR_RESUME_PREKEYS`.

## One-time setup

In short: install `tmux` (≥2.1), `cp config.example.sh config.sh`,
`mkdir -p ~/.claude/autoresume && chmod 700 ~/.claude/autoresume`, apply the
fail-soft status-line patch (keeps a `.bak`), `chmod +x bin/*`, and alias `claude`
to `bin/cc-run` (see Usage).

## Usage

Run the launcher directly, or alias `claude` to it so your normal interface is
always wrapped:

```bash
# ~/.bashrc — interactive shells only; scripts/non-interactive `claude` unaffected
alias claude="$HOME/claude-autoresume/bin/cc-run"
```

```bash
claude                # inside tmux: runs in THIS pane (fresh convo, like native)
claude "fix the bug"  # args forwarded to the real claude
claude -c             # continue this dir's last conversation
claude --resume       # claude's session picker
# ...work normally; walk away. On a limit it waits + auto-resumes in place.
# <prefix> then X     # stop retrying (cancel)   — <prefix> is YOUR tmux prefix
#   ...or run `cc-cancel` from any shell to do the same.
```

Inside tmux, Claude takes over the current pane and your shell prompt returns when
it exits — so open a tmux window/tab per project and run `claude` in each. (When
launched from a plain, non-tmux shell, it instead builds the private `ccar`
fallback server and attaches; `<prefix> then d` detaches it, `claude -c` re-opens.)

### Behaves like native `claude`

The alias is a transparent stand-in for the real CLI:

- **Non-interactive invocations pass straight through, no tmux:** `claude -p …`
  (headless print), every subcommand (`mcp`, `doctor`, `update`, `auth`, …),
  `--version`/`--help`, and any piped/redirected stdin. Only an interactive
  session launch gets wrapped.
- **Runs where you are.** Inside tmux, `claude` runs a fresh conversation in your
  current pane (native semantics — `claude` always starts fresh; use `-c` to
  continue this dir's last convo). The fallback path opens one window per `$PWD`,
  keyed to its dir via a `@ccar_dir` tmux option.
- **One account-wide monitor** watches every registered pane. Because the rate
  limit is per-account (all sessions pause together), on reset it resumes *all*
  paused panes, not just one.

The launch uses `exec claude`, which bypasses the alias (execvp ignores aliases)
so there's no recursion.

The monitor follows your panes via a **registry** (`~/.claude/autoresume/panes/`),
so it works on whichever tmux server you're on. Only the **fallback** path (when
you launch from outside tmux) uses the private `ccar` socket; manage it with:

```bash
tmux -L ccar ls                       # list the fallback session + windows
tmux -L ccar kill-session -t cc       # end the fallback session
```

### Rendering

Claude's TUI garbles on scroll inside tmux if the terminal advertises xterm caps,
so both paths need `default-terminal tmux-256color` + truecolor `terminal-features
RGB`. **In-tmux:** put these in your own `~/.tmux.conf` (your normal server renders
Claude). **Fallback:** the `ccar` session loads this repo's `tmux.conf`, which
sources your `~/.tmux.conf` (you keep your prefix/mouse/keys), applies the same
caps, and — because a hardcoded `TERM=screen-256color` in the shell rc makes tmux
render with the wrong terminfo — attaches with `TERM=xterm-256color`
(`CCAR_OUTER_TERM`). Scroll with tmux copy-mode (`<prefix>` then `[`).

The config also forwards Claude's terminal title (status emoji + session summary)
to the outer terminal tab via `set-titles on` / `set-titles-string '#T'` — tmux
otherwise swallows the app's OSC title into the pane title. (If Windows Terminal
doesn't update, check the profile's "Suppress title changes" isn't enabled.)

## Security

No network calls outside `claude`→Anthropic. No deps beyond bash + tmux + python
stdlib. send-keys is guarded by a foreground check so it can never inject into a
shell. State files are `0600` in a `0700` dir and gitignored. Full requirements in
PLAN.md §7.
