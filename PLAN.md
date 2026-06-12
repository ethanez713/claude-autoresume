# claude-autoresume — implementation plan

> **For the implementing Claude instance:** this file is the spec. Read it top to
> bottom, then work the TODO checklist in §9. The human operator will **manually
> trigger a real 5-hour rate limit** so you can observe the live pause screen —
> §6 is the empirical capture step that finalizes the two version-dependent
> values (detection regex + resume keystrokes). Everything is **100% local**: the
> only process that touches the network is `claude` itself talking to Anthropic.
> The monitor and the status-line patch make **zero network calls** — keep it that way.

---

## 1. Goal / behavior spec

A long, walk-away interactive Claude Code session must survive a 5-hour rate
limit with no human present:

1. When *any* prompt/turn hits the limit, the TUI **pauses in place** (it does
   **not** exit — confirmed by the operator). Detect that pause automatically;
   the operator does not know in advance which prompt will trip it.
2. Show a visible **"auto-resuming at HH:MM"** countdown (in the tmux status bar)
   when a concrete reset time is known; otherwise a **"retrying in Xm"** countdown
   on a **2 → 4 → 8 → 16 → 30-minute backoff, capped at 30m**.
3. When the window resets, **resume the interrupted workflow in place** by sending
   the literal text `continue the above workflow` + Enter into the paused session
   (same conversation, same context — no relaunch, no `--resume`).
4. Provide a **stop-retrying** key chord (default **Ctrl-b then X**).

## 2. Architecture & the key insight

Two facts make this clean:

- **The TUI pauses in place, it does not exit.** A normal wrapper has nothing to
  react to. **tmux is the handle**: run `claude` inside a tmux pane, read it with
  `tmux capture-pane`, drive it with `tmux send-keys`. This is the technique every
  working project (claude-auto-retry, autoclaude, amux) uses.
- **The reset time is already a structured signal.** `~/.claude/statusline.py`
  receives, on stdin from Claude Code, `rate_limits.five_hour.resets_at` — a Unix
  timestamp (see that file, lines ~70-75). We **piggyback on the status line**:
  patch it to also dump `rate_limits` to a state file every render. The monitor
  reads `resets_at` from there. This avoids the brittle "parse 'resets 3pm' from
  TUI text with TZ/DST math" that the other projects wrestle with.

```
┌─ tmux session "cc" ───────────────────────────────┐
│  pane 0: claude (native TUI, runs normally)        │
│            │ capture-pane (read)  ▲ send-keys (write)
│            ▼                      │                │
│  monitor.sh  ── reads ──►  state.json (resets_at)  │
└────────────────────────────────┬──────────────────┘
        ▲ writes every render     │
   ~/.claude/statusline.py (patched, additive, fail-soft)
```

**Detection vs. timing are separated on purpose:**
- *Detect the pause* from the pane text (authoritative for "paused right now").
- *Decide how long to wait* from `state.json:resets_at` (authoritative for "when").
- Fall back to pane-text time parsing, then to backoff, only if `resets_at` is missing.

## 3. Components to build

### 3a. Status-line patch (one-time, additive, fail-soft)
Modify the global `~/.claude/statusline.py` so that, in addition to printing the
status line, it writes the rate-limit block to the state file. Requirements:
- **Additive & fail-soft:** wrap in `try/except: pass`. statusline.py runs on
  every render — if our code ever raised, it would blank the user's status bar.
  It must never raise and never slow the status line down.
- Write atomically (`tmp` file + `os.replace`) to `$CCAR_STATE_JSON`.
- Dump at least: `{"resets_at": <int|null>, "used_percentage": <num|null>,
  "captured_at": <now_epoch>}` from `data.get("rate_limits",{}).get("five_hour")`.
- Create `$CCAR_STATE_DIR` with mode `0700` and the file `0600` if missing.
- **Keep a backup** of the original statusline.py before editing (`statusline.py.bak`).
- The state dir path must match `config.sh` (default `~/.claude/autoresume`).

### 3b. Launcher (`bin/cc-run`)
Starts a watched session:
- Create tmux session `$CCAR_TMUX_SESSION` (detached if not present), one pane for claude.
- Launch claude in that pane with a **pinned session id**: `claude --session-id "$(uuidgen)"`
  (record the id to `$CCAR_STATE_DIR/session_id` for an optional fallback relaunch path).
