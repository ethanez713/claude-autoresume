#!/usr/bin/env bash
# claude-autoresume monitor (PLAN.md §3c) — watches every registered claude pane
# (the registry CCAR_PANES_DIR, written by cc-run, spanning your own tmux server
# and the ccar fallback) for the account-wide rate limit, waits until the window
# resets (resets_at from state.json, else pane-text time, else backoff), then
# resumes the paused sessions.
#
# Detection is a per-pane LATCH, not a point-in-time text match: when a pane
# shows evidence it hit the limit (the choice prompt we answer, the pause
# message anywhere on its screen, or the account usage crossing the limit), the
# monitor flags it and remembers a snapshot of its paused screen. At reset time
# it resumes each latched pane unless there is positive evidence it un-paused
# (screen changed since the pause / actively repainting). This guards BOTH ways:
# no "continue" into a pane that wasn't limited or is mid-work (false positive),
# and no paused pane skipped because UI chrome (todo list, spinner) pushed the
# pause message around the screen (false negative). Usage readings from the
# status line are only trusted inside their validity window: a >=limit reading
# until its own resets_at passes, a clear reading while fresh — a stale number
# is treated as unknown, never as truth. 100% local: no network, bash + tmux +
# python stdlib.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${CCAR_CONFIG:-$here/config.sh}"

CANCEL_FILE="$CCAR_STATE_DIR/cancel"
backoff_idx=0
declare -A prompt_last_dismiss=()   # paneref -> epoch we last answered its rate-limit choice prompt (cooldown)
# Per-pane rate-limit latch (the monitor's memory of who got limited):
#   pane_latch[paneref] = seen  — per-pane evidence: we answered its choice
#                                 prompt, or its screen showed the pause message
#                       = usage — account-level evidence only (usage >= limit
#                                 while this pane showed nothing itself)
#   pane_snap[paneref]  = hash of the pane's screen when it last looked paused;
#                         "unchanged since then" is the resume-safety signal
#   pane_snap_ok[paneref] = 1 once the snapshot is trustworthy: taken from a
#                         screen that showed the pause message, or settled (two
#                         consecutive scans identical — a latch can fire while a
#                         pane is still painting, and a snapshot of a moving
#                         screen would make the gate see phantom "activity")
#   pane_parked[paneref] = 1 once the pane has positive pause evidence and so
#                         will be resumed: a seen latch always, a usage latch
#                         only when the pause message is in its scrollback. This,
#                         not the bare latch, drives the wait glyph — an idle
#                         pane swept into a usage latch by account-wide usage is
#                         latched (for resume safety) but not parked, so it keeps
#                         its own idle/working glyph instead of the hourglass.
# In-memory only: a restarted monitor re-derives latches from the pause screens,
# which stay painted until something is sent to the pane.
# (=() matters: bash 5.1 + set -u treats a declared-but-never-assigned array as
# unbound when expanding ${#arr[@]}.)
declare -A pane_latch=()
declare -A pane_snap=()
declare -A pane_snap_ok=()
declare -A pane_parked=()
declare -A attached=()            # socket -> yes|no, recomputed once per scan
declare -A pane_busy=()           # paneref -> last @ccar_busy value we published for its window
declare -A socket_any_busy=()     # socket -> last @ccar_any_busy value we published for its server
declare -A pane_busy_snap=()      # paneref -> hash of its last captured screen, for the frozen-pane test
declare -A pane_hook_veto=()      # paneref -> epoch the pane went frozen-and-spinnerless under a hook-set 1
declare -A pane_hook_veto_logged=() # paneref -> 1 once we've logged that pane's stranded flag
busy_frame=0                      # index into CCAR_BUSY_GLYPHS, advanced while any pane is working
poll_registry=""                  # panerefs alive this poll (one registry walk, shared by every consumer)
poll_panes=""                     # the subset running claude
stats_last_ts=0; stats_last_cpu=0; stats_polls=0; stats_frames=0
declare -A busy_format_done=()    # "<socket>\t<session>" -> 1 once we've patched (or declined to patch) its formats
status_active=0                   # 1 while a countdown is painted in status-right, so we can wipe it when the limit clears on its own

# --- clock reconciliation ----------------------------------------------------
# On WSL2 (and some VMs) the guest clock can freeze in the past when the host
# sleeps and only re-syncs lazily, so `date +%s` reads BEHIND true wall time
# after a resume. Every timing decision here is epoch math against an absolute
# resets_at, so a lagging "now" makes us over-wait and paint a wrong countdown.
# We reconcile against an external true-time source (the Windows host clock by
# default) and carry the difference as clock_offset, added to every `date +%s`
# via now_epoch. We do NOT touch the system clock (that needs root); we only fix
# the monitor's own notion of "now", which is sufficient because resets_at is an
# absolute server epoch, not derived from the local clock.
clock_offset=0          # seconds to add to `date +%s` to get true wall time
clock_last_resync=0     # raw `date +%s` at the last reconcile attempt (gates cadence)
# Command that prints the true wall-clock UNIX epoch. Default reads the Windows
# host clock (WSL); 100% local, no network. Set CCAR_HOST_TIME_CMD="" to disable
# reconciliation (offset stays 0 -> identical to plain `date`), e.g. on native
# Linux where systemd-timesyncd already keeps the clock honest.
CCAR_HOST_TIME_CMD="${CCAR_HOST_TIME_CMD-powershell.exe -NoProfile -Command '[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()'}"
CCAR_CLOCK_RESYNC_SECONDS="${CCAR_CLOCK_RESYNC_SECONDS:-600}"  # min gap between reconciles
CCAR_CLOCK_DRIFT_WARN_SECONDS="${CCAR_CLOCK_DRIFT_WARN_SECONDS:-5}"  # log when offset shifts more than this

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$CCAR_LOG"; }

host_epoch() { # prints the external true-time epoch, or nothing on failure
  [ -n "$CCAR_HOST_TIME_CMD" ] || return 1
  local out
  out="$(timeout 5 sh -c "$CCAR_HOST_TIME_CMD" 2>/dev/null | tr -dc '0-9')"
  # Sanity-gate: a plausible current epoch is 10 digits (>= 2001, < 2286). This
  # rejects empty output, error text, and millisecond epochs that would yield a
  # wild offset.
  case "$out" in
    [1-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) printf '%s' "$out" ;;
    *) return 1 ;;
  esac
}

# Recompute clock_offset from the external source. Rate-limited to once per
# CCAR_CLOCK_RESYNC_SECONDS (measured on the RAW clock, which still ticks after a
# resume even when offset is wrong) UNLESS $1 = "force" — used at the moments that
# matter most (a detected suspend jump, and right around a wait).
reconcile_clock() {
  [ -n "$CCAR_HOST_TIME_CMD" ] || return 0
  local raw host new
  raw="$(date +%s)"
  if [ "${1:-}" != force ] && [ $((raw - clock_last_resync)) -lt "$CCAR_CLOCK_RESYNC_SECONDS" ]; then
    return 0
  fi
  clock_last_resync="$raw"
  host="$(host_epoch)" || { log "clock reconcile: host time unavailable; keeping offset ${clock_offset}s"; return 0; }
  new=$((host - raw))
  local delta=$((new - clock_offset)); delta="${delta#-}"  # abs change since last offset
  [ "$delta" -ge "$CCAR_CLOCK_DRIFT_WARN_SECONDS" ] && \
    log "clock reconcile: local clock now ${new}s behind host (was ${clock_offset}s) — corrected the monitor's wait math"
  clock_offset="$new"
}

now_epoch() { echo $(( $(date +%s) + clock_offset )); }  # true wall-clock "now"

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
  status_active=1
}
status_clear() {
  local socket session
  while IFS=$'\t' read -r socket session; do
    [ -n "$socket" ] && tmux -S "$socket" set-option -u -t "$session" status-right 2>/dev/null
  done < <(live_sessions)
  status_active=0
}

capture() { txp "$1" capture-pane -p -t "$(pr_pane "$1")" 2>/dev/null; }  # $1 = paneref
# Same screen WITH its colour escapes. Kept separate from capture(): the limit
# regex spans several words and would break if Claude ever recoloured part of the
# phrase, so only the busy check — which needs colour to work at all — pays for it.
capture_ansi() { txp "$1" capture-pane -pe -t "$(pr_pane "$1")" 2>/dev/null; }  # $1 = paneref

hash_of() { printf '%s' "$1" | sha1sum | cut -d' ' -f1; }  # $1 = screen text

