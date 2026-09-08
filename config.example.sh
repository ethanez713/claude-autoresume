# shellcheck shell=bash
# claude-autoresume configuration. Copy to config.sh and edit. config.sh is gitignored.
# All values are local-only; nothing here is sent anywhere.

# --- tmux topology -----------------------------------------------------------
CCAR_TMUX_SESSION="cc"                 # tmux session name the FALLBACK launcher creates
# FALLBACK private tmux socket + config, used only when you launch `claude` from
# OUTSIDE tmux: cc-run builds this isolated server so Claude renders correctly and
# the cancel keybinding never touches your normal tmux. Inside tmux, cc-run runs
# Claude in your current pane on your own server instead (no nesting). The config
# sources your ~/.tmux.conf first (you keep your prefix/mouse/etc.) then fixes the
# terminal caps that garble Claude's TUI. Attach manually: tmux -L ccar attach -t cc
CCAR_TMUX_SOCKET="ccar"
CCAR_TMUX_CONF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tmux.conf"
# TERM used for the *outer* attach. Your ~/.bashrc forces TERM=screen-256color on
# every shell, so tmux would render to Windows Terminal with the conservative
# `screen` terminfo — the source of the garbled-scroll / stuck-column artifacts.
# WT is xterm-compatible + truecolor, so we attach as xterm-256color. Set empty
# to keep whatever TERM your shell exports.
CCAR_OUTER_TERM="xterm-256color"
# Resource heartbeat: one JSON line per window with the monitor's CPU (its own
# plus every child it reaped) and the shape it was running against — how many
# panes were registered, running claude, working, and on an attached server. It
# exists to answer "is this costing me battery" without re-deriving it by hand;
# read it with `tail`/`jq`, nothing reads it automatically. 0 disables.
CCAR_STATS_SECONDS=300
CCAR_STATS_MAX_BYTES=262144            # trimmed to half this when exceeded
CCAR_STATE_DIR="$HOME/.claude/autoresume"   # runtime state (0700). Holds state.json, cancel sentinel, monitor.pid.
# Pane registry (0700): one file per watched Claude pane, written by cc-run and
# read by the monitor, so the monitor watches your panes across ANY tmux server
# (your own socket and the ccar fallback alike). One file per pane avoids races.
CCAR_PANES_DIR="$CCAR_STATE_DIR/panes"
# Hook busy-state dir (0700): one file per pane, written by bin/cc-busy-hook on
# every UserPromptSubmit/Stop/SessionStart/SessionEnd and read by the monitor's
# read_hook_busy(). This is the primary @ccar_busy signal; see CCAR_BUSY_REGEX
# below for the fallback.
CCAR_BUSY_DIR="$CCAR_STATE_DIR/busy"

# --- signal sources ----------------------------------------------------------
# Authoritative reset time, written by the patched statusline.py (see PLAN.md §3a).
CCAR_STATE_JSON="$CCAR_STATE_DIR/state.json"
CCAR_STATS_JSONL="$CCAR_STATE_DIR/stats.jsonl"

