# claude-autoresume — design & status

> Status: **built and working.** Used daily as a transparent `claude` alias. One
> item still needs a real limit to finalize (§9). This file is the as-built
> reference; the original step-by-step build spec has been folded into the
> summaries below now that the work is done.

Everything is **100% local**: the only process that touches the network is
`claude` talking to Anthropic. The monitor and the status-line patch make **zero**
network calls — keep it that way.

---

## 1. Goal

Be a drop-in `claude` that survives the account rate limit with nobody watching:
when a limit pauses your session(s), wait until the window resets and resume the
interrupted workflow in place — same conversation, same context, no relaunch.
Work across **multiple projects at once**, and behave **exactly like native
`claude`** for everything that isn't an interactive session launch.

## 2. Architecture (as built)

`claude` is aliased to `bin/cc-run`. **Inside tmux** it execs Claude in the current
pane (no new server, no nesting); **outside tmux** it falls back to building the
private `ccar` server and attaching. Both record the pane in a registry; a single
background monitor watches every registered pane and drives resumes.

```
  your tmux server(s)            ccar fallback server (only if launched w/o tmux)
┌─ session: work ───────────┐  ┌─ socket "ccar", session "cc" ──────────┐
│ pane → claude  @ccar_dir  │  │ window /proj  pane → claude  @ccar_dir  │
└─────────────┬─────────────┘  └─────────────┬──────────────────────────┘
              │ register (socket+pane+dir)    │ register
              ▼                               ▼
       ~/.claude/autoresume/panes/  ◄──reads── bin/monitor.sh
         (one file per pane)                    │ capture-pane (read)
                                                ▲ send-keys (resume)
   bin/monitor.sh also reads ──► ~/.claude/autoresume/state.json
        ▲ writes every render    {resets_at, used_percentage, captured_at}
   ~/.claude/statusline.py (patched: additive, fail-soft)
```

Three design decisions carry the whole thing:

- **Run where you are; private socket only as a fallback.** Inside tmux, Claude
  runs in your own pane (the natural place, no nesting). The isolated `ccar`
  server is built only when you launch from a plain shell with no tmux to host it.
  A per-pane **registry** decouples the monitor from any one server, so it follows
  your Claude panes wherever they live.
- **`used_percentage` is the authoritative limit signal, not pane text.** The
  patched status line writes the five-hour `used_percentage` + `resets_at` to
  `state.json`. The monitor gates detection on that number (account-global, can't
  be faked by on-screen text), and uses `resets_at` for *when* to resume. Pane
  text is only a fallback when `state.json` has no usage data.