# Claude Code paints the SAME title glyph (✳) whether it is idle or working, so
# the tmux window name alone cannot tell a burning session from a parked one.
# What does differ is its TUI: while a turn is running it paints its spinner
# glyph at column 1 in the active colour, and a FINISHED turn leaves the same
# shape behind in grey ("✻ Cooked for 24m 49s"). Matching the colour rather than
# the glyph is the whole trick — see CCAR_BUSY_REGEX. We publish the answer as a
# per-window user option and swap the glyph in window-status-format; the pane
# title keeps flowing through untouched, so Claude's own subagent-dispatch moon
# phases still win.
screen_shows_working() { # $1 = screen text WITH colour escapes (capture_ansi)
  [ -n "${CCAR_BUSY_REGEX:-}" ] || return 1   # empty regex => feature off, NOT "grep matches everything"
  [ -n "$1" ] && printf '%s\n' "$1" | grep -a -E -q "$CCAR_BUSY_REGEX"
}

# Splice $3 into whatever $2 already says on server $1, in place of the first of
# the tokens $4... it contains — rewriting the token instead of overwriting the
# option keeps any customisation the operator has, whatever this tmux's stock
# format happens to be. Always re-derives from the value as it was BEFORE we ever
# touched it, stashed on first patch: patching our own output is not reversible
# (we can't recognise an older release's blob to strip it), so without the stash
# an upgrade would need the operator to reset the option by hand.
splice_format() { # $1=socket $2=option $3=replacement $4...=tokens it may replace
  local socket="$1" opt="$2" repl="$3"; shift 3
  local origkey="@ccar_orig_$opt" orig cur tok
  orig="$(tmux -S "$socket" show-options -gv "$origkey" 2>/dev/null)"
  if [ -z "$orig" ]; then
    cur="$(tmux -S "$socket" show-options -gv "$opt" 2>/dev/null)" || return 1
    case "$cur" in *@ccar_*)
      tmux -S "$socket" set-option -gu "$opt" 2>/dev/null
      cur="$(tmux -S "$socket" show-options -gv "$opt" 2>/dev/null)"
      log "$opt on $socket carried an older ccar glyph format — reset to this tmux's default before re-patching" ;;
    esac
    orig="$cur"
    tmux -S "$socket" set-option -g "$origkey" "$orig" 2>/dev/null
  fi
  for tok in "$@"; do
    case "$orig" in *"$tok"*)
      tmux -S "$socket" set-option -g "$opt" "${orig//"$tok"/$repl}" 2>/dev/null
      return 0 ;;
    esac
  done
  return 1
}

# The glyph swap has to live on whichever tmux server the operator actually
# attached to, which is theirs as often as it is the ccar fallback — so we patch
# the formats in place rather than shipping them in tmux.conf. Two of them: the
# window list (per-window @ccar_busy), and the terminal title, which is the only
# indicator visible from the taskbar and so tracks the whole server instead
# (@ccar_any_busy). A title nobody pushes to the terminal can't sparkle, so
# set-titles goes on too.
install_busy_format() {
  [ -n "${CCAR_BUSY_REGEX:-}" ] || return 0
  local socket session key opt
  while IFS=$'\t' read -r socket session; do
    key="$socket"$'\t'"$session"
    [ -n "${busy_format_done[$key]:-}" ] && continue
    busy_format_done[$key]=1
    for opt in window-status-format window-status-current-format; do
      splice_format "$socket" "$opt" "$CCAR_BUSY_NAME_FORMAT" '#W' '#{window_name}' \
        || log "$opt on $socket names no window — leaving it alone; the working glyph will not show there"
    done
    if [ -n "${CCAR_BUSY_TITLE_FORMAT:-}" ]; then
      if splice_format "$socket" set-titles-string "$CCAR_BUSY_TITLE_FORMAT" '#T' '#{pane_title}'; then
        if [ "$(tmux -S "$socket" show-options -gv set-titles 2>/dev/null)" != on ]; then
          tmux -S "$socket" set-option -g set-titles on 2>/dev/null
          log "turned set-titles on for $socket so the working glyph reaches the terminal tab"
        fi
      else
        log "set-titles-string on $socket names no pane title — leaving it alone; the taskbar will not show working sessions"
      fi
    fi
    # So no window is ever glyph-less before the first frame tick, and the states
    # the frame loop never touches have their glyph from the start.
    tmux -S "$socket" set-option -g @ccar_spin "$(busy_glyph 0)" \; \
      set-option -g @ccar_sub_spin "$(busy_glyph 0 "${CCAR_SUBAGENT_GLYPHS:-}")" \; \
      set-option -g @ccar_wait "${CCAR_LIMIT_GLYPH:-⧗}" 2>/dev/null
  done < <(live_sessions)
}

socket_attached() { # $1 = socket path; cached for the length of one scan
  local s="$1"
  if [ -z "${attached[$s]:-}" ]; then
    if [ -n "$(tmux -S "$s" list-clients -F '#{client_name}' 2>/dev/null | head -1)" ]; then
      attached[$s]=yes
    else
      attached[$s]=no
    fi
  fi
  [ "${attached[$s]}" = yes ]
}

# Same key convention as register_pane() in bin/cc-run and bin/cc-busy-hook, so
# all three derive an identical key from one paneref/socket+pane pair.
pane_key() { # $1 = paneref
  printf '%s:%s' "$(pr_socket "$1")" "$(pr_pane "$1")" | tr -c 'A-Za-z0-9._-' '_'
}

# Primary @ccar_busy signal: the per-pane state bin/cc-busy-hook writes on every
# UserPromptSubmit/Stop/SessionStart/SessionEnd. Echoes "0"/"1", or "" when
# there is no hook state at all (missing file, unreadable, or garbage) — the
# caller reads that as "no hook installed for this pane, fall back". Defaults
# CCAR_BUSY_DIR the same way bin/cc-busy-hook does: an existing install.sh never
# overwrites a user's config.sh, so an install from before this knob existed
# has none, and set -u would make an unset reference here an error.
read_hook_busy() { # $1 = paneref
  local f state
  f="${CCAR_BUSY_DIR:-$CCAR_STATE_DIR/busy}/$(pane_key "$1")"
  [ -f "$f" ] || return 0
  IFS=$'\t' read -r state _ <"$f" 2>/dev/null
  case "$state" in
    0|1) printf '%s' "$state" ;;
  esac
}

# Second hook signal for the same pane: how many subagents are running, kept by
# bin/cc-busy-hook on SubagentStart/SubagentStop. Echoes "1" while at least one
# is, else "0". The count is what makes "the main agent is idle but its subagents
# are not" a decidable state — the pane's own subagent panel is a TUI element
# with no text worth matching, and it paints a spinner the scrape cannot tell
# apart from a turn of the main agent's own.
read_hook_sub() { # $1 = paneref
  local f n
  f="${CCAR_BUSY_DIR:-$CCAR_STATE_DIR/busy}/$(pane_key "$1").sub"
  [ -f "$f" ] || { printf '0'; return; }
  IFS=$'\t' read -r n _ <"$f" 2>/dev/null
  case "$n" in ''|0|*[!0-9]*) printf '0' ;; *) printf '1' ;; esac
}