# --- detection ---------------------------------------------------------------
# Regex (grep -E -i) matched against the captured claude pane to decide "paused at limit".
# Finalized against the real pause screen, which reads:
#   You've hit your session limit · resets 4am (America/New_York)
# We deliberately do NOT match the softer "approaching limit" warning — only the
# actual pause. "session" is the 5-hour window; the on-screen time is just the
# local render of rate_limits.five_hour.resets_at (the authoritative signal).
CCAR_DETECT_REGEX="(hit your (session|usage) limit|usage limit reached|session limit.*reset)"
# How often to run the FULL scan (limit detection, usage state, rc/burn checks).
# This is the monitor's dominant running cost, and it does not need to be quick:
# the resume fires at the reset time read from state.json, not at poll
# granularity, and a pane that hits the limit between polls just waits anyway.
# Measured on one box: 5s costs ~6.4% of a core, 15s ~3.3%. The working-glyph
# indicator is NOT tied to this — see CCAR_BUSY_REFRESH_MS.
CCAR_POLL_SECONDS=15                   # how often to poll while watching
# FALLBACK for @ccar_busy, the window option that says "a turn is running right
# now" (see CCAR_BUSY_DIR above for the primary, hook-driven signal). This regex
# now only drives panes with no hook state (a claude not launched through ccar,
# or hooks not installed) and clears a hook-set 1 that got stranded because Stop
# never fired (Esc-interrupt, crash, kill -9) — see CCAR_BUSY_STALE_SECONDS.
#
# Matched (grep -E) against a claude pane's captured colour output.
#
# This has to key on COLOUR, not on the glyph or the wording. A finished turn
# leaves its own spinner-shaped line on screen — "✻ Cooked for 24m 49s" — so a
# plain-text match on the glyph reads every parked session as working. What
# actually separates them is that the glyph is painted in the active colour while
# the turn runs and in grey (38;5;246, same as the completion line) once it ends.
# The verb pulses through several shades but the GLYPH's colour is stable, so the
# glyph is what we match. Re-derive it for another theme with:
#   tmux capture-pane -pe -t <pane> | grep -aE $'^\[' | cat -v
# The wording is useless here: it is randomised per turn ("Processing…",
# "Beboppin'…", "Doodling…") and one active state ("Waiting for 1 background
# agent to finish") is past-tense-shaped exactly like the completion line.
# Set empty to switch the indicator off.
CCAR_BUSY_REGEX=$'(^\[38;5;174m[✻✽✢✶✳✺✷*·]|esc to interrupt)'
# How long a pane must sit FROZEN with no spinner on screen, under a hook that
# still says "working", before the monitor assumes the session's Stop hook was
# lost (Esc-interrupt, crash) and clears the flag. Both conditions are required:
# "no spinner" alone is not evidence of idleness, because a running tool call
# paints its output where the spinner line would be. A repaint or a spinner at
# any point before this resets the clock.
CCAR_BUSY_STALE_SECONDS=20
# What the window name renders as, per pane state. A Claude pane's window name
# carries a leading ✳ as an anchor (your automatic-rename-format puts it there —
# see the README), and we swap that ✳ for the glyph of the state the monitor
# publishes in @ccar_busy:
#   1      a turn is running                     -> @ccar_spin (current frame)
#   sub    the main agent is idle, subagents are
#          still working                         -> @ccar_sub_spin
#   limit  parked at the rate limit, waiting for
#          the window to reset                   -> @ccar_wait
#   0      idle                                  -> ✳, i.e. unchanged
# The #{m:✳*} guard leaves any window without the anchor — a shell, an editor,
# anything that isn't a Claude pane — exactly as it is. The monitor splices this
# into window-status-format on whichever tmux server your panes live on.
CCAR_BUSY_NAME_FORMAT='#{?#{m:✳*,#{window_name}},#{?#{==:#{@ccar_busy},1},#{@ccar_spin},#{?#{==:#{@ccar_busy},sub},#{@ccar_sub_spin},#{?#{==:#{@ccar_busy},limit},#{@ccar_wait},✳}}}#{s|^✳||:#{window_name}},#{window_name}}'
# The same swap for the terminal's own title — the tab, and the taskbar entry
# that is all you can see of a session whose window isn't in front. That title
# belongs to whichever pane is active, so it cannot key on the per-window
# @ccar_busy; it reads @ccar_any_busy, the busiest state among the watched panes
# on that tmux server. Live work ranks above a parked pane there, so the taskbar
# sparkles while anything anywhere is running, shows the hourglass only when the
# only thing left is a wait, and a ✳ still means nothing is happening at all. The
# monitor splices this into set-titles-string (and turns set-titles on). Set
# empty to leave the title alone.
CCAR_BUSY_TITLE_FORMAT='#{?#{m:✳*,#{pane_title}},#{?#{==:#{@ccar_any_busy},1},#{@ccar_spin},#{?#{==:#{@ccar_any_busy},sub},#{@ccar_sub_spin},#{?#{==:#{@ccar_any_busy},limit},#{@ccar_wait},✳}}}#{s|^✳||:#{pane_title}},#{pane_title}}'
# Frames for that spinner, cycled in order — Claude's own set, so the window list
# animates the way the session itself does. Whitespace-separated; a single glyph
# gives a static indicator.
CCAR_BUSY_GLYPHS='· * ✢ ✶ ✽ ✻ ✽ ✶ ✢ *'
# Frames for the subagent indicator, on the same clock — a phase cycle rather
# than a star one, so delegated work reads as a different KIND of activity at a
# glance and not just a different session. Single-width, unlike the emoji moons
# Claude itself ticks while it dispatches an agent, so the window list can't
# shift a column under it.
CCAR_SUBAGENT_GLYPHS='○ ◑ ● ◐'
# What a pane parked at the rate limit renders as until the monitor resumes it.
# Static on purpose: nothing is happening, and that is the whole message.
CCAR_LIMIT_GLYPH='⧗'
# Milliseconds per frame. Each frame costs ONE tmux call per server that has a
# working pane (set-option + refresh-client, batched), so this is the knob to
# raise if the animation ever shows up in CPU. 0 disables the animation and pins
# the indicator to the first glyph.
CCAR_BUSY_ANIM_MS=400
# How often to re-read which panes are working, independent of the full scan, so
# the indicator stays fresh without paying for a scan. One capture per attached
# pane; panes on a server with no client attached cost nothing at all.
CCAR_BUSY_REFRESH_MS=2000
# The account is treated as rate-limited when the status line's five-hour
# used_percentage (in state.json) is at/above this — but only while the reading
# is inside its validity window (see CCAR_USAGE_FRESH_SECONDS). A valid reading
# at/above triggers a latch on every claude pane; a valid reading below vetoes
# text detection (a conversation merely showing the limit phrase can't latch).
CCAR_LIMIT_PCT=95
# The status line only writes state.json while a session renders it, so the file
# goes stale exactly when everything is paused. A >= CCAR_LIMIT_PCT reading stays
# valid until its own resets_at passes; a below-limit reading is only trusted as
# a veto for this many seconds after captured_at. Outside those windows usage is
# treated as UNKNOWN and detection falls back to per-pane screen evidence.
CCAR_USAGE_FRESH_SECONDS=600
# The pause message is matched against the pane's FULL visible screen (UI chrome
# like a todo checklist can push it well above the bottom lines — that once made
# the monitor skip a genuinely paused pane). For panes latched on account usage
# alone, the resume gate additionally looks for the message within this many
# recent history lines, so a pane whose message scrolled off-screen entirely is
# still resumable while an idle never-interrupted pane is not.
CCAR_DETECT_HISTORY_LINES=60
# Resume safety: a candidate pane showing the pause message is double-captured
# this many seconds apart and must be IDENTICAL (a paused TUI is frozen; active
# work repaints every second) before "continue" is sent into it.
CCAR_SETTLE_SECONDS=2

