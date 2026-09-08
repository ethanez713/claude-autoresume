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
cc-attach             # get back to the fallback session (see below)
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

### Getting back to the fallback session

A detach costs you nothing — the server keeps running and `cc-attach` walks back
in, with the same `TERM` override the launcher uses (a hand-rolled `tmux -L ccar
attach` renders the TUI with the shell's `screen-256color` and garbles it).

A reboot or a `wsl --shutdown` is different: tmux keeps no session state on disk,
so the windows are gone for good. The conversations are not — Claude Code files
those under `~/.claude/projects/` — and the pane registry outlives the server, so
it still names every directory that had a window. `cc-attach` reads it, shows
what it would reopen and which of those have a conversation to continue, and asks
before it builds anything:

```
No tmux server on socket 'ccar' — session 'cc' is gone.

Reopen 2 window(s):

  1  /home/you/rotblock   claude -c — continues the last of 7 conversation(s)
  2  /home/you/notes      claude — no saved conversation here, starts fresh

Scrollback and any unsent input from the old session are not recoverable.

Reopen 2 window(s)? [y/N]
```

`-y` skips the prompt. Panes you started inside your own tmux are listed in the
same registry but are never reopened by this — it rebuilds the `ccar` fallback
session and nothing else.

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

Everything under `tests/` runs standalone and needs no account: the `_test.sh`
files are pure functions, the `_e2e.sh` ones drive scratch tmux servers with a
stub `claude` on `PATH`.

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
otherwise swallows the app's OSC title into the pane title. The monitor rewrites
that title too, so the tab and the taskbar sparkle while any session works (see
below). (If Windows Terminal doesn't update, check the profile's "Suppress title
changes" isn't enabled.)

### Working-vs-idle glyph

Claude Code emits the same title glyph (`✳`) whether a session is parked at the
prompt or burning tokens, so a window list of several sessions can't tell you
which ones are actually running. The monitor closes that gap and gives each pane
the glyph of the state it is actually in — a working one gets Claude's own
spinner, ping-ponging `· * ✢ ✶ ✽ ✻` and back:

```
1:✽ adbconnect          <- running a turn
2:✳ rotblock            <- idle at the prompt
3:◑ notes               <- idle itself; its subagents are still working
4:⧗ pyfin               <- parked at the limit, waiting for the window to reset
```

**Give a Claude pane's window name a leading `✳`** — that anchor is what the
monitor swaps for the state glyph, and naming windows is your tmux's job, not
this repo's. In your `~/.tmux.conf`:

```tmux
set -g automatic-rename on
set -g automatic-rename-format '#{?#{==:#{pane_current_command},claude},✳ ,}#{b:pane_current_path}'
```

Emit the anchor here rather than lifting it off the terminal title: Claude Code
does put a `✳` in front of its title, but not on every pane in every state, and a
window whose name is missing the anchor gets no glyph at all.

**The signal is hook-driven, not scraped.** `./install.sh` writes six hooks
into `~/.claude/settings.json`, each pointing at `bin/cc-busy-hook <event>`:
`UserPromptSubmit` (a turn started), `Stop` (it ended), `SubagentStart` /
`SubagentStop` (a subagent came or went), `SessionStart` (clears flags stranded
by a previous session in this pane, and tells the monitor hooks are live here),
and `SessionEnd` (drops the pane's state entirely). The first two write a single
`0`/`1` to a per-pane file in `CCAR_BUSY_DIR`; the subagent pair keeps a count
beside it, under an `flock` because a fan-out starts several in the same instant.
The monitor reads both via `read_hook_busy()` and `read_hook_sub()`.

Neither signal is trusted alone, because each is wrong in one direction. The
scrape false-negatives constantly: while a tool call runs, the pane paints the
tool's output where the spinner line would be, so "no spinner" is not evidence
of idleness. The hook false-negatives too: no hook fires when a background-task
notification (a finished subagent, a scheduled wake) resumes a session, so it
can still read `0` from the last `Stop` on a turn that is genuinely running.

So a visible spinner always wins, whatever the hook says; and a hook-set `1` is
cleared only once the pane has held **byte-identical AND spinnerless** for
`CCAR_BUSY_STALE_SECONDS` (20s) — the state an Esc-interrupt or a `kill -9`
leaves behind, since a live turn repaints and a parked one does not. That is the
same frozen-means-parked test `should_resume()` uses on the rate-limit path.

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

### Waiting, and working through someone else

Two more states share the same slot, because "not running a turn" is not the
same as "nothing is happening":

* **Subagents are still working** while the main agent is idle — the session
  finished its turn and handed the job to agents that are still out. `Stop` has
  fired, so every busy signal reads idle; only the hook's subagent count knows
  otherwise. The pane's own subagent panel is no help: it paints a coloured
  spinner the scrape cannot tell apart from a turn of the main agent's own,
  which is exactly why the count decides it. Rendered as a phase cycle
  (`CCAR_SUBAGENT_GLYPHS`, `○ ◑ ● ◐`) rather than a star one, so delegated work
  reads as a different kind of activity and not just another busy session.
* **Parked at the rate limit**, waiting for the window to reset — the pane the
  monitor is about to resume. It is a latch, not a reading, so it outranks every
  other signal: a turn cut off mid-flight never fires `Stop`, and its stranded
  flag must not read as work. Static `⧗` (`CCAR_LIMIT_GLYPH`), because nothing
  is happening and that is the whole message.

The result is published as the window option `@ccar_busy` — `1`, `sub`, `limit`
or `0` — and the monitor patches `window-status-format` to swap a *leading* `✳`
for that state's glyph. The swap only fires on that anchor, so a window without
one — a shell, an editor, anything that isn't a Claude pane — is left exactly as
it is rather than having a glyph prepended to it.

### The same glyph in the taskbar

The window list only helps when you are looking at it. The terminal's own title —
the tab, and the taskbar entry behind every other window — is all you can see of a
session you walked away from, so the monitor splices `CCAR_BUSY_TITLE_FORMAT` into
`set-titles-string` as well (turning `set-titles` on if it was off, since a title
nobody pushes to the terminal can't sparkle).

That title belongs to whichever pane is active, so it can't read the per-window
`@ccar_busy`. It reads `@ccar_any_busy`, which the monitor sets per tmux *server*
to the busiest state among its watched panes. Precedence there is deliberately
not the per-window one — the taskbar answers "is anything still moving", so a
running turn outranks working subagents, which outrank a parked pane. You get the
spinner while anything anywhere is running, whatever window you left in front;
the hourglass once the only thing left is a wait; and a still `✳` when nothing is
happening at all.

The swap fires on the leading `✳` of the *pane* title (`#T`), the one Claude
itself sets. A pane that isn't Claude has no `✳` to swap and stays as it is.

Frames advance during the monitor's poll sleep: one batched `set-option ;
refresh-client -S` per *server* per frame — both cycles in the same call — not
per working pane. When nothing is
working it falls back to a plain sleep, so an all-idle box is exactly as quiet as
it was before. Raise `CCAR_BUSY_ANIM_MS` (default 400) to slow it down; set it to
`0`, or list a single glyph in `CCAR_BUSY_GLYPHS`, for a static indicator.

The format is patched on whichever tmux server your panes live on (yours as
often as the `ccar` fallback), which is why it isn't shipped in this repo's
`tmux.conf`. Only the token already in your format is rewritten — `#W` /
`#{window_name}` in the window list, `#T` / `#{pane_title}` in the title — so any
customisation survives; a format naming neither logs a line and is left alone.
The pre-patch value is stashed in `@ccar_orig_<option>`, so changing
`CCAR_BUSY_NAME_FORMAT` or `CCAR_BUSY_TITLE_FORMAT` and restarting the monitor
re-derives from the original rather than patching a patch.

Set `CCAR_BUSY_TITLE_FORMAT=""` to leave the terminal title alone, or
`CCAR_BUSY_REGEX=""` to switch the whole thing off.

### Cost

Measured on this box (one bash loop, no daemon, no network), as a share of one core:

| state | cost |
|---|---|
| walked away / detached | **~1.1%** |
| attached, everything idle | ~1.1% |
| attached, a session working (animating) | ~4.3% |

The idle case is the one that matters — this tool exists for sessions you walk
away from — and three things keep it cheap. **Nothing paints when no client is
attached:** the colour capture and the animation are both skipped for a server
nobody is looking at. **The scan interval is decoupled from the indicator:**
`CCAR_POLL_SECONDS` (15s) governs only limit detection, which needn't be quick —
the resume fires at the reset time read from `state.json`, not at poll
granularity — while `CCAR_BUSY_REFRESH_MS` (2s) keeps the glyph fresh for a
fraction of the cost. And **one registry walk serves the whole poll:** asking
"which panes are alive and running claude" costs two tmux round-trips per pane,
and three different consumers used to ask independently.

To trim further: raise `CCAR_BUSY_REFRESH_MS` (the dominant remaining cost when
attached), raise `CCAR_POLL_SECONDS`, raise `CCAR_BUSY_ANIM_MS` (or `0` for a
static glyph), or set `CCAR_BUSY_REGEX=""` to drop the indicator and sit at the
floor.

### Resource heartbeat

Every `CCAR_STATS_SECONDS` (300) the monitor appends one JSON line to
`stats.jsonl` in the state dir — its CPU over the window, including every child
it reaped, alongside the shape it was running against:

```json
{"ts":"…","window_s":15,"cpu_ms":650,"cpu_pct":4.3,"polls":1,"frames":37,
 "registered":8,"claude":7,"busy":3,"sub":1,"servers_attached":1,"latched":0}
```

It's a log, not a dashboard: nothing reads it automatically. The shape fields are
what make a surprising `cpu_pct` actionable rather than merely alarming — a climb
with `registered` climbing is a pane-registry leak, a climb at constant shape is
the monitor itself. Trimmed to half of `CCAR_STATS_MAX_BYTES` when it exceeds it;
`CCAR_STATS_SECONDS=0` turns it off.

```sh
tail -5 ~/.claude/autoresume/stats.jsonl | jq -c '{ts,cpu_pct,claude,busy}'
```

## Security

No network calls outside `claude`→Anthropic. No deps beyond bash + tmux + python
stdlib. send-keys is guarded by a foreground check so it can never inject into a
shell. State files are `0600` in a `0700` dir and gitignored. Full requirements in
PLAN.md §7.