# Pure decision for @ccar_busy, split out of publish_busy so it can be unit
# tested with no tmux involved.
#   $1 hook     = "0" | "1" | ""   (read_hook_busy; "" = no hook state for this pane)
#   $2 scrape   = "0" | "1" | ""   (screen_shows_working; "" = never attempted,
#                                    i.e. no client is attached to this server)
#   $3 frozen   = "0" | "1" | ""   (this pane's screen is byte-identical to the
#                                    previous refresh; "" when unknown)
#   $4 veto_age = seconds the pane has been BOTH frozen and scraping idle while
#                 a hook flag still says 1, or "" if that has not been true yet
#   $5 sub      = "0" | "1"        (read_hook_sub: subagents are running)
#   $6 limited  = "0" | "1"        (this pane is parked at the limit — has pause
#                                    evidence and will be resumed; a bare latch
#                                    without that evidence does NOT count, so an
#                                    idle pane swept into an account-usage latch
#                                    keeps its own glyph)
# Echoes the pane's state: "limit" (parked until the window resets), "1" (the
# main agent is running a turn), "sub" (the main agent is idle, its subagents are
# not) or "0" (idle).
#
# The signals disagree in every direction, and each is authoritative somewhere:
#
#   limited wins over a stale hook flag but not over a live spinner. A pane
#   parked at the limit is not working whatever its last hook said — a turn cut
#   off mid-flight never fires Stop, so its flag stands there for the whole
#   wait. But once the pane is visibly running again (a spinner on the live
#   screen) it has been resumed and should_resume() will skip it at reset, so
#   the hourglass would lie: the live scrape takes the window back.
#
#   hook=1 outlives the scrape, because the scrape false-negatives constantly:
#   while a tool call runs the pane paints its output instead of the spinner
#   line, so "no spinner" is not evidence of idleness. Only a FROZEN screen is
#   — a live turn repaints (the spinner ticks, the timer counts) and an
#   interrupted one does not. So a hook flag is cleared only after the pane has
#   held still AND shown no spinner for CCAR_BUSY_STALE_SECONDS, which is what
#   an Esc-interrupt or a kill -9 leaves behind. This is the same
#   frozen-means-parked test should_resume() uses on the rate-limit path.
#
#   sub outranks the scrape, because the subagent panel paints a coloured
#   spinner of its own that the scrape cannot tell apart from a turn of the main
#   agent's. Only the count separates "thinking" from "waiting on its agents",
#   and only a hook-set turn of its own takes the window back.
#
#   scrape=1 has the last word, and it is what carries a pane with no hooks at
#   all: Claude Code fires none when a background-task notification (a finished
#   subagent, a scheduled wake) resumes a session, so the hook can read 0 from
#   the last Stop while a turn is genuinely running. Seeing the spinner is proof
#   that something is.
decide_busy() {
  local hook="$1" scrape="$2" frozen="$3" veto_age="$4" sub="${5:-0}" limited="${6:-0}" stale=0
  # A parked pane keeps the hourglass only while it still looks parked. A live
  # spinner means it was resumed and will not get a continue at reset (should_resume
  # sees it repainting and skips it), so live activity takes the window back. Only
  # the scrape overrides — a stale hook flag from an interrupted turn does not, and
  # an unattached pane (scrape "") has no live signal, so it keeps the parked glyph.
  [ "$limited" = 1 ] && [ "$scrape" != 1 ] && { printf 'limit'; return; }
  # A frozen, spinnerless pane has held still too long for any hook flag on it to
  # still be true. Anything else — a repaint, or nobody attached to look — leaves
  # the flags standing.
  if [ "$frozen" = 1 ] && [ -n "$veto_age" ] && [ "$veto_age" -ge "${CCAR_BUSY_STALE_SECONDS:-20}" ]; then
    stale=1
  fi
  [ "$stale" = 0 ] && [ "$hook" = 1 ] && { printf '1'; return; }
  [ "$stale" = 0 ] && [ "$sub" = 1 ] && { printf 'sub'; return; }
  [ "$scrape" = 1 ] && { printf '1'; return; }
  printf '0'
}

publish_busy() { # $1 = paneref
  [ -n "${CCAR_BUSY_REGEX:-}" ] || return 0
  local pr="$1" hook sub limited=0 scrape="" frozen="" att=0 busy now veto_age="" ansi shot
  hook="$(read_hook_busy "$pr")"
  sub="$(read_hook_sub "$pr")"
  [ -n "${pane_parked[$pr]:-}" ] && limited=1
  socket_attached "$(pr_socket "$pr")" && att=1
  # One capture per attached pane, as before the hooks existed — it answers both
  # "is the spinner up" and "did anything repaint". An unattached server is still
  # free: nobody can see that window list, so neither question is worth asking.
  if [ "$att" = 1 ]; then
    ansi="$(capture_ansi "$pr")"
    if screen_shows_working "$ansi"; then scrape=1; else scrape=0; fi
    shot="$(hash_of "$ansi")"
    if [ "$shot" = "${pane_busy_snap[$pr]:-}" ]; then frozen=1; else frozen=0; fi
    pane_busy_snap[$pr]="$shot"
  fi
  # Age a hook flag — a running turn or a running subagent — only while the pane
  # is BOTH frozen and showing no spinner, the one state an Esc-interrupt or a
  # kill -9 leaves behind. Any repaint means the work is alive and resets the
  # clock, so a long tool call (which paints its output where the spinner line
  # would be) can no longer clear a live flag.
  if { [ "$hook" = 1 ] || [ "$sub" = 1 ]; } && [ "$att" = 1 ] && [ "$scrape" = 0 ] && [ "$frozen" = 1 ]; then
    now="$(now_epoch)"
    [ -n "${pane_hook_veto[$pr]:-}" ] || pane_hook_veto[$pr]=$now
    veto_age=$(( now - pane_hook_veto[$pr] ))
  elif [ "$att" = 1 ] || { [ "$hook" != 1 ] && [ "$sub" != 1 ]; }; then
    # Disproven (it repainted or the spinner is up), or every flag has dropped and
    # a stale timer must not survive into the next turn. An unattached pane with a
    # flag still up falls through both: its timer is unobserved, not disproven.
    unset 'pane_hook_veto[$pr]' 'pane_hook_veto_logged[$pr]'
  fi
  busy="$(decide_busy "$hook" "$scrape" "$frozen" "$veto_age" "$sub" "$limited")"
  if [ "$busy" = 0 ] && { [ "$hook" = 1 ] || [ "$sub" = 1 ]; } && [ -n "$veto_age" ] && [ -z "${pane_hook_veto_logged[$pr]:-}" ]; then
    log "pane $pr: hook flag stranded (no Stop/SubagentStop?) — cleared @ccar_busy after ${veto_age}s frozen with no spinner"
    pane_hook_veto_logged[$pr]=1
  fi
  # Re-set every poll rather than only on a change: the option lives on the
  # window, so moving/splitting/renumbering panes can strand a stale value that
  # a change-gated writer would never correct.
  txp "$pr" set-option -w -t "$(pr_pane "$pr")" @ccar_busy "$busy" 2>/dev/null
  [ "${pane_busy[$pr]:-}" = "$busy" ] && return 0
  pane_busy[$pr]="$busy"
  txp "$pr" refresh-client -S 2>/dev/null   # repaint now instead of at the next status-interval
}

# Cumulative CPU of the monitor AND every child it has reaped, in 10ms ticks.
# The forks (tmux, grep) are most of the cost, so self-time alone would say the
# monitor is free. Stripping through the last ')' keeps a space in comm from
# shifting the fields.
cpu_ticks() {
  local st; st="$(</proc/$$/stat)"; st="${st#*") "}"
  local -a f; read -ra f <<<"$st"
  echo $(( f[11] + f[12] + f[13] + f[14] ))
}

# One wide event per window answering "what is this costing, and on what". Not a
# counter: the shape (how many panes, how many attached, how many working) is
# what makes a surprising cpu_pct actionable rather than just alarming.
stats_emit() {
  local every="${CCAR_STATS_SECONDS:-300}"
  [ "$every" -gt 0 ] 2>/dev/null || return 0
  local now; now=$(date +%s)
  if [ "$stats_last_ts" -eq 0 ]; then stats_last_ts=$now; stats_last_cpu=$(cpu_ticks); return 0; fi
  [ $(( now - stats_last_ts )) -ge "$every" ] || return 0
  local wall=$(( now - stats_last_ts )) t; t=$(cpu_ticks)
  local dcpu=$(( t - stats_last_cpu )) pct10 busy=0 sub=0 att=0 k
  pct10=$(( dcpu * 10 / wall ))          # ticks are 10ms, so ticks/second IS percent-of-core
  for k in "${!pane_busy[@]}"; do
    case "${pane_busy[$k]}" in 1) busy=$(( busy + 1 )) ;; sub) sub=$(( sub + 1 )) ;; esac
  done
  for k in "${!attached[@]}";  do [ "${attached[$k]}" = yes ] && att=$(( att + 1 )); done
  printf '{"ts":"%s","window_s":%d,"cpu_ms":%d,"cpu_pct":%d.%d,"polls":%d,"frames":%d,"registered":%d,"claude":%d,"busy":%d,"sub":%d,"servers_attached":%d,"latched":%d}\n' \
    "$(date -Is)" "$wall" "$(( dcpu * 10 ))" "$(( pct10 / 10 ))" "$(( pct10 % 10 ))" \
    "$stats_polls" "$stats_frames" "$(count "$poll_registry")" "$(count "$poll_panes")" \
    "$busy" "$sub" "$att" "${#pane_latch[@]}" >>"$CCAR_STATS_JSONL"
  stats_last_ts=$now; stats_last_cpu=$t; stats_polls=0; stats_frames=0
  local max="${CCAR_STATS_MAX_BYTES:-262144}"
  if [ "$(stat -c%s "$CCAR_STATS_JSONL" 2>/dev/null || echo 0)" -gt "$max" ]; then
    tail -c $(( max / 2 )) "$CCAR_STATS_JSONL" > "$CCAR_STATS_JSONL.tmp" 2>/dev/null \
      && mv "$CCAR_STATS_JSONL.tmp" "$CCAR_STATS_JSONL"
  fi
}