# --- resume action -----------------------------------------------------------
# Keystrokes to un-pause. PREKEYS are sent first (e.g. to dismiss a menu), then
# the input is CLEARED, then TEXT is typed, then Enter.
# Confirm the exact sequence from the real pause screen.
CCAR_RESUME_PREKEYS=""                 # e.g. "Escape"  — leave empty if no menu must be dismissed
# Keys that empty the input box, sent right before the resume text. This prevents
# residual content in a pane's prompt (a stray "/resume", or our own leading
# characters dropped while the TUI was mid-render) from riding along and changing
# the submitted line — we once saw a pane resume with "/resume the above workflow"
# (run as a slash command, which failed) for exactly this reason. C-u kills the
# line in Claude Code's prompt; set empty to disable clearing. Confirm at a real
# limit that this binding empties the input on your build.
CCAR_RESUME_CLEAR="C-u"
# The resume text MUST be a plain prompt, never a slash command — a leading "/"
# is interpreted by Claude as a command (e.g. "/resume"), not a message. Any
# leading slashes are stripped defensively before sending.
CCAR_RESUME_TEXT="continue"
CCAR_FOREGROUND_CMDS="node claude"     # pane_current_command must be one of these before we send keys

# --- rate-limit choice prompt ------------------------------------------------
# Newer Claude Code interposes a CHOICE prompt the moment the limit is hit, ahead
# of the normal pause screen:
#       What do you want to do?
#     ❯ 1. Stop and wait for limit to reset
#       2. Upgrade your plan
# While it's up it BLOCKS text entry, so a later resume "continue" can't land. The
# monitor answers it the INSTANT it detects the menu (this runs on every poll),
# NOT at the reset window. Because the menu WRAPS, a blind "Up Up" can leave the
# cursor on the wrong option — so instead the monitor STEPS the selection and,
# after each keypress, re-reads the pane to CONFIRM the marker (❯) is on the
# "stop and wait" line before it presses Enter. If it can't get there within
# CCAR_LIMIT_PROMPT_MAX_NAV steps it does NOT confirm (better than picking
# "Upgrade"). Set CCAR_LIMIT_PROMPT_REGEX="" to disable this handling entirely.
CCAR_LIMIT_PROMPT_REGEX="stop and wait for limit to reset"   # identifies the wait-option line
CCAR_LIMIT_PROMPT_MARKER='^[[:space:]]*(❯|>)'   # regex (grep -E) for how the SELECTED menu line is marked
CCAR_LIMIT_PROMPT_NAV_STEP="Up"        # one navigation keypress, sent between position checks
CCAR_LIMIT_PROMPT_MAX_NAV=6            # give up WITHOUT confirming after this many steps (>= number of menu options)
CCAR_LIMIT_PROMPT_CONFIRM="Enter"      # key to confirm once the marker is on the wait option
# The live menu sits at the very bottom of the pane, so the prompt match is
# anchored to the last N non-blank lines — and a fresh below-limit usage reading
# vetoes it too. Both guards exist because the nav keys are the most dangerous
# send (a stray Up into a normal input box recalls history), so a conversation
# that merely QUOTES the menu text must not trigger them.
CCAR_PROMPT_TAIL_LINES=15
# Don't re-answer the same pane more than once per this many seconds: once the
# prompt is dismissed the input box returns, and a stray Up+Enter there could
# resubmit recalled history, so we guard against double-firing across polls.
CCAR_PROMPT_COOLDOWN_SECONDS=15

