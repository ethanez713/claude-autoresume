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
CCAR_STATE_DIR="$HOME/.claude/autoresume"   # runtime state (0700). Holds state.json, cancel sentinel, monitor.pid.
# Pane registry (0700): one file per watched Claude pane, written by cc-run and
# read by the monitor, so the monitor watches your panes across ANY tmux server
# (your own socket and the ccar fallback alike). One file per pane avoids races.
CCAR_PANES_DIR="$CCAR_STATE_DIR/panes"

# --- signal sources ----------------------------------------------------------
# Authoritative reset time, written by the patched statusline.py (see PLAN.md §3a).
CCAR_STATE_JSON="$CCAR_STATE_DIR/state.json"

# --- detection ---------------------------------------------------------------
# Regex (grep -E -i) matched against the captured claude pane to decide "paused at limit".
# Finalized against the real pause screen, which reads:
#   You've hit your session limit · resets 4am (America/New_York)
# We deliberately do NOT match the softer "approaching limit" warning — only the
# actual pause. "session" is the 5-hour window; the on-screen time is just the
# local render of rate_limits.five_hour.resets_at (the authoritative signal).
CCAR_DETECT_REGEX="(hit your (session|usage) limit|usage limit reached|session limit.*reset)"
CCAR_POLL_SECONDS=5                    # how often to poll while watching
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
