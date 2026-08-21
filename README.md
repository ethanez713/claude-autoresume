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
registered pane (across your own tmux server and the fallback alike) and flags
each pane the moment it shows evidence of hitting the limit — the pause message
on screen, the rate-limit choice prompt (which it answers), or the
`used_percentage` signal written to a state file by the patched
`~/.claude/statusline.py`. It waits until `resets_at`, then un-pauses each
flagged pane with `tmux send-keys` — but only if the pane still looks paused (a
frozen screen, unchanged since the pause), so it never types into active work
and never misses a pane whose message got buried by UI chrome. See
**[PLAN.md](PLAN.md)** for the full design.

## Status

**Built and in daily use.** Detection and resume are validated end-to-end
against scratch tmux panes painted with real pause screens: false-positive
vetoes (limit phrase or quoted choice menu in a conversation), the pause message
buried under a todo checklist or scrolled off-screen entirely, hand-resumed
panes skipped, idle panes never injected, sleep/wake, cancel, native
passthrough, per-dir windows. One item still needs a real limit to finalize —
see **PLAN.md §9**: confirming `CCAR_RESUME_TEXT` un-pauses claude and whether a
menu needs `CCAR_RESUME_PREKEYS`.

## One-time setup

```bash
./install.sh
```

The installer is idempotent and 100% local (it installs nothing from the network
and never auto-installs system packages). It: checks for `tmux`/`python3` and
reports if missing; `chmod +x bin/*`; copies `config.example.sh` → `config.sh` if
absent (never clobbers); creates `~/.claude/autoresume{,/panes}` at `0700`; applies
the fail-soft status-line patch to `~/.claude/statusline.py` (keeps a `.bak`, skips
if already applied, falls back to printing manual steps if it can't find the parse
anchor); and adds the `claude` alias to `~/.bashrc` (skipped if already present, or
with `CCAR_NO_ALIAS=1`). Override `CLAUDE_DIR`/`BASHRC` to install elsewhere. Then
open a new shell (or `source ~/.bashrc`).

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

### Remote-control watchdog (opt-in)

Claude Code's **Remote Control** already recovers from the disconnects you'd
expect, and this repo does not duplicate any of it — turn on *"Enable Remote
Control for all sessions"* (`/config`, or `"remoteControlAtStartup": true`) and
every session connects itself, including panes the monitor resumes; the bridge
also rebuilds its own transport after a laptop sleep or a network blip.

What none of that covers is the state *after* Claude Code's internal recovery is
exhausted: the `/rc active` indicator vanishes from the footer and its own advice
is to run `/remote-control` again by hand — which nobody does at 3am. Set
`CCAR_RC_ENABLE=1` and the monitor re-types that command for you, and nothing
else. It only ever types into a pane it can prove is idle: an input box that is
present and **empty**, a screen byte-identical two seconds apart (a session
mid-turn repaints its timer every second), no rate-limit UI, and no rate limit
latched. Attempts back off per pane (1, 2, 4, 8, 16, 30, 60 minutes, then hold),
and any sighting of the indicator resets that. Panes too narrow to fit the
indicator are skipped rather than guessed about, since Claude Code hides it there.

```bash
tests/rc_watchdog_test.sh   # screen-reading helpers, no tmux
tests/rc_watchdog_e2e.sh    # rc_check driven against scratch tmux panes
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

### Working-vs-idle glyph

Claude Code emits the same title glyph (`✳`) whether a session is parked at the
prompt or burning tokens, so a window list of several sessions can't tell you
which ones are actually running. The monitor closes that gap and renders a
working session as Claude's own spinner, ping-ponging `· * ✢ ✶ ✽ ✻` and back:

```
1:✽ adbconnect          <- running
2:✳ rotblock            <- idle at the prompt
3:🌒 notes              <- subagent dispatched
```

**Detection keys on colour, not on the glyph or the wording.** A finished turn
leaves a spinner-*shaped* line on screen — `✻ Cooked for 24m 49s` — so matching
the glyph reads every parked session as working. What separates them is that
Claude paints the glyph in an active colour while the turn runs and in grey once
it ends. The verb pulses through several shades but the glyph's colour is
stable, so the glyph is what `CCAR_BUSY_REGEX` matches, against a
`capture-pane -pe`. The wording is no help: it's randomised per turn
("Processing…", "Beboppin'…", "Doodling…") and one genuinely active state,
`✻ Waiting for 1 background agent to finish`, is shaped exactly like the
completion line. Re-derive the colour for another theme with:

```
tmux capture-pane -pe -t <pane> | grep -aE $'^\033\[' | cat -v
```

The result is published as the window option `@ccar_busy`, and the monitor
patches `window-status-format` to swap a *leading* `✳` for the current frame
(`@ccar_spin`). The swap only fires on a leading `✳`, so any other glyph Claude
puts in the title — the moon phases it ticks while a subagent runs — is left
alone rather than having a spinner prepended to it, keeping dispatch
distinguishable from a plain in-session turn.

Frames advance during the monitor's poll sleep: one batched `set-option ;
refresh-client -S` per *server* per frame, not per working pane. When nothing is
working it falls back to a plain sleep, so an all-idle box is exactly as quiet as
it was before. Raise `CCAR_BUSY_ANIM_MS` (default 400) to slow it down; set it to
`0`, or list a single glyph in `CCAR_BUSY_GLYPHS`, for a static indicator.

The format is patched on whichever tmux server your panes live on (yours as
often as the `ccar` fallback), which is why it isn't shipped in this repo's
`tmux.conf`. Only the `#W` / `#{window_name}` already in your format is
rewritten, so any customisation survives; if your format names no window at all
it logs a line and leaves it alone. The pre-patch value is stashed in
`@ccar_orig_window-status-format`, so changing `CCAR_BUSY_NAME_FORMAT` and
restarting the monitor re-derives from the original rather than patching a patch.

Set `CCAR_BUSY_REGEX=""` to switch the whole thing off.

## Security

No network calls outside `claude`→Anthropic. No deps beyond bash + tmux + python
stdlib. send-keys is guarded by a foreground check so it can never inject into a
shell. State files are `0600` in a `0700` dir and gitignored. Full requirements in
PLAN.md §7.