# --- wait logic --------------------------------------------------------------
CCAR_RESET_MARGIN_SECONDS=30           # wait until resets_at + this margin
# Backoff used ONLY when no resets_at is available (minutes): 2,4,8,16,30 then hold at 30.
CCAR_BACKOFF_MINUTES="2 4 8 16 30"
CCAR_GRACE_SECONDS=15                  # after sending resume, wait this long before re-checking
# The monitor exits once no registered pane is still alive for this long (the
# panes all closed). A short grace avoids exiting during a launch race or cutover.
CCAR_IDLE_EXIT_SECONDS=60
# Safety cap on any single wait. A session reset is always <= ~5h out, so a target
# further away than this means a stale/rolled-over time (e.g. the machine slept
# through the reset and a bare "4am" got parsed as *tomorrow*). When exceeded we
# resume now instead of blocking for hours. The monitor also re-reads the wall
# clock every ~10s while waiting, so a suspend/resume past the reset still fires.
CCAR_MAX_WAIT_SECONDS=21600            # 6 hours

# --- clock reconciliation ----------------------------------------------------
# On WSL2 / some VMs the guest clock can freeze in the past when the host sleeps
# and only re-syncs lazily, so `date +%s` reads BEHIND true wall time after a
# resume — which makes the monitor over-wait (it thinks the reset is further off
# than it is) and paint a wrong countdown. The monitor reconciles its notion of
# "now" against an external true-time source and carries the difference as an
# offset; it does NOT change the system clock (no root needed). resets_at is an
# absolute server epoch, so correcting only "now" is sufficient.
#
# Command that prints the true wall-clock UNIX epoch. Default reads the Windows
# host clock (WSL) — 100% local, no network. Set to "" to DISABLE reconciliation
# (offset stays 0, identical to plain `date`), e.g. on native Linux where
# systemd-timesyncd already keeps the clock honest.
CCAR_HOST_TIME_CMD='powershell.exe -NoProfile -Command "[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()"'
# Reconcile at most once per this many seconds (rate-limited "per interaction"):
# the monitor checks on every poll/wait pass but only re-queries the host when
# this much RAW clock time has elapsed since the last check — except a detected
# suspend jump forces an immediate re-query regardless.
CCAR_CLOCK_RESYNC_SECONDS=600          # 10 minutes
CCAR_CLOCK_DRIFT_WARN_SECONDS=5        # log a correction only when it shifts more than this

# --- cancel ------------------------------------------------------------------
# tmux prefix-table key that stops retrying (press: YOUR prefix, then this key,
# e.g. backtick then X if your tmux prefix is backtick).
CCAR_CANCEL_KEY="X"

# --- logging -----------------------------------------------------------------
CCAR_LOG="$CCAR_STATE_DIR/monitor.log"

