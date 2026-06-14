#!/usr/bin/env bash
# claude-autoresume monitor (PLAN.md §3c) — watches every registered claude pane
# (the registry CCAR_PANES_DIR, written by cc-run, spanning your own tmux server
# and the ccar fallback) for the account-wide rate limit, waits until the window
# resets (resets_at from state.json, else pane-text time, else backoff), then
# resumes every paused session. Detection is gated on the status line's
# used_percentage (authoritative + account-global) so it can't be fooled by a
# session that merely displays the limit text. 100% local: no network, bash +
# tmux + python stdlib.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${CCAR_CONFIG:-$here/config.sh}"

CANCEL_FILE="$CCAR_STATE_DIR/cancel"
backoff_idx=0

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$CCAR_LOG"; }

# A "paneref" is "<socket_path>\t<pane_id>"; address its tmux server with txp.
# cc-run records one registry file per pane (CCAR_PANES_DIR), so the monitor
# follows panes across ANY tmux server — your own socket AND the ccar fallback —
# not just one hardcoded session.
pr_socket() { printf '%s' "${1%%$'\t'*}"; }
pr_pane()   { printf '%s' "${1##*$'\t'}"; }
txp() { local pr="$1"; shift; tmux -S "$(pr_socket "$pr")" "$@"; }  # tmux on paneref's server

pane_alive() { # $1 = paneref: true if the pane still exists on its server
  [ -n "$(txp "$1" display-message -p -t "$(pr_pane "$1")" '#{pane_id}' 2>/dev/null)" ]
}