busy_glyph() { # $1 = frame index (wraps), $2 = glyph list (default CCAR_BUSY_GLYPHS)
  local -a g
  read -ra g <<<"${2-${CCAR_BUSY_GLYPHS:-}}"   # read never globs, so a bare * stays a glyph
  [ "${#g[@]}" -gt 0 ] || return 0
  printf '%s' "${g[$(( $1 % ${#g[@]} ))]}"
}

busy_sockets() { # sockets with a pane in an ANIMATED state AND a client attached.
  # A hook-only flag on an unattached server is correct and free to publish, but
  # nobody is looking at that window list — the socket_attached filter is what
  # keeps the animation loop (spinner set-option + refresh-client every
  # CCAR_BUSY_ANIM_MS) from spending real cost on a walked-away session. The
  # limit glyph is static, so a parked pane needs no frames.
  local p s
  for p in "${!pane_busy[@]}"; do
    case "${pane_busy[$p]}" in 1|sub) ;; *) continue ;; esac
    s="$(pr_socket "$p")"
    socket_attached "$s" && printf '%s\n' "$s"
  done | sort -u
}

# The busiest state on a server, published per server as @ccar_any_busy. The
# terminal title has to ask that question rather than the per-window one: it
# belongs to whichever pane is active, but the taskbar shows it whatever window
# you happen to be looking at, so it speaks for the whole server or it lies.
# Precedence is deliberately not the per-window one: there a limit is exclusive
# truth about one pane, here the question is "is anything still moving", so live
# work outranks a parked pane and the hourglass only reaches the taskbar once
# nothing anywhere is running.
# Never call this from a command substitution — the change-tracking would be
# written in the subshell and thrown away.
publish_any_busy() {
  [ -n "${CCAR_BUSY_TITLE_FORMAT:-}" ] || return 0
  local p s state
  local -A any=()
  local -A rank=([0]=0 [limit]=1 [sub]=2 [1]=3)
  for p in "${!pane_busy[@]}"; do
    s="$(pr_socket "$p")"; state="${pane_busy[$p]}"
    [ -n "${any[$s]:-}" ] && [ "${rank[${any[$s]}]:-0}" -ge "${rank[$state]:-0}" ] && continue
    any[$s]="$state"
  done
  for s in "${!any[@]}"; do
    [ "${socket_any_busy[$s]:-}" = "${any[$s]}" ] && continue
    socket_any_busy[$s]="${any[$s]}"
    # A working server gets refreshed by the frame loop anyway; this call is what
    # repaints the title of one that has just stopped working.
    tmux -S "$s" set-option -g @ccar_any_busy "${any[$s]}" \; refresh-client -S 2>/dev/null
  done
}

# The poll sleep, spent animating the spinner instead of idling. Claude's own
# glyph cycle is the point — a working session should read the same in the window
# list as it does in the pane. One batched tmux call per server per frame keeps
# that affordable, and @ccar_spin is a SERVER option (not per-window) so the cost
# is per server rather than per working pane. Falls back to a plain sleep when
# nothing is working, so an all-idle box is exactly as quiet as it was before.
poll_sleep() {
  local step_ms="${CCAR_BUSY_ANIM_MS:-400}" frames socks i socket nap every p
  if [ "$step_ms" -le 0 ] || [ -z "${CCAR_BUSY_GLYPHS:-}" ] || [ "${#pane_busy[@]}" -eq 0 ]; then
    sleep "$CCAR_POLL_SECONDS"; return
  fi
  frames=$(( CCAR_POLL_SECONDS * 1000 / step_ms ))
  [ "$frames" -gt 0 ] || frames=1
  nap="$(printf '%d.%03d' $((step_ms / 1000)) $((step_ms % 1000)))"
  # How often, in frames, to re-read who is working. The full scan is far too
  # expensive to run at the rate the indicator wants to be fresh (it re-reads
  # state.json and runs the rc/burn checks), so the two are decoupled: this loop
  # re-reads only the pane colours, which is one capture per attached pane.
  every=$(( ${CCAR_BUSY_REFRESH_MS:-2000} / step_ms ))
  [ "$every" -gt 0 ] || every=1
  socks="$(busy_sockets)"
  for ((i = 0; i < frames; i++)); do
    if [ $(( i % every )) -eq 0 ]; then
      [ "$i" -gt 0 ] && for p in "${!pane_busy[@]}"; do publish_busy "$p"; done
      publish_any_busy
      socks="$(busy_sockets)"
    fi
    if [ -z "$socks" ]; then sleep "$nap"; continue; fi   # nothing working: idle out the rest
    busy_frame=$(( busy_frame + 1 )); stats_frames=$(( stats_frames + 1 ))
    while IFS= read -r socket; do
      [ -n "$socket" ] || continue
      tmux -S "$socket" set-option -g @ccar_spin "$(busy_glyph "$busy_frame")" \; \
        set-option -g @ccar_sub_spin "$(busy_glyph "$busy_frame" "${CCAR_SUBAGENT_GLYPHS:-}")" \; \
        refresh-client -S 2>/dev/null
    done <<<"$socks"
    sleep "$nap"
  done
}

screen_shows_limit() { # $1 = screen text: pause message anywhere on the visible screen
  [ -n "$1" ] && printf '%s\n' "$1" | grep -E -i -q "$CCAR_DETECT_REGEX"
}

# Pause message in the pane's recent output (visible screen + last N history
# lines). A paused pane keeps the message in its transcript even when UI chrome
# (todo checklist, spinner) has pushed it off the visible screen entirely.
history_shows_limit() { # $1 = paneref
  txp "$1" capture-pane -p -S "-${CCAR_DETECT_HISTORY_LINES:-60}" -t "$(pr_pane "$1")" 2>/dev/null \
    | grep -E -i -q "$CCAR_DETECT_REGEX"
}

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

read_state_json() { # prints "used_percentage<US>resets_at<US>captured_at" (fields empty when absent)
  # Fields are separated by US (ASCII 0x1f), NOT tab/space: the reader splits with
  # IFS=$'\x1f', and because US is not an IFS-whitespace char an EMPTY middle field
  # (e.g. resets_at=null) is preserved as its own field. With a tab/space
  # separator bash would collapse the empty field and shift captured_at into
  # resets, silently breaking the "clear" reading.
  python3 - "$CCAR_STATE_JSON" <<'PY'
import json, sys
used = resets = captured = ""
try:
    d = json.load(open(sys.argv[1]))
    if d.get("used_percentage") is not None: used = str(d["used_percentage"])
    if d.get("resets_at") is not None: resets = str(int(d["resets_at"]))
    if d.get("captured_at") is not None: captured = str(int(d["captured_at"]))
except Exception:
    pass
print(used + "\x1f" + resets + "\x1f" + captured)
PY
}

# state.json is (re)written by the status line only while a session is actively
# rendering it; once everything pauses it stops changing. usage_state() runs on
# EVERY poll and every wait iteration, and it used to shell out to python3 each
# time just to parse this tiny file — thousands of interpreter startups across a
# multi-hour idle wait. Each python3 (~30 MB RSS) bumps the WSL2 VM's memory
# high-water mark, which the VM does not hand back to Windows, so the guest keeps
# looking bloated long after the spawns are gone. We cache the parsed fields
# keyed on the file's mtime: python3 runs only when the file actually changed
# (i.e. a session is live and writing it), and NOT AT ALL while idle/paused. A
# missing file needs no python at all. `stat` is a ~100 KB coreutils call —
# orders of magnitude lighter than a python startup — so the steady-state idle
# cost drops to one stat per poll.
#
# IMPORTANT: the cache lives in these globals and refresh_state_cache() must run
# in the MAIN shell, not a subshell — scan_panes (its only caller) runs directly
# in the loop, so the mtime it records persists across polls. usage_state() below
# only READS these globals, so it stays safe to call inside $(...).
state_cache_mtime="__unset__"
state_used="" ; state_resets="" ; state_captured=""
refresh_state_cache() { # updates state_used/state_resets/state_captured, re-parsing only when state.json changes
  local mtime
  mtime="$(stat -c %Y "$CCAR_STATE_JSON" 2>/dev/null)" || mtime=""
  if [ -z "$mtime" ]; then
    [ "$state_cache_mtime" = "" ] && return          # already reflects "no file"
    state_cache_mtime="" ; state_used="" ; state_resets="" ; state_captured=""
  elif [ "$mtime" != "$state_cache_mtime" ]; then
    IFS=$'\x1f' read -r state_used state_resets state_captured < <(read_state_json)
    state_cache_mtime="$mtime"
  fi
}