- **One monitor resumes every pane.** The limit is account-wide, so when it trips
  the monitor resumes **every** registered claude pane — not just one. Panes are
  keyed to their dir by a `@ccar_dir` tmux window option (also used by the
  fallback's window-per-dir reconnect).

## 3. Components (as built)

- **`~/.claude/statusline.py` patch** (`dump_rate_limits`, fail-soft, backup at
  `statusline.py.bak`). On every render writes `{resets_at, used_percentage,
  captured_at}` from `rate_limits.five_hour` to `$CCAR_STATE_JSON`, atomically,
  `0600` in a `0700` dir. Skips the write when `five_hour` is absent so a fresh
  session can't clobber the last good values with nulls.

- **`bin/cc-run`** (launcher / alias target):
  - **Native passthrough** — execs the real `claude` directly (no tmux) for
    headless `-p/--print`, subcommands (`mcp`, `doctor`, `update`, `auth`, …),
    `--version/--help`, or non-TTY stdin. `exec claude` bypasses the alias via
    `execvp` (a script loads no alias anyway).
  - **In-tmux (`$TMUX` set)** — the common path: derive `socket_path`/`pane_id`
    from `$TMUX`/`$TMUX_PANE`, tag the window `@ccar_dir=$PWD`, register the pane,
    bind the cancel chord on **this** server, ensure the monitor is up, then
    `exec claude [--session-id <uuid>] [args]` in the current pane. `exec` only
    replaces cc-run (a child of your shell), so the pane stays and your prompt
    returns when claude exits. No new window, no attach, **no nesting**.
  - **Out-of-tmux fallback** — ensures the private session `cc` exists, opens a
    window per `$PWD` running `exec claude …`, registers that pane too, then
    attaches overriding `TERM` to `$CCAR_OUTER_TERM`. `-c/--continue` reconnects
    to this dir's live window if present; `-r/--resume` opens claude's picker.
    (Reconnect flags don't pin `--session-id`, which claude forbids with them.)
  - Both paths share `register_pane` (writes the registry file) and `start_monitor`
    (pidfile-guarded).

- **`bin/monitor.sh`** (single account-wide watcher) — see §4/§5.

- **Pane registry** (`$CCAR_PANES_DIR`, default `~/.claude/autoresume/panes/`,
  `0700`) — one `0600` file per Claude pane, tab-separated
  `<socket_path>\t<session>\t<pane_id>\t<dir>`, written atomically by `cc-run`.
  It's the contract between launcher and monitor: the monitor reads it (addressing
  each pane's server by socket *path* with `tmux -S`), so it follows panes across
  your own server and the `ccar` fallback. The monitor prunes a file when its pane
  dies and exits once none remain (`CCAR_IDLE_EXIT_SECONDS` grace).

- **`bin/cc-cancel`** — `touch`es `$CCAR_STATE_DIR/cancel`. Works two ways: run it
  directly from any shell, or press the bound chord (**your prefix then `X`** —
  backtick + X here), which `cc-run` binds on whichever server hosts the pane. The
  monitor consumes the sentinel and exits; the next `claude` launch restarts it.

- **`tmux.conf`** (loaded via `-f` only on the **fallback** `ccar` socket) —
  sources the user's `~/.tmux.conf` (keeps their prefix/mouse/keys), then fixes the
  terminal caps that garble Claude's TUI (`default-terminal tmux-256color`,
  `terminal-features ",*:RGB"`), bumps history, and forwards Claude's title to the
  terminal tab (`set-titles on` / `set-titles-string '#T'`). For the in-tmux path
  the same caps must live in the user's own `~/.tmux.conf` (their server renders
  Claude).

- **`config.sh`** (from `config.example.sh`, gitignored) — all tunables.

## 4. Detection: per-pane latch + evidence-gated resume

Detection is a **per-pane latch**, not a point-in-time text match. The monitor
separates the two questions that used to be conflated — *"did this pane hit the
limit?"* (answered eagerly, latched) and *"is it still paused right now?"*
(answered at reset time, from evidence) — so a false positive and a false
negative are guarded independently.

**Latching** (every poll, and every ~10s during a wait), per claude pane
(`pane_current_command ∈ CCAR_FOREGROUND_CMDS`):

```
latch := seen   if we answered its rate-limit choice prompt, or the pause
                message is anywhere on its FULL visible screen
      |  usage  if the account usage signal reads limited and the pane
                showed nothing itself (limit is account-wide)
snap  := hash of the screen when the pane last looked paused (a snapshot
         taken without text evidence is provisional until two consecutive
         scans agree — a latch can fire while a pane is still painting)
```

**Usage signal validity.** The status line only writes `state.json` while a
session renders it, so the file goes stale exactly when everything is paused
(that staleness once kept re-triggering detection in a 5s busy-loop after the
window had already reset). A reading is interpreted only inside its window:

```
limited — used ≥ CCAR_LIMIT_PCT and its own resets_at is still in the future
clear   — used < CCAR_LIMIT_PCT and captured within CCAR_USAGE_FRESH_SECONDS
unknown — anything else (missing/unpatched/stale) → per-pane evidence only
```

`clear` vetoes both the text latch and the choice-prompt answer — that is what
stops a conversation merely *displaying* the limit phrase (or quoting the menu)
from triggering key injection. `limited` latches every claude pane.