# --- burn window (opt-in, off by default) -------------------------------------
# The inverse of a rate limit: the 5h window resets SOON and quota is still
# unspent. That quota expires at the reset, so it is the cheapest moment to run
# something expensive you would otherwise put off. When the monitor sees the
# window open it paints a status-right hint and posts a one-time tmux message;
# pressing YOUR tmux prefix then CCAR_BURN_KEY opens CCAR_BURN_CMD in a new
# window. Reuses the state the limit detector already reads — no extra polling.
#
# Leave CCAR_BURN_CMD empty (the default) and the whole feature stays inert.
CCAR_BURN_ENABLE=0                     # 1 to arm it
CCAR_BURN_LEAD_MINUTES=75              # "soon" = this close to the reset
CCAR_BURN_MAX_PCT=75                   # ...and only while usage is at or below this
CCAR_BURN_KEY="I"                      # prefix + this key launches the command
CCAR_BURN_WINDOW="improve"             # name of the tmux window it opens
CCAR_BURN_CWD="$HOME"                  # working dir for that window; pin it so the run
                                       # never inherits an unrelated project repo
CCAR_BURN_LABEL="♻ improve"            # status-right hint while the window is open
# Runs in a fresh tmux window, interactively, so you can watch and steer it.
# Example (routes through cc-run so the new pane also gets auto-resume):
#   CCAR_BURN_CMD="$HOME/claude-autoresume/bin/cc-run --model opus --effort xhigh '/self-improve'"
CCAR_BURN_CMD=""

# --- remote-control watchdog (opt-in, off by default) -------------------------
# Claude Code's Remote Control already reconnects itself in the cases you'd
# expect, and this watchdog is NOT a replacement for any of it:
#   * turn on "Enable Remote Control for all sessions" (`/config`, or
#     "remoteControlAtStartup": true in ~/.claude/settings.json) and every new
#     session connects on its own — including panes this monitor resumes;
#   * the bridge rebuilds its own transport after a laptop sleep or a network
#     blip, retrying internally before it gives up.
# The one state neither covers is AFTER that internal recovery is exhausted: the
# "/rc active" indicator vanishes from the footer and Claude Code's own advice is
# to run /remote-control again by hand — which nobody does at 3am. This re-types
# that command for you, and nothing else.
#
# It only ever types into a pane that is demonstrably idle: an input box that is
# present and EMPTY, a screen byte-identical CCAR_SETTLE_SECONDS apart (a session
# mid-turn repaints its timer every second), no rate-limit UI on screen, and no
# rate limit latched. If the pane's completion popup swallows the Enter, it
# presses Enter once more — and if the box ends up holding anything other than
# the command it typed, it clears the box and gives up on that attempt.
CCAR_RC_ENABLE=0                       # 1 to arm it
CCAR_RC_COMMAND="/remote-control"      # the long form: less ambiguous than /rc to fuzzy completion
# The footer indicator. Claude Code paints "/rc active" while the bridge is up,
# and truncates it to a bare "/rc" when the pane is too narrow for the word.
CCAR_RC_INDICATOR_REGEX='(^|[[:space:]])/rc([[:space:]]|$)'
# The input line's prompt marker, with anything the line holds after it. Used
# both to prove the box is empty before typing and to read back what landed in it.
CCAR_RC_PROMPT_REGEX='^[[:space:]]*(❯|>)[[:space:]]*'
CCAR_RC_TAIL_LINES=8                   # bottom chrome to search (input box, separator, status, mode line)
# Claude Code HIDES the indicator entirely on a pane too narrow to fit it, so a
# narrow pane can't distinguish "disconnected" from "no room" — those are skipped.
CCAR_RC_MIN_WIDTH=80
CCAR_RC_CHECK_SECONDS=30               # how often to look (the main poll is far faster than this needs)
CCAR_RC_GRACE_SECONDS=120              # indicator must stay missing this long — Claude Code's own reconnect goes first
CCAR_RC_BUSY_RETRY_SECONDS=60          # retry gap when a reconnect was due but the pane wasn't idle (doesn't consume a backoff step)
# Exponential backoff between reconnect attempts, in minutes; holds at the last
# value forever rather than giving up, so a session that was offline for hours
# still recovers on the first poll after the network returns.
CCAR_RC_BACKOFF_MINUTES="1 2 4 8 16 30 60"