# The status line's used_percentage, interpreted ONLY inside its validity window.
# The status line renders (and writes state.json) while sessions are active, then
# goes silent when everything pauses — so the file is often STALE precisely when
# the monitor is working. Trusting a stale number either way caused real bugs
# (a pre-reset >=95 kept re-triggering detection in a 5s busy-loop after the
# window had already reset). Rules:
#   limited — used >= CCAR_LIMIT_PCT and its own resets_at is still in the
#             future (a limit reading self-expires at its reset)
#   clear   — used < CCAR_LIMIT_PCT and captured within
#             CCAR_USAGE_FRESH_SECONDS (a clear reading is only a veto while
#             fresh; sessions were rendering the status line moments ago)
#   unknown — anything else (missing file, unpatched status line, stale data):
#             fall back to per-pane screen evidence alone
usage_state() { # echoes limited | clear | unknown — reads the cache refreshed by scan_panes
  local used="$state_used" resets="$state_resets" captured="$state_captured" now
  [ -n "$used" ] || { echo unknown; return; }
  now=$(now_epoch)
  if awk "BEGIN{exit !($used >= ${CCAR_LIMIT_PCT:-95})}" 2>/dev/null; then
    if [ -n "$resets" ] && [ "$now" -lt "$resets" ]; then
      echo limited
    else
      echo unknown
    fi
  elif [ -n "$captured" ] && [ $((now - captured)) -le "${CCAR_USAGE_FRESH_SECONDS:-600}" ]; then
    echo clear
  else
    echo unknown
  fi
}

# --- burn window (opt-in) ----------------------------------------------------
# The inverse of a rate limit: the window resets SOON and quota is still unspent.
# That quota expires at the reset, so it is the cheapest moment to run something
# expensive. Reuses the state cache the limit detector already maintains — no
# extra polling, no network. Off unless CCAR_BURN_CMD is set.
#
# Deliberately kept off the status_set/status_clear path: those own status-right
# for the resume countdown and toggle status_active, which the main loop treats
# as "a countdown is painted". Sharing them would make the two fight every poll.
burn_bound=""   # sockets whose launch key is already bound
burn_open=0     # 1 while we have flagged the current window as open
burn_swept=0    # 0 until we have cleared any label a PREVIOUS monitor left painted

burn_enabled() { [ "${CCAR_BURN_ENABLE:-0}" = 1 ] && [ -n "${CCAR_BURN_CMD:-}" ]; }

burn_status_set() { # $1 = text; sets status-right WITHOUT claiming status_active
  local socket session
  while IFS=$'\t' read -r socket session; do
    [ -n "$socket" ] && tmux -S "$socket" set-option -t "$session" status-right "$1" 2>/dev/null
  done < <(live_sessions)
}
burn_status_clear() {
  local socket session
  while IFS=$'\t' read -r socket session; do
    [ -n "$socket" ] && tmux -S "$socket" set-option -u -t "$session" status-right 2>/dev/null
  done < <(live_sessions)
}

burn_window_open() { # 0 = open
  local used="$state_used" resets="$state_resets" captured="$state_captured" now mins
  [ -n "$used" ] && [ -n "$resets" ] && [ -n "$captured" ] || return 1
  now=$(now_epoch)
  # A stale usage figure must never read as "quota to spare" — same reasoning as
  # usage_state(): the status line stops writing when sessions go idle.
  [ $((now - captured)) -le "${CCAR_USAGE_FRESH_SECONDS:-600}" ] || return 1
  [ "$now" -lt "$resets" ] || return 1
  mins=$(( (resets - now) / 60 ))
  [ "$mins" -le "${CCAR_BURN_LEAD_MINUTES:-75}" ] || return 1
  awk "BEGIN{exit !($used <= ${CCAR_BURN_MAX_PCT:-75})}" 2>/dev/null || return 1
  return 0
}

burn_bind_keys() { # idempotent per socket: prefix+KEY opens the command in a new window
  local socket session
  while IFS=$'\t' read -r socket session; do
    [ -n "$socket" ] || continue
    case "$burn_bound" in *"|$socket|"*) continue ;; esac
    # -c is required: new-window otherwise inherits the SESSION's start directory,
    # which is wherever the first `claude` of the day happened to run — an unrelated
    # project repo would load its CLAUDE.md and file the transcript under it.
    if tmux -S "$socket" bind-key "${CCAR_BURN_KEY:-I}" \
         new-window -c "${CCAR_BURN_CWD:-$HOME}" \
         -n "${CCAR_BURN_WINDOW:-improve}" "${CCAR_BURN_CMD:-}" 2>/dev/null; then
      burn_bound="$burn_bound|$socket|"
      log "bound prefix+${CCAR_BURN_KEY:-I} on $socket"
    fi
  done < <(live_sessions)
}

burn_check() { # called once per idle poll; must never disturb the resume path
  burn_enabled || return 0
  [ "${#pane_latch[@]}" -eq 0 ] || return 0   # a real limit outranks an opportunity
  [ "$status_active" -eq 0 ] || return 0      # countdown owns status-right
  burn_bind_keys
  if burn_window_open; then
    local mins; mins=$(( (state_resets - $(now_epoch)) / 60 ))
    if [ "$burn_open" -eq 0 ]; then
      burn_open=1
      local socket session
      while IFS=$'\t' read -r socket session; do
        [ -n "$socket" ] && tmux -S "$socket" display-message -t "$session" \
          "${CCAR_BURN_LABEL:-♻ improve} — ~${mins}m to reset, ${state_used}% used. prefix+${CCAR_BURN_KEY:-I} to start" 2>/dev/null
      done < <(live_sessions)
      log "burn window OPEN (${mins}m to reset, ${state_used}% used) — nudged live sessions"
    fi
    burn_status_set "${CCAR_BURN_LABEL:-♻ improve} prefix+${CCAR_BURN_KEY:-I} "
  elif [ "$burn_open" -eq 1 ]; then
    burn_open=0
    burn_status_clear
    log "burn window closed"
  elif [ "$burn_swept" -eq 0 ]; then
    # First closed pass of this process. A monitor that was restarted while the
    # window was open (or killed mid-window) leaves our label painted with no
    # in-process transition left to clear it, so sweep it once — but only if the
    # text is still ours, never a countdown someone else owns.
    burn_swept=1
    local socket session cur
    while IFS=$'\t' read -r socket session; do
      [ -n "$socket" ] || continue
      cur="$(tmux -S "$socket" show-options -qv -t "$session" status-right 2>/dev/null)"
      case "$cur" in
        "${CCAR_BURN_LABEL:-♻ improve}"*)
          tmux -S "$socket" set-option -u -t "$session" status-right 2>/dev/null
          log "cleared a stale burn label left by a previous monitor" ;;
      esac
    done < <(live_sessions)
  fi
}

# --- remote-control watchdog (opt-in, best effort) ---------------------------
# Claude Code already handles the common disconnects ITSELF, and we deliberately
# do not duplicate that:
#   * `remoteControlAtStartup` (settings.json / `/config` -> "Enable Remote
#     Control for all sessions") reconnects every new session, including the ones
#     cc-run starts and the ones this monitor resumes.
#   * The bridge rebuilds its own transport after a laptop sleep or a network
#     blip, retrying internally before it gives up.
# What it does NOT do is come back after that internal recovery is EXHAUSTED:
# the footer indicator disappears and Claude Code's own advice is "run
# /remote-control again to retry" — a manual step, which is exactly the state an
# unattended session gets stuck in overnight. This watchdog performs only that
# last step, and only when it is confident the pane is idle.
#
# Evidence, all of it read-only, per pane:
#   indicator — the footer carries "/rc active" (or a bare "/rc" when the pane is
#               too narrow to fit the word) while the bridge is up. Missing =
#               not connected. Claude Code hides the indicator entirely on very
#               narrow panes, so panes below CCAR_RC_MIN_WIDTH are skipped rather
#               than guessed about.
#   grace     — the indicator must stay missing for CCAR_RC_GRACE_SECONDS before
#               we touch anything, so Claude Code's own reconnect wins the race.
#   idle      — an input box that is PRESENT and EMPTY, and a screen that is
#               byte-identical CCAR_SETTLE_SECONDS apart. A session mid-turn
#               repaints its elapsed-time counter every second, so a settled
#               screen means nothing is running and nothing is half-typed.
# Then a per-pane exponential backoff (CCAR_RC_BACKOFF_MINUTES) spaces the
# retries, and any sighting of the indicator resets it.
declare -A rc_missing_since=()   # paneref -> epoch the indicator first went missing
declare -A rc_next_attempt=()    # paneref -> epoch we may next send the command
declare -A rc_attempts=()        # paneref -> retries already sent this episode
rc_last_check=0

