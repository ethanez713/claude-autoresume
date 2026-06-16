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
# Authoritative detection: the account is treated as rate-limited when the status
# line's five-hour used_percentage (in state.json) is at/above this. This both
# triggers detection AND vetoes false positives from a session that merely shows
# the limit phrase on screen (e.g. a conversation about rate limits).
CCAR_LIMIT_PCT=95
# Fallback only (when state.json has no usage data): match CCAR_DETECT_REGEX
# against just the last N visible lines of a pane, so a mention of the phrase up
# in the scrollback isn't mistaken for a live pause at the bottom of the screen.
CCAR_DETECT_TAIL_LINES=15

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

# --- cancel ------------------------------------------------------------------
# tmux prefix-table key that stops retrying (press: YOUR prefix, then this key,
# e.g. backtick then X if your tmux prefix is backtick).
CCAR_CANCEL_KEY="X"

# --- logging -----------------------------------------------------------------
CCAR_LOG="$CCAR_STATE_DIR/monitor.log"
