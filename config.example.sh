# shellcheck shell=bash
# claude-autoresume configuration. Copy to config.sh and edit. config.sh is gitignored.
# All values are local-only; nothing here is sent anywhere.

# --- tmux topology -----------------------------------------------------------
CCAR_TMUX_SESSION="cc"                 # tmux session name the launcher creates
CCAR_STATE_DIR="$HOME/.claude/autoresume"   # runtime state (0700). Holds pane id, state.json, cancel sentinel.

# --- signal sources ----------------------------------------------------------
# Authoritative reset time, written by the patched statusline.py (see PLAN.md §3a).
CCAR_STATE_JSON="$CCAR_STATE_DIR/state.json"

# --- detection ---------------------------------------------------------------
# Regex (grep -E -i) matched against the captured claude pane to decide "paused at limit".
# FINALIZE against the real pause screen (PLAN.md §6 empirical capture).
CCAR_DETECT_REGEX='(usage limit reached|limit reached.*reset|[0-9]+-hour limit|approaching usage limit)'
CCAR_POLL_SECONDS=5                    # how often to capture-pane while watching

# --- resume action -----------------------------------------------------------
# Keystrokes to un-pause. PREKEYS are sent first (e.g. to dismiss a menu), then TEXT, then Enter.
# Confirm the exact sequence from the real pause screen.
CCAR_RESUME_PREKEYS=""                 # e.g. "Escape"  — leave empty if no menu must be dismissed
CCAR_RESUME_TEXT="continue the above workflow"
CCAR_FOREGROUND_CMDS="node claude"     # pane_current_command must be one of these before we send keys

# --- wait logic --------------------------------------------------------------
CCAR_RESET_MARGIN_SECONDS=30           # wait until resets_at + this margin
# Backoff used ONLY when no resets_at is available (minutes): 2,4,8,16,30 then hold at 30.
CCAR_BACKOFF_MINUTES="2 4 8 16 30"

# --- cancel ------------------------------------------------------------------
# tmux prefix-table key that stops retrying (press: prefix, then this key). Default: Ctrl-b then X.
CCAR_CANCEL_KEY="X"

# --- logging -----------------------------------------------------------------
CCAR_LOG="$CCAR_STATE_DIR/monitor.log"