**Resume gate** (at reset time, per latched pane). Resume when:
- the pause message is on the visible screen **and** the screen is static
  (double-capture `CCAR_SETTLE_SECONDS` apart — a paused TUI is frozen, active
  work repaints every second); or
- the screen is byte-identical to the pause snapshot; a `usage`-only latch
  additionally needs the message within `CCAR_DETECT_HISTORY_LINES` of recent
  history, so an idle pane that was never interrupted is not injected.

Anything else means the pane changed since it paused (user typed, resumed by
hand) — skip it rather than inject into work we can't see.

Why this shape (all learned from live limits):
- **The old post-wait confirmation was bottom-anchored to the last 15 non-blank
  lines and a todo checklist pushed the pause message above it** — the monitor
  skipped genuinely paused panes ("resumed by hand?") every 5s for hours. The
  latch + full-screen/history matching fixes that class of miss; the frozen-
  screen check replaces the brittle text re-find as the "still paused" test.
- **Usage gate kills false positives** — but only while the reading is valid;
  trusting a stale ≥95 re-triggered detection forever, and a fresh sub-limit
  reading is the veto that lets dev sessions *about* this project display the
  pause phrase safely.
- **The latch is the resume set.** A pane opened during the wait never latches
  (no evidence), so it is never injected; a latched pane that died is dropped.
  Latches live in memory only — a restarted monitor re-derives them from the
  pause screens, which stay painted until something is sent to the pane.

## 5. Wait logic (`compute_wait`) + sleep/wake safety

