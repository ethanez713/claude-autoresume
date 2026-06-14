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

## 4. Detection (`detect_limited`)

The account is limited per the authoritative status-line usage; on-screen text is
secondary. When limited, **every** claude pane is returned for resuming.

```
panes := all panes whose pane_current_command ∈ CCAR_FOREGROUND_CMDS (claude/node)
used  := state.json.used_percentage
if used is known:
    limited  ⇔  used ≥ CCAR_LIMIT_PCT (default 95)   # authoritative; ignore text
else:                                                # no usage data → fallback
    limited  ⇔  any pane's last CCAR_DETECT_TAIL_LINES *non-blank* lines
               match CCAR_DETECT_REGEX                # bottom-anchored
if limited: resume ALL claude panes
```

Why this shape (both learned from a live test):
- **Usage gate kills false positives.** A session that merely *displays* the limit
  phrase (e.g. a conversation about rate limits) used to send the monitor into a
  bogus multi-hour wait. The `used < CCAR_LIMIT_PCT` veto stops that.
- **Resume-all stops sessions being left behind.** Per-pane text matching missed
  panes whose message had scrolled out of the viewport. Since the limit is
  account-wide, once limited we resume every claude pane regardless of what's
  visible.
- The fallback is anchored to the last *non-blank* lines because `capture-pane`
  pads to full pane height with blank rows (a naive `tail` grabs only blanks).

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
~10s of wake (and logs the clock jump). Holds across a WSL freeze/thaw; a full WSL
teardown kills tmux+monitor and is out of scope for an in-tmux mechanism.

**Countdown.** `status-right` shows `⏳ resume HH:MM (in Xm)` (reset path) or
`⏳ retry in Xm` (backoff), cleared on resume/cancel.

After the wait, re-evaluate, then `send_resume` (optional `CCAR_RESUME_PREKEYS`,
**clear the input** via `CCAR_RESUME_CLEAR`, then literal `CCAR_RESUME_TEXT`, then
Enter) to each still-limited pane; grace re-check escalates backoff if still
limited.

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
· single account-wide monitor with usage-gated detection, resume-all, compute_wait
+ sleep/wake safety, countdown, backoff · cancel chord · private-socket rendering
fixes + tab-title forwarding · README + `~/.bashrc` alias. All dry-run validated
(detection FP-veto / usage-trigger / viewport-independent resume / bottom-anchored
fallback / multi-pane resume-all / sleep-through / cancel / passthrough / per-dir
windows). The real pause message is
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