rc_enabled() { [ "${CCAR_RC_ENABLE:-0}" = 1 ] && [ -n "${CCAR_RC_COMMAND:-}" ]; }

# The bottom chrome of the pane: input box, separator, status line, mode line.
# Claude Code pads its EMPTY input line with U+00A0 (non-breaking space), which
# [[:space:]] does not match — so without this normalisation an idle prompt reads
# as "the box has text in it" and the watchdog would never fire. Rewriting the
# two-byte sequence to a plain space up front lets every helper below use
# ordinary whitespace classes. (tr can't do this: 0xC2 and 0xA0 are also bytes of
# other UTF-8 characters on these lines, e.g. "·", and deleting them corrupts.)
rc_tail() { # $1 = screen text
  printf '%s\n' "$1" | sed 's/\xc2\xa0/ /g' | grep -v '^[[:space:]]*$' \
    | tail -n "${CCAR_RC_TAIL_LINES:-8}"
}

# Just the chrome BELOW the input box — separator, status line, mode line. That is
# where the indicator is painted, and restricting the search to it keeps a
# CONVERSATION that happens to mention /rc from reading as "still connected"
# (which would silently disable the watchdog for that pane). Falls back to the
# whole tail when there is no input box to anchor on; we never act on that state
# anyway, since rc_input_ready requires the box.
rc_footer() { # $1 = screen text
  local t n
  t="$(rc_tail "$1")"
  n="$(printf '%s\n' "$t" | grep -n -E "${CCAR_RC_PROMPT_REGEX}" | tail -n1 | cut -d: -f1)"
  if [ -n "$n" ]; then printf '%s\n' "$t" | tail -n +$((n + 1)); else printf '%s\n' "$t"; fi
}

rc_indicator_present() { # $1 = screen text
  rc_footer "$1" | grep -E -q "${CCAR_RC_INDICATOR_REGEX}"
}

# The input line as Claude Code paints it when idle: the prompt marker and
# nothing after it. Returns 1 when there is no input box at all (a modal/menu is
# up, or the pane is showing something else entirely) as well as when the box
# holds text — both mean "don't type here".
rc_input_ready() { # $1 = screen text
  local line rest
  line="$(rc_tail "$1" | grep -E "${CCAR_RC_PROMPT_REGEX}" | tail -n1)"
  [ -n "$line" ] || return 1
  rest="$(printf '%s' "$line" | sed -E "s/${CCAR_RC_PROMPT_REGEX}//" | tr -d '[:space:]')"
  [ -z "$rest" ]
}

# Whatever currently sits in the input box (empty string when idle or absent).
rc_input_text() { # $1 = screen text
  rc_tail "$1" | grep -E "${CCAR_RC_PROMPT_REGEX}" | tail -n1 \
    | sed -E "s/${CCAR_RC_PROMPT_REGEX}//" | sed -E 's/[[:space:]]+$//'
}

# Is what's sitting in the input box our own command (whole or partially
# completed), rather than something else the pane put there? Only then is it safe
# to press Enter on it.
rc_residue_is_ours() { # $1 = text left in the box, $2 = the command we typed
  [ -n "$1" ] || return 1
  case "$2" in "$1"*) return 0 ;; *) return 1 ;; esac
}

rc_backoff_minutes() { # $1 = 1-based attempt number; echoes minutes to wait before the next try
  local i=0 m last=60
  for m in ${CCAR_RC_BACKOFF_MINUTES:-1 2 4 8 16 30 60}; do
    i=$((i + 1)); last="$m"
    [ "$i" -eq "$1" ] && { printf '%s' "$m"; return; }
  done
  printf '%s' "$last"   # hold at the longest interval rather than giving up
}

# Type the reconnect command into an idle pane. Returns 0 only if it was
# submitted. Slash commands open Claude Code's completion popup, where the first
# Enter ACCEPTS the highlighted completion instead of submitting the line — so we
# read the input box back and only press Enter a second time when what is sitting
# there is still our own command. Anything else is cleared and abandoned: the
# pane must never be left holding a half-typed or mis-completed command.
rc_send() { # $1 = paneref
  local p="$1" pane cmd left
  pane="$(pr_pane "$p")"
  cmd="${CCAR_RC_COMMAND:-/remote-control}"
  if [ -n "${CCAR_RESUME_CLEAR:-}" ]; then
    # shellcheck disable=SC2086 — clear keys are intentionally word-split key names
    txp "$p" send-keys -t "$pane" $CCAR_RESUME_CLEAR
    sleep 0.3
  fi
  txp "$p" send-keys -t "$pane" -l "$cmd"
  sleep 0.5   # let the TUI ingest the text (and open its completion popup)
  txp "$p" send-keys -t "$pane" Enter
  sleep 0.8
  left="$(rc_input_text "$(capture "$p")")"
  if [ -n "$left" ]; then
    if rc_residue_is_ours "$left" "$cmd"; then
      txp "$p" send-keys -t "$pane" Enter   # the popup ate the first Enter as a completion
      sleep 0.5
    else
      if [ -n "${CCAR_RESUME_CLEAR:-}" ]; then
        # shellcheck disable=SC2086 — clear keys are intentionally word-split key names
        txp "$p" send-keys -t "$pane" $CCAR_RESUME_CLEAR
      fi
      log "rc: input box held unexpected text after typing the reconnect command — cleared it, not submitting"
      return 1
    fi
  fi
  left="$(rc_input_text "$(capture "$p")")"
  if [ -n "$left" ] && [ -n "${CCAR_RESUME_CLEAR:-}" ]; then
    # shellcheck disable=SC2086 — clear keys are intentionally word-split key names
    txp "$p" send-keys -t "$pane" $CCAR_RESUME_CLEAR   # never leave residue behind
  fi
  return 0
}

rc_forget() { # $1 = paneref
  unset 'rc_missing_since[$1]' 'rc_next_attempt[$1]' 'rc_attempts[$1]'
}

rc_check() { # called once per idle poll; must never disturb the resume path
  rc_enabled || return 0
  [ "${#pane_latch[@]}" -eq 0 ] || return 0    # a real rate limit outranks this
  local now; now=$(now_epoch)
  [ $((now - rc_last_check)) -ge "${CCAR_RC_CHECK_SECONDS:-30}" ] || return 0
  rc_last_check=$now

  local p scr seen="" width since idx mins
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    seen="$seen|$p|"
    # Claude Code hides the indicator on a pane too narrow to fit it, so a narrow
    # pane tells us nothing — never act on that ambiguity.
    width="$(txp "$p" display-message -p -t "$(pr_pane "$p")" '#{pane_width}' 2>/dev/null)"
    case "$width" in ''|*[!0-9]*) continue ;; esac
    [ "$width" -ge "${CCAR_RC_MIN_WIDTH:-80}" ] || continue

    scr="$(capture "$p")"
    if rc_indicator_present "$scr"; then
      if [ -n "${rc_missing_since[$p]:-}" ]; then
        since="${rc_missing_since[$p]}"
        log "rc: remote control is connected again after $((now - since))s (${rc_attempts[$p]:-0} reconnect attempt(s)) — backoff reset"
      fi
      rc_forget "$p"
      continue
    fi

    # Indicator gone. Let Claude Code's own transport recovery have the first go.
    if [ -z "${rc_missing_since[$p]:-}" ]; then
      rc_missing_since[$p]=$now
      rc_next_attempt[$p]=$((now + ${CCAR_RC_GRACE_SECONDS:-120}))
      rc_attempts[$p]=0
      log "rc: remote control indicator missing on a pane — waiting ${CCAR_RC_GRACE_SECONDS:-120}s for Claude Code's own reconnect"
      continue
    fi
    [ "$now" -ge "${rc_next_attempt[$p]:-0}" ] || continue

    # Belt-and-suspenders: never type into a pane that is showing rate-limit UI.
    # scan_panes latches those within a poll, but this closes the race.
    if screen_shows_limit "$scr" || \
       { [ -n "${CCAR_LIMIT_PROMPT_REGEX:-}" ] && \
         rc_tail "$scr" | grep -E -i -q "$CCAR_LIMIT_PROMPT_REGEX"; }; then
      rc_next_attempt[$p]=$((now + ${CCAR_RC_BUSY_RETRY_SECONDS:-60}))
      continue
    fi
    # An empty input box and a screen that isn't repainting: the session is idle,
    # not mid-turn, and nothing is half-typed that our keys could ride along with.
    if ! rc_input_ready "$scr" ; then
      rc_next_attempt[$p]=$((now + ${CCAR_RC_BUSY_RETRY_SECONDS:-60}))
      log "rc: reconnect due but the pane's input box is busy or absent — retrying in ${CCAR_RC_BUSY_RETRY_SECONDS:-60}s"
      continue
    fi
    sleep "${CCAR_SETTLE_SECONDS:-2}"
    if [ "$(hash_of "$(capture "$p")")" != "$(hash_of "$scr")" ]; then
      rc_next_attempt[$p]=$((now + ${CCAR_RC_BUSY_RETRY_SECONDS:-60}))
      log "rc: reconnect due but the pane is still repainting (work in progress) — retrying in ${CCAR_RC_BUSY_RETRY_SECONDS:-60}s"
      continue
    fi

    since="${rc_missing_since[$p]}"
    idx=$(( ${rc_attempts[$p]:-0} + 1 ))
    if rc_send "$p"; then
      rc_attempts[$p]=$idx
      log "rc: indicator missing for $((now - since))s — sent ${CCAR_RC_COMMAND} (attempt $idx)"
    fi
    mins="$(rc_backoff_minutes "$idx")"
    rc_next_attempt[$p]=$((now + mins * 60))
  done <<<"$poll_panes"

  # Drop state for panes that are gone (closed, or no longer running claude).
  for p in "${!rc_missing_since[@]}"; do
    case "$seen" in *"|$p|"*) ;; *) rc_forget "$p" ;; esac
  done
}