- Record the claude **pane id** (`tmux display-message -p '#{pane_id}'`) to
  `$CCAR_STATE_DIR/pane` so the monitor targets it unambiguously.
- Start `monitor.sh` in the background (or a second pane).
- Register the cancel key-binding (§3d).
- `attach` the operator to the session.

### 3c. Monitor (`bin/monitor.sh`) — the core loop
Polls every `$CCAR_POLL_SECONDS`:

```
loop:
  if cancel sentinel exists: clear status, log "cancelled", remove sentinel, idle until next launch
  pane := read $CCAR_STATE_DIR/pane
  screen := tmux capture-pane -p -t "$pane" -S -50
  if screen matches $CCAR_DETECT_REGEX:        # paused at limit
     target := compute_wait()                  # see §7
     show_countdown_until(target)              # set tmux status-right; re-check cancel each tick
     if cancelled during wait: continue loop
     if not foreground_is_claude(pane): log + skip   # never inject into a shell
     send_resume(pane)                         # PREKEYS, then -l TEXT, then Enter
     sleep grace (~15s); re-capture:
        still limited? -> escalate backoff and wait again
        cleared?       -> clear status, log "resumed", reset backoff index
  sleep $CCAR_POLL_SECONDS
```

`foreground_is_claude`: `tmux display-message -p -t "$pane" '#{pane_current_command}'`
must be in `$CCAR_FOREGROUND_CMDS` (claude is a node process → typically `node`).

`send_resume`: `[ -n PREKEYS ] && tmux send-keys -t "$pane" $PREKEYS` ; then
`tmux send-keys -t "$pane" -l "$CCAR_RESUME_TEXT"` ; then `tmux send-keys -t "$pane" Enter`.
(`-l` sends the text literally so it is never interpreted as key names.)

### 3d. Cancel mechanism (`bin/cc-cancel`)
- `cc-cancel` simply `touch`es `$CCAR_STATE_DIR/cancel`.
- Launcher binds it in tmux's **prefix table** (not root, to avoid clobbering
  claude's own input): `tmux bind-key "$CCAR_CANCEL_KEY" run-shell '<abs path>/cc-cancel'`.
- Operator presses **prefix then the key** (default **Ctrl-b X**) to stop retrying.
- Monitor removes the sentinel after acting so it's one-shot.

## 4. One-time setup (document in README; implementer performs/verifies)

1. **Install tmux** if absent (`tmux >= 2.1`). Do **not** auto-install silently —
   the operator runs the install; just check and instruct.
2. `cp config.example.sh config.sh` and review values.
3. `mkdir -p ~/.claude/autoresume && chmod 700 ~/.claude/autoresume`.
4. Apply the status-line patch (§3a); confirm `statusline.py.bak` exists and the
   status bar still renders normally.
5. `chmod +x bin/*`.
6. (Optional) add `bin/` to PATH or alias `cc-run`.

## 5. Config

All tunables live in `config.sh` (see `config.example.sh` for the annotated list).
The two values that **must be finalized from the live limit** (§6) are
`CCAR_DETECT_REGEX` and `CCAR_RESUME_PREKEYS`/`CCAR_RESUME_TEXT`.

## 6. Empirical capture (operator triggers the real limit — do this live)

The other projects disagree on the exact resume keystrokes (`continue` alone vs.
`Escape→continue→Enter` vs. selecting a menu "option 1"), because it depends on
what the TUI renders. When the operator hits the real limit, capture ground truth:

```bash
# with claude paused at the limit inside the cc session:
tmux capture-pane -p -S -80 > state/limit_screen.txt   # exact pause text + any menu
cat ~/.claude/autoresume/state.json                    # confirm resets_at is present & sane
```

From `limit_screen.txt` finalize:
- **`CCAR_DETECT_REGEX`** — a stable substring of the pause screen.
- **Resume sequence** — if a menu is shown, set `CCAR_RESUME_PREKEYS` to whatever
  dismisses/selects it (e.g. `Escape` or `1`), then `continue the above workflow`.
- Confirm `state.json.resets_at` matches the time shown on screen (sanity-check the
  whole piggyback path end to end).

## 7. Wait-time logic (`compute_wait`)