# Distinct "<socket>\t<session>" among live registered panes — the countdown is
# painted on every session that currently has a watched pane.
live_sessions() {
  local f socket session pane dir
  [ -d "$CCAR_PANES_DIR" ] || return
  for f in "$CCAR_PANES_DIR"/*; do
    [ -e "$f" ] || continue
    IFS=$'\t' read -r socket session pane dir <"$f" || continue
    pane_alive "$socket"$'\t'"$pane" && printf '%s\t%s\n' "$socket" "$session"
  done | sort -u
}
status_set() { # $1 = text
  local socket session
  while IFS=$'\t' read -r socket session; do
    [ -n "$socket" ] && tmux -S "$socket" set-option -t "$session" status-right "$1" 2>/dev/null
  done < <(live_sessions)
}
status_clear() {
  local socket session
  while IFS=$'\t' read -r socket session; do
    [ -n "$socket" ] && tmux -S "$socket" set-option -u -t "$session" status-right 2>/dev/null
  done < <(live_sessions)
}

capture() { txp "$1" capture-pane -p -t "$(pr_pane "$1")" 2>/dev/null; }  # $1 = paneref

foreground_is_claude() { # $1 = paneref
  local cmd c
  cmd="$(txp "$1" display-message -p -t "$(pr_pane "$1")" '#{pane_current_command}' 2>/dev/null)" || return 1
  for c in $CCAR_FOREGROUND_CMDS; do
    [ "$cmd" = "$c" ] && return 0
  done
  return 1
}

read_resets_at() { # prints epoch or nothing
  python3 - "$CCAR_STATE_JSON" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        v = json.load(f).get("resets_at")
    print(int(v) if v else "")
except Exception:
    print("")
PY
}

read_used_pct() { # prints the 5h window used_percentage from state.json, or nothing
  python3 - "$CCAR_STATE_JSON" <<'PY'
import json, sys
try:
    v = json.load(open(sys.argv[1])).get("used_percentage")
    print(v if v is not None else "")
except Exception:
    print("")
PY
}

parse_screen_time() { # $1: pane text; prints next-future epoch or nothing
  # Fallback only — used when the status line gave us no resets_at epoch. The
  # message is like "resets 4am (America/New_York)"; if a tz name is present we
  # interpret the clock time in THAT zone (so it's correct regardless of the
  # machine's timezone), else we fall back to local time.
  python3 - "$1" <<'PY'
import re, sys
from datetime import datetime, timedelta

text = sys.argv[1]

tz = None
mtz = re.search(r'\(([A-Za-z]+/[A-Za-z_]+)\)', text)
if mtz:
    try:
        from zoneinfo import ZoneInfo
        tz = ZoneInfo(mtz.group(1))
    except Exception:
        tz = None

m = re.search(r'\b(\d{1,2})(?::(\d{2}))?\s*([ap]m)\b', text, re.I)
if m:
    hour, minute = int(m[1]) % 12, int(m[2] or 0)
    if m[3].lower() == "pm":
        hour += 12
else:
    m = re.search(r'\b(\d{1,2}):(\d{2})\b', text)
    if not m:
        print("")
        raise SystemExit
    hour, minute = int(m[1]), int(m[2])
if not (0 <= hour <= 23 and 0 <= minute <= 59):
    print("")
    raise SystemExit
now = datetime.now(tz)
t = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
if t <= now:  # bare times roll over midnight
    t += timedelta(days=1)
print(int(t.timestamp()))
PY
}

backoff_target() { # $1 = now epoch; echoes target epoch using current $backoff_idx
  # shellcheck disable=SC2206 — intentional word-split of the configured list
  local -a steps=($CCAR_BACKOFF_MINUTES)
  local i=$backoff_idx
  [ "$i" -ge "${#steps[@]}" ] && i=$((${#steps[@]} - 1))
  echo "$(( $1 + steps[i] * 60 ))"
}

compute_wait() { # $1 = a limited pane's screen text (fallback parse); echoes "<epoch> <mode>"
  local screen="${1:-}" now resets target parsed max
  now=$(date +%s)
  max=$((now + CCAR_MAX_WAIT_SECONDS))

  # 1) Authoritative reset epoch from the status line (timezone-independent). When
  #    present we trust it over any on-screen text.
  resets="$(read_resets_at)"
  if [ -n "$resets" ]; then
    target=$((resets + CCAR_RESET_MARGIN_SECONDS))
    if [ "$target" -gt "$now" ]; then
      # Future reset. Clamp implausibly-distant values (stale/wrong bucket) so we
      # never block for hours; a session reset is always <= ~5h out.
      [ "$target" -gt "$max" ] && { echo "$now capped"; return; }
      echo "$target reset"
    elif [ "$backoff_idx" -eq 0 ]; then
      # Reset time already passed — the classic "machine slept through 4am" case.
      # The window is open now, so resume promptly. If the resume doesn't clear
      # the limit, backoff_idx advances and we drop to backoff below next pass
      # instead of busy-resuming on the same stale timestamp.
      echo "$now reset-passed"
    else
      echo "$(backoff_target "$now") backoff"
    fi
    return
  fi

  # 2) No epoch available: parse a clock time off the pause screen.
  parsed="$(parse_screen_time "$screen")"
  if [ -n "$parsed" ] && [ "$parsed" -gt "$now" ]; then
    target=$((parsed + CCAR_RESET_MARGIN_SECONDS))
    # A bare "4am" parsed after it already passed rolls to *tomorrow* (~24h away);
    # the cap turns that into an immediate resume so a slept-through reset with no
    # epoch doesn't strand the session for a day.
    [ "$target" -gt "$max" ] && { echo "$now capped"; return; }
    echo "$target parsed"
    return
  fi

  # 3) Backoff.
  echo "$(backoff_target "$now") backoff"
}

wait_until() { # $1 = target epoch, $2 = mode; returns 1 if cancelled
  # The target is an ABSOLUTE wall-clock epoch and we re-read the clock every
  # iteration, so a suspend/resume that overshoots the target still fires within
  # one poll (~10s of wake) instead of waiting out a frozen relative timer.
  local target="$1" mode="$2" now remaining mins step before after
  while :; do
    [ -e "$CANCEL_FILE" ] && return 1
    now=$(date +%s)
    remaining=$((target - now))
    [ "$remaining" -le 0 ] && return 0
    mins=$(((remaining + 59) / 60))
    if [ "$mode" = backoff ]; then
      status_set "⏳ retry in ${mins}m"
    else
      status_set "⏳ resume $(date -d "@$target" '+%H:%M') (in ${mins}m)"
    fi
    step=$((remaining < 10 ? remaining : 10))
    before=$(date +%s); sleep "$step"; after=$(date +%s)
    # A sleep that took far longer than asked means the machine suspended; the
    # loop re-reads the clock above so timing is still correct — just note it.
    [ $((after - before)) -gt $((step + 30)) ] && \
      log "wall clock jumped ~$((after - before - step))s during wait (machine likely slept) — re-checking reset"
  done
}

send_resume() { # $1 = paneref
  local p="$1" pane text; pane="$(pr_pane "$p")"
  if [ -n "${CCAR_RESUME_PREKEYS:-}" ]; then
    # shellcheck disable=SC2086 — prekeys are intentionally word-split key names
    txp "$p" send-keys -t "$pane" $CCAR_RESUME_PREKEYS
    sleep 1
  fi
  # Clear any residual content in the input box BEFORE typing. Without this, stale
  # text already in a pane's prompt (e.g. a half-typed "/resume") — or the leading
  # characters of our own send being dropped while the TUI is busy rendering — can
  # ride along, so the submitted line is no longer exactly CCAR_RESUME_TEXT. We
  # observed exactly this: with 4 panes resumed by the same send, one submitted
  # "/resume the above workflow" (the "continue" prefix lost, a stale "/resume"
  # left in place), which Claude then ran as a slash command and failed. Clearing
  # first guarantees the submitted message is the resume prompt and never a slash
  # command. The clear keys are configurable because which binding empties the
  # input is TUI-specific (C-u kills the line in Claude Code's prompt).
  if [ -n "${CCAR_RESUME_CLEAR:-}" ]; then
    # shellcheck disable=SC2086 — clear keys are intentionally word-split key names
    txp "$p" send-keys -t "$pane" $CCAR_RESUME_CLEAR
    sleep 0.3
  fi
  # Belt-and-suspenders: a leading "/" makes Claude treat the line as a slash
  # command, not a prompt. Strip any leading slashes so the resume text is always
  # submitted as a plain message even if CCAR_RESUME_TEXT is misconfigured.
  text="$CCAR_RESUME_TEXT"
  while [ "${text#/}" != "$text" ]; do text="${text#/}"; done
  txp "$p" send-keys -t "$pane" -l "$text"
  sleep 0.3 # let the TUI ingest the text before Enter so it isn't swallowed
  txp "$p" send-keys -t "$pane" Enter
}

# Every live registered pane (panerefs), pruning registry files whose pane died.
registry_panerefs() {
  local f socket session pane dir pr
  [ -d "$CCAR_PANES_DIR" ] || return
  for f in "$CCAR_PANES_DIR"/*; do
    [ -e "$f" ] || continue
    IFS=$'\t' read -r socket session pane dir <"$f" || continue
    pr="$socket"$'\t'"$pane"
    if pane_alive "$pr"; then
      printf '%s\n' "$pr"
    else
      rm -f "$f"   # pane gone -> drop its registry entry
    fi
  done
}

claude_panes() { # panerefs of every live registered pane whose foreground is claude
  local pr
  while IFS= read -r pr; do
    [ -z "$pr" ] && continue
    foreground_is_claude "$pr" && printf '%s\n' "$pr"   # never inject into a bare shell
  done < <(registry_panerefs)
}

is_paused_pane() { # $1 = paneref: do its bottom-most content lines show the limit?
  # Anchored to the last N NON-BLANK lines (capture-pane pads to full pane height
  # with blank rows, so a plain tail would just grab those). The genuine pause
  # sits near the bottom, above the input box; a mention up in the scrollback
  # falls outside the window.
  local scr
  scr="$(capture "$1" | grep -v '^[[:space:]]*$' | tail -n "${CCAR_DETECT_TAIL_LINES:-15}")"
  [ -n "$scr" ] && printf '%s\n' "$scr" | grep -E -i -q "$CCAR_DETECT_REGEX"
}

# Decide whether the account is rate-limited; if so, echo EVERY claude pane to
# resume (the limit is account-wide, so all sessions are paused — we don't rely on
# seeing the text in each one, which is what left sessions behind before). The
# status line's used_percentage is authoritative: it both triggers detection and
# vetoes false positives from a session that merely displays the limit phrase.
detect_limited() { # echoes panerefs to resume, or nothing
  local panes used p
  panes="$(claude_panes)"
  [ -z "$panes" ] && return
  used="$(read_used_pct)"
  if [ -n "$used" ]; then
    # Authoritative usage known: trust the number, ignore on-screen text entirely.
    awk "BEGIN{exit !($used >= ${CCAR_LIMIT_PCT:-95})}" && echo "$panes"
    return
  fi
  # No usage data (status line unpatched / not yet rendered): fall back to
  # bottom-anchored pane text — if ANY claude pane is paused, all of them are.
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if is_paused_pane "$p"; then echo "$panes"; return; fi
  done <<<"$panes"
}

count() { [ -z "$1" ] && echo 0 || grep -c . <<<"$1"; }

# When sourced (tests), expose the functions but don't enter the loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

log "monitor started (pid $$)"
idle_since=0
while :; do
  if [ -e "$CANCEL_FILE" ]; then
    rm -f "$CANCEL_FILE"
    status_clear
    log "cancelled by operator — monitor exiting (cc-run restarts it)"
    exit 0
  fi
  # No registered pane still alive? Allow a grace window (covers launch races and
  # cutover) before exiting — the next `claude` launch restarts the monitor.
  if [ -z "$(registry_panerefs)" ]; then
    now=$(date +%s)
    [ "$idle_since" -eq 0 ] && idle_since=$now
    if [ $((now - idle_since)) -ge "${CCAR_IDLE_EXIT_SECONDS:-60}" ]; then
      log "no live registered panes for ${CCAR_IDLE_EXIT_SECONDS:-60}s — monitor exiting"
      exit 0
    fi
    sleep "$CCAR_POLL_SECONDS"
    continue
  fi
  idle_since=0

  limited="$(detect_limited)"
  if [ -n "$limited" ]; then
    # First pane's screen feeds the pane-text time fallback in compute_wait.
    read -r target mode <<<"$(compute_wait "$(capture "$(head -1 <<<"$limited")")")"
    log "limit detected ($(count "$limited") claude pane(s)); waiting until $(date -d "@$target" '+%F %T') ($mode)"
    if ! wait_until "$target" "$mode"; then
      rm -f "$CANCEL_FILE"
      status_clear
      log "cancelled during wait — monitor exiting (cc-run restarts it)"
      exit 0
    fi
    # Re-evaluate after the wait (windows/usage may have changed).
    still="$(detect_limited)"
    if [ -z "$still" ]; then
      backoff_idx=0
      status_clear
      log "limit cleared during wait — no resume needed"
    else
      while IFS= read -r p; do [ -n "$p" ] && send_resume "$p"; done <<<"$still"
      log "resume sent to $(count "$still") pane(s)"
      sleep "${CCAR_GRACE_SECONDS:-15}"
      after="$(detect_limited)"
      if [ -n "$after" ]; then
        backoff_idx=$((backoff_idx + 1))
        log "still limited after resume ($(count "$after") pane(s)) — escalating backoff (idx $backoff_idx)"
      else
        backoff_idx=0
        status_clear
        log "resumed $(count "$still") pane(s)"
      fi
    fi
  fi
  sleep "$CCAR_POLL_SECONDS"
done