parse_screen_time() { # $1: pane text, $2: true-now epoch; prints next-future epoch or nothing
  # Fallback only — used when the status line gave us no resets_at epoch. The
  # message is like "resets 4am (America/New_York)"; if a tz name is present we
  # interpret the clock time in THAT zone (so it's correct regardless of the
  # machine's timezone), else we fall back to local time. "now" is passed in as
  # the reconciled wall-clock epoch (not datetime.now()) so the "already passed ->
  # roll to tomorrow" logic stays correct even when the local clock has drifted.
  python3 - "$1" "$2" <<'PY'
import re, sys
from datetime import datetime, timedelta

text = sys.argv[1]
now_epoch = int(sys.argv[2])

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
now = datetime.fromtimestamp(now_epoch, tz)
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
  now=$(now_epoch)
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
  parsed="$(parse_screen_time "$screen" "$now")"
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
    refresh_poll_panes
    scan_panes   # a pane hitting the limit mid-wait still gets latched + its choice prompt answered promptly
    reconcile_clock   # rate-limited; keeps a long wait honest if the clock drifts
    now=$(now_epoch)
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
    # A sleep that took far longer than asked means the machine suspended. Force an
    # immediate clock reconcile (the guest clock may have frozen during suspend and
    # now lags real time) so the next iteration's now_epoch reflects true wall time
    # and we fire on schedule instead of waiting out a stale offset.
    if [ $((after - before)) -gt $((step + 30)) ]; then
      log "wall clock jumped ~$((after - before - step))s during wait (machine likely slept) — reconciling clock and re-checking reset"
      reconcile_clock force
    fi
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

claude_panes() { # $1 = newline-separated panerefs; keeps those whose foreground is claude
  local pr
  while IFS= read -r pr; do
    [ -z "$pr" ] && continue
    foreground_is_claude "$pr" && printf '%s\n' "$pr"   # never inject into a bare shell
  done <<<"$1"
}

# Answering "which panes are alive and running claude" costs two tmux round-trips
# per registered pane, and scan_panes, rc_check and the idle-exit check each used
# to ask independently — three walks per poll for an answer that cannot change
# within one. Walk once per poll here; every consumer reads the globals.
refresh_poll_panes() {
  poll_registry="$(registry_panerefs)"
  poll_panes="$(claude_panes "$poll_registry")"
}

unlatch_pane() { # $1 = paneref
  local p="$1"
  unset 'pane_latch[$p]' 'pane_snap[$p]' 'pane_snap_ok[$p]' 'pane_parked[$p]'
}

# Is the selection marker (❯) currently sitting on the "stop and wait" line?
# We isolate the menu line that IS the wait option (matches CCAR_LIMIT_PROMPT_REGEX)
# and check whether that exact line carries the marker. This is the ground truth
# for "pressing Enter now picks 'stop and wait'", independent of how many options
# the menu has or where the cursor happened to start.
prompt_wait_selected() { # $1 = screen text; returns 0 if the wait-option line is the selected one
  local line
  line="$(printf '%s\n' "$1" | grep -E -i "$CCAR_LIMIT_PROMPT_REGEX" | tail -n1)"
  [ -n "$line" ] || return 1
  printf '%s\n' "$line" | grep -E -q "${CCAR_LIMIT_PROMPT_MARKER:-^[[:space:]]*(❯|>)}"
}

# Newer Claude Code interposes a CHOICE prompt the instant the limit is hit, ahead
# of the normal pause screen:
#       What do you want to do?
#     ❯ 1. Stop and wait for limit to reset
#       2. Upgrade your plan
# While it's up it BLOCKS text entry, so a later resume "continue" can't land. We
# pick "Stop and wait" to fall through to the pause screen — the MOMENT we see the
# menu, NOT at reset time (this runs on every scan, and scan runs every poll).
#
# The menu WRAPS, so a fixed "Up Up" is unreliable: if the cursor didn't start
# where we assumed, wrapping can leave it on "Upgrade" and a blind Enter would
# select the wrong thing. Instead we STEP the selection and, after each keypress,
# re-read the pane to CONFIRM the marker (❯) landed on the wait line before we
# ever press Enter. If we can't get there within CCAR_LIMIT_PROMPT_MAX_NAV steps
# we do NOT confirm (better to leave the menu up for the next pass than to pick
# "Upgrade"). Stepping one key at a time and verifying also makes a false trigger
# safer than the old approach: on a screen that merely QUOTES the menu we send at
# most a few Ups and NEVER an Enter. A per-pane cooldown (set before we act, so it
# holds whether we confirmed or bailed) stops us from re-navigating the input box
# that returns afterward, and the caller vetoes entirely when usage reads clear.
dismiss_limit_prompt() { # $1 = paneref, $2 = its captured screen; returns 0 only if it confirmed
  [ -n "${CCAR_LIMIT_PROMPT_REGEX:-}" ] || return 1   # empty regex => feature disabled
  local p="$1" pane tail now last tries max
  tail="$(printf '%s\n' "$2" | grep -v '^[[:space:]]*$' | tail -n "${CCAR_PROMPT_TAIL_LINES:-15}")"
  [ -n "$tail" ] && printf '%s\n' "$tail" | grep -E -i -q "$CCAR_LIMIT_PROMPT_REGEX" || return 1
  now=$(now_epoch); last="${prompt_last_dismiss[$p]:-0}"
  [ $((now - last)) -lt "${CCAR_PROMPT_COOLDOWN_SECONDS:-15}" ] && return 1  # acted on it recently
  prompt_last_dismiss[$p]=$now       # one attempt per cooldown, whether we confirm or bail
  pane="$(pr_pane "$p")"
  max="${CCAR_LIMIT_PROMPT_MAX_NAV:-6}"
  for ((tries = 0; tries < max; tries++)); do
    if prompt_wait_selected "$(capture "$p")"; then
      txp "$p" send-keys -t "$pane" "${CCAR_LIMIT_PROMPT_CONFIRM:-Enter}"
      return 0
    fi
    # shellcheck disable=SC2086 — nav step is an intentionally word-split key name
    txp "$p" send-keys -t "$pane" ${CCAR_LIMIT_PROMPT_NAV_STEP:-Up}
    sleep "${CCAR_LIMIT_PROMPT_NAV_PAUSE:-0.3}"   # let the menu redraw the new selection
  done
  log "rate-limit menu up but the marker never landed on 'stop and wait' in $max steps — not confirming this pass"
  return 1
}

# One pass over every claude pane: answer choice prompts and update the latches.
# Called on every poll of the main loop AND every iteration of a wait, so a pane
# that pauses mid-wait is still caught, and a latched pane's snapshot tracks the
# last screen that positively looked paused (robust to redraws/resizes while the
# pause message stays visible). A fresh sub-limit usage reading vetoes BOTH the
# prompt answer and the text latch — that is what stops a conversation that
# merely displays the limit phrase (or quotes the choice menu) from triggering
# key injection while the account is demonstrably not limited.
scan_panes() {
  local p scr ustate was busy_file
  attached=()                # re-probe each scan: attaching must light the indicator back up
  refresh_state_cache        # main-shell context, so the mtime cache persists across polls
  ustate="$(usage_state)"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    publish_busy "$p"
    # Every consumer of $scr below is gated on the account looking limited or on
    # this pane already being latched. With a clear reading and no latch — the
    # normal state — capturing it is a tmux round-trip whose result is discarded.
    scr=""
    if [ "$ustate" != clear ] || [ -n "${pane_latch[$p]:-}" ]; then
      scr="$(capture "$p")"
    fi
    if [ "$ustate" != clear ] && dismiss_limit_prompt "$p" "$scr"; then
      [ "${pane_latch[$p]:-}" ] || log "rate-limit choice prompt on a pane — selected 'Stop and wait'; latched it as limited"
      pane_latch[$p]=seen
      pane_parked[$p]=1                   # answered its own prompt — it will resume
      continue   # screen is mid-redraw; snapshot it on the next pass
    fi
    was="${pane_latch[$p]:-}"
    if [ "$ustate" != clear ] && screen_shows_limit "$scr"; then
      [ "$was" = seen ] || log "pane latched as limited (pause message on screen)"
      pane_latch[$p]=seen
      pane_parked[$p]=1                   # pause message on its own screen — it will resume
      pane_snap[$p]="$(hash_of "$scr")"
      pane_snap_ok[$p]=1                  # snapshot of an actual pause screen — trusted
    elif [ "$ustate" = limited ] && [ -z "$was" ]; then
      log "pane latched as limited (account usage >= ${CCAR_LIMIT_PCT:-95}%)"
      pane_latch[$p]=usage
      # Latched by account-wide usage alone. Only park it (and show the hourglass)
      # if the pause message is actually in its scrollback — the same history test
      # should_resume() gates a usage latch on. An idle pane that was never paused
      # is latched for safety but stays unparked, so it keeps its own idle glyph.
      history_shows_limit "$p" && pane_parked[$p]=1
      pane_snap[$p]="$(hash_of "$scr")"
      pane_snap_ok[$p]=0                  # provisional until the screen settles
    elif [ -n "$was" ] && [ "${pane_snap_ok[$p]:-0}" != 1 ]; then
      # Latched without ever seeing the pause message on screen (usage/prompt
      # latch): chase the screen until two consecutive scans agree, then freeze
      # the snapshot. A pane still repainting at latch time would otherwise pin
      # a mid-paint snapshot and the resume gate would see phantom activity.
      if [ -n "${pane_snap[$p]:-}" ] && [ "$(hash_of "$scr")" = "${pane_snap[$p]}" ]; then
        pane_snap_ok[$p]=1
      else
        pane_snap[$p]="$(hash_of "$scr")"
        pane_snap_ok[$p]=0
      fi
    fi
  done <<<"$poll_panes"
  # A pane that dies mid-turn would otherwise stay "working" forever, animating a
  # window that is gone and pinning the taskbar glyph on. Also drop its hook
  # state file: a kill -9'd claude never fires SessionEnd, so this prune loop is
  # the only reaper for it.
  local live=$'\n'"$poll_panes"$'\n'
  for p in "${!pane_busy[@]}"; do
    case "$live" in
      *$'\n'"$p"$'\n'*) ;;
      *)
        unset 'pane_busy[$p]' 'pane_busy_snap[$p]' 'pane_hook_veto[$p]' 'pane_hook_veto_logged[$p]'
        busy_file="${CCAR_BUSY_DIR:-$CCAR_STATE_DIR/busy}/$(pane_key "$p")"
        rm -f "$busy_file" "$busy_file.sub" "$(dirname "$busy_file")/.$(basename "$busy_file").sublock" 2>/dev/null
        ;;
    esac
  done
  publish_any_busy    # poll_sleep skips its own call when the animation is off
}