Priority order:
1. **`state.json:resets_at`** present and in the future → `target = resets_at + CCAR_RESET_MARGIN_SECONDS`. Reset backoff index. *(normal path)*
2. Else parse an `HH:MM`/`H[:MM]am/pm` from the pane; resolve to the next future
   epoch (bare times roll over midnight; full datetimes are used as-is).
3. Else **backoff**: take the next value from `CCAR_BACKOFF_MINUTES` (2,4,8,16,30),
   holding at 30; `target = now + step`.

Countdown display: `tmux set -t "$CCAR_TMUX_SESSION" status-right` to
`⏳ resume HH:MM (in Xm)` (path 1) or `⏳ retry in Xm` (path 3), refreshed each tick.
Clear `status-right` on resume/cancel.

## 8. Security / governance requirements (non-negotiable)

- **100% local.** Monitor + status-line patch make no network calls. Only `claude`
  egresses, to Anthropic. No telemetry, no phone bridges, no third-party services.
- **No third-party code or deps.** bash + tmux (system) + python **stdlib** only.
  Do not `npm install` anything, do not adopt the existing projects' code — we are
  reimplementing the technique, not importing their supply chain.
- **send-keys safety:** always verify `pane_current_command` is claude/node before
  sending; only ever send the configured resume sequence; target the recorded pane
  id, never a guessed one. This prevents injecting `continue⏎` into a shell.
- **Fail-soft status-line patch:** wrapped in try/except; can never break or slow
  the global status bar; original backed up.
- **File hygiene:** state dir `0700`, files `0600`; everything under `state/` and
  `~/.claude/autoresume` is gitignored / outside the repo. Log no secrets (there
  are none here, but don't dump full pane contents to the log either — log events,
  not screens).
- **No silent installs.** tmux presence is checked and reported; the operator installs.

## 9. TODO (work in order)

- [ ] Read `~/.claude/statusline.py`; back it up to `statusline.py.bak`.
- [ ] Implement the additive, fail-soft state-dump patch (§3a). Verify the status
      bar still renders and `state.json` appears with `resets_at` once a session has run a bit.
- [ ] `config.sh` from the example; create `~/.claude/autoresume` (0700).
- [ ] `bin/cc-run` launcher (§3b): tmux session, pinned `--session-id`, record pane id, start monitor, bind cancel key, attach.
- [ ] `bin/monitor.sh` core loop (§3c) with detection, `compute_wait` (§7), countdown, foreground check, send_resume, grace re-check, backoff escalation.
- [ ] `bin/cc-cancel` + tmux prefix-table binding (§3d).
- [ ] Dry-run validation **without** a real limit (§10).
- [ ] **Live:** operator triggers the limit → §6 capture → finalize `CCAR_DETECT_REGEX`
      + resume keystrokes in `config.sh` → confirm full auto-resume end to end.
- [ ] README with the §4 setup steps and usage.

## 10. Testing / validation

**Without a real limit (do first):**
- **Fake pause:** print a line matching `CCAR_DETECT_REGEX` into the claude pane (or
  point the monitor at a scratch pane echoing the limit text) and confirm: detection
  fires, countdown renders in the status bar, `send_resume` targets the right pane,
  and the foreground guard blocks sending when the pane is a bare shell.
- **resets_at path:** hand-write a `state.json` with `resets_at = now+90s`; confirm
  the monitor waits to that time + margin, not the backoff.
- **Backoff path:** remove `resets_at`; confirm 2→4→8→16→30 escalation and 30m cap.
- **Cancel:** trigger a wait, press prefix+X, confirm retry stops, status clears,
  sentinel is consumed, session left paused.
- **Foreground guard:** confirm no keys are sent when `pane_current_command` is `bash`.

**With the real limit (operator-triggered):** §6 capture, then confirm the session
actually resumes the interrupted workflow on its own when the window resets.

## 11. Open questions to resolve at the live limit

- Does the pause render a **menu** (needing PREKEYS) or a bare paused turn?
- Does Claude Code keep invoking the status line **while paused** (so `resets_at`
  stays fresh)? Even if it stops, the last-written `resets_at` is a fixed future
  timestamp and remains correct — note which behavior you observe.
- Exact `pane_current_command` value for the claude pane (confirm it's `node`).