Priority:
1. **`state.json:resets_at`** present:
   - future → `target = resets_at + CCAR_RESET_MARGIN_SECONDS`;
   - already passed, first try (`backoff_idx==0`) → **resume now** (slept through
     the reset — window is open);
   - passed and already retried → **backoff** (don't busy-resume a stale ts).
2. Else parse a clock time off the pane (timezone-aware if the message carries
   one, e.g. `(America/New_York)`) → next future epoch.
3. Else **backoff**: `CCAR_BACKOFF_MINUTES` (2,4,8,16,30), hold at 30.

**Sleep/wake.** Any target beyond `now + CCAR_MAX_WAIT_SECONDS` (6h, longer than a
session window) is collapsed to an immediate resume, so a stale/rolled-over time
can't strand a session ~24h. `wait_until` waits on the absolute epoch and re-reads
the wall clock every ~10s, so a suspend that overshoots the target fires within
~10s of wake (and logs the clock jump). A full WSL teardown kills tmux+monitor and
is out of scope for an in-tmux mechanism.

**Clock reconciliation.** Re-reading the wall clock only helps if the clock is
*right*: on WSL2 the guest clock can freeze in the past across a host sleep and
re-sync lazily, so `date +%s` reads BEHIND true wall time after a resume —
inflating every `target - now` and painting a wrong countdown. The monitor
therefore reconciles its notion of "now" against an external true-time source
(`CCAR_HOST_TIME_CMD`, the Windows host clock by default — local, no network) and
carries the difference as `clock_offset`, added to every `date +%s` via
`now_epoch`. It does **not** touch the system clock (that needs root); correcting
only "now" suffices because `resets_at` is an absolute server epoch. Cadence is
rate-limited per-interaction: every poll/wait pass calls `reconcile_clock`, but it
only re-queries the host once per `CCAR_CLOCK_RESYNC_SECONDS` (10m) of RAW elapsed
time — except a detected suspend jump in `wait_until` forces an immediate
re-query, since that is exactly when the guest clock has likely jumped. Set
`CCAR_HOST_TIME_CMD=""` to disable (offset stays 0 ≡ plain `date`), e.g. on native
Linux where `systemd-timesyncd` already keeps the clock honest.

**Countdown.** `status-right` shows `⏳ resume HH:MM (in Xm)` (reset path) or
`⏳ retry in Xm` (backoff), cleared on resume/cancel.

After the wait, each latched pane goes through the resume gate (§4), then
`send_resume` (optional `CCAR_RESUME_PREKEYS`, **clear the input** via
`CCAR_RESUME_CLEAR`, then literal `CCAR_RESUME_TEXT`, then Enter); the grace
re-check keeps the latch and escalates backoff for any pane whose screen still
shows the pause message.

**Why clear first (learned from a multi-pane resume).** The same `send_resume`
went to four panes; three submitted `continue the above workflow`, but one
submitted `/resume the above workflow` — Claude ran it as a slash command and it
failed. The config text is slash-free, so the slash came from *that pane's input
state*: residual content (a stale `/resume`) plus the leading chars of our send
being dropped while the TUI was mid-render. `send_resume` now clears the input box
before typing and strips any leading slash, so the submitted line is always the
plain resume prompt regardless of what was sitting in the box.

## 6. Native compatibility

The alias is transparent: non-interactive `claude` (print mode, subcommands,
version/help, piped stdin) behaves exactly like the real CLI (§3 passthrough).
Multiple concurrent projects each get their own window; `--continue`/`--resume`
are honored per-dir. Plain `claude` always starts a fresh conversation, like
native.

## 7. Security / governance (non-negotiable)

- **100% local.** Monitor + status-line patch make no network calls. Only `claude`
  egresses, to Anthropic. No telemetry, no third-party services.
- **No third-party code/deps.** bash + system tmux + python **stdlib** only.
- **send-keys safety:** only ever send the configured resume sequence, only to
  panes whose `pane_current_command` is claude/node — never inject into a shell.
- **Fail-soft status-line patch:** wrapped in try/except; can never break or slow
  the global status bar; original backed up.
- **File hygiene:** state dir `0700`, files `0600`; everything runtime is
  gitignored / outside the repo. Log events, not screen contents.
- **No silent installs.** tmux presence is checked and reported; operator installs.

## 8. Done

Status-line patch · launcher with passthrough + window-per-dir + alias-safe `exec`
· single account-wide monitor with per-pane latch detection + evidence-gated
resume (§4), compute_wait + sleep/wake safety, countdown, backoff · cancel chord
· private-socket rendering fixes + tab-title forwarding · README + `~/.bashrc`
alias. Validated end-to-end against a scratch tmux server with fake panes:
checklist-below-the-message resume (the live failure), fresh-usage FP veto (text
+ quoted choice menu), hand-resume skip, message-only-in-history resume,
idle-pane non-injection, choice-prompt answer. The real pause message is
`You've hit your session limit · resets 4am (America/New_York)`.

## 9. Open

- **Confirm the resume keystrokes at a real limit.** Detection and multi-session
  resume are solid and tested; what a real limit still needs to verify is that
  `CCAR_RESUME_TEXT` ("continue the above workflow") actually un-pauses claude,
  whether a menu requires `CCAR_RESUME_PREKEYS`, and that `CCAR_RESUME_CLEAR`
  (`C-u`) empties the input on the current build. Capture ground truth when it trips:
  ```bash
  tmux -L ccar capture-pane -p -t cc -S -80 > state/limit_screen.txt
  cat ~/.claude/autoresume/state.json   # used_percentage should read ~100, resets_at sane
  ```
- **Optional hardening:** `cc-run`'s monitor-already-running check trusts the
  pidfile via `kill -0`; a recycled PID could mask a dead monitor. Low value on a
  personal box — pending a decision.

## 10. Operations

- **Restart the monitor after editing `monitor.sh`** — a running bash loop doesn't
  re-read its file. Kill the pid in `~/.claude/autoresume/monitor.pid` and relaunch
  (or end the session and `claude` again).
- Inspect: `tmux -L ccar ls`, `tail -f ~/.claude/autoresume/monitor.log`.
- End everything: `tmux -L ccar kill-session -t cc`.