# Resume gate, evaluated per latched pane at reset time. Resume when:
#   a) the pause message is on the visible screen AND the screen is static
#      (double-capture CCAR_SETTLE_SECONDS apart) — a paused TUI is frozen,
#      active work repaints every second; or
#   b) the screen is byte-identical to the snapshot from when it last looked
#      paused — untouched since the pause, even if UI chrome hides the message;
#      a usage-only latch (no per-pane evidence ever) additionally needs the
#      message in recent history, so an idle pane that was never interrupted
#      is not injected just because the account was limited.
# Anything else means the pane changed since it was paused (user typed, resumed
# by hand, new output) — skip it rather than inject into work we can't see.
should_resume() { # $1 = paneref
  local p="$1" scr h
  scr="$(capture "$p")"
  h="$(hash_of "$scr")"
  if screen_shows_limit "$scr"; then
    sleep "${CCAR_SETTLE_SECONDS:-2}"
    [ "$(hash_of "$(capture "$p")")" = "$h" ] && return 0
    return 1   # showing the message but repainting => active work; never inject
  fi
  if [ "${pane_snap_ok[$p]:-0}" = 1 ] && [ "$h" = "${pane_snap[$p]:-}" ]; then
    [ "${pane_latch[$p]}" = seen ] && return 0
    history_shows_limit "$p" && return 0
  fi
  return 1
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
  refresh_poll_panes
  if [ -z "$poll_registry" ]; then
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

  reconcile_clock   # rate-limited; ensures compute_wait sees a true "now"
  install_busy_format
  scan_panes
  if [ "${#pane_latch[@]}" -gt 0 ]; then
    # Any latched pane's screen feeds the pane-text time fallback in compute_wait.
    first=""
    for p in "${!pane_latch[@]}"; do first="$p"; break; done
    read -r target mode <<<"$(compute_wait "$(capture "$first")")"
    log "limit latched on ${#pane_latch[@]} pane(s); waiting until $(date -d "@$target" '+%F %T') ($mode)"
    if ! wait_until "$target" "$mode"; then
      rm -f "$CANCEL_FILE"
      status_clear
      log "cancelled during wait — monitor exiting (cc-run restarts it)"
      exit 0
    fi
    # The latch set is the resume set — panes limited at detection or that latched
    # during the wait. A pane opened during the wait never latches (no evidence),
    # so it is never injected; a latched pane that died is dropped here.
    resumed=""
    for p in "${!pane_latch[@]}"; do
      if ! pane_alive "$p"; then unlatch_pane "$p"; continue; fi
      if should_resume "$p"; then
        send_resume "$p"
        resumed+="$p"$'\n'
      else
        log "skipping a latched pane: screen changed since the pause and no limit message is visible (resumed by hand?)"
        unlatch_pane "$p"
      fi
    done
    resumed="${resumed%$'\n'}"
    if [ -z "$resumed" ]; then
      backoff_idx=0
      status_clear
      log "no latched pane needed a resume"
    else
      log "resume sent to $(count "$resumed") pane(s)"
      sleep "${CCAR_GRACE_SECONDS:-15}"
      # A pane whose screen still shows the pause message did not un-pause: keep
      # its latch so the next pass retries (compute_wait escalates to backoff on a
      # stale resets_at). A pane that repainted is running again — unlatch it.
      stuck=0
      while IFS= read -r p; do
        [ -z "$p" ] && continue
        if pane_alive "$p" && screen_shows_limit "$(capture "$p")"; then
          stuck=$((stuck + 1))
        else
          unlatch_pane "$p"
        fi
      done <<<"$resumed"
      if [ "$stuck" -gt 0 ]; then
        backoff_idx=$((backoff_idx + 1))
        log "still limited after resume ($stuck pane(s)) — escalating backoff (idx $backoff_idx)"
      else
        backoff_idx=0
        status_clear
        log "resumed $(count "$resumed") pane(s)"
      fi
    fi
  elif [ "$status_active" -eq 1 ]; then
    # Nothing is latched, but a countdown is still painted — the limit cleared on
    # its OWN (e.g. the window reset after a failed resume escalated to backoff),
    # so none of the resume/resolution paths above ran to wipe it. Clear it now so
    # the tab doesn't keep showing a stale "resume HH:MM" long after the reset.
    status_clear
    log "no active limit but a countdown was still shown — cleared it"
  fi
  burn_check
  rc_check
  stats_polls=$(( stats_polls + 1 ))
  stats_emit
  poll_sleep
done
