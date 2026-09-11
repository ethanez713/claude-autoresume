#!/usr/bin/env bash
# Shared helpers for the claude-autoresume commands. Sourced, never executed;
# expects config.sh to already be sourced and $here to point at the repo root.

# Pane registry: one file per Claude pane, read by the monitor. Tab-separated
# fields <socket_path>\t<session>\t<pane_id>\t<dir>; atomic write, 0600. Keyed by
# socket+pane (pane ids are only unique within a server).
register_pane() {  # $1=socket_path $2=session $3=pane_id $4=dir
  local key tmp
  key="$(printf '%s:%s' "$1" "$3" | tr -c 'A-Za-z0-9._-' '_')"
  tmp="$CCAR_PANES_DIR/.$key.$$"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$CCAR_PANES_DIR/$key"
}

# Start the account-wide monitor if not already running.
start_monitor() {
  local pidfile="$CCAR_STATE_DIR/monitor.pid"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "Monitor already running (pid $(cat "$pidfile"))."
  else
    CCAR_CONFIG="${CCAR_CONFIG:-$here/config.sh}" nohup "$here/bin/monitor.sh" >/dev/null 2>&1 &
    echo $! >"$pidfile"
    echo "Monitor started (pid $!). Log: $CCAR_LOG"
  fi
}

# Registry rows for panes on a socket whose server is gone. Their pane ids get
# handed out again by the next session on that socket, so a row left behind would
# point the monitor at a pane it does not own.
forget_dead_panes() {
  local f socket
  find "$CCAR_PANES_DIR" -maxdepth 1 -type f -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
      IFS=$'\t' read -r socket _ <"$f" || continue
      [ "$(basename -- "$socket")" = "$CCAR_TMUX_SOCKET" ] && rm -f "$f"
    done
}

# Whether an invocation can be satisfied by a window this directory already has
# open. A bare `claude` and `claude -c` both mean "take me back to it"; a prompt
# to deliver, a session picker, or any other option is asking for something the
# running window cannot give.
wants_rejoin() { # $@ = the launcher's own arguments
  local a
  for a in "$@"; do
    case "$a" in
      -c|--continue) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# What the monitor's @ccar_busy says a pane is doing, in words (see config.sh).
busy_label() { # $1 = @ccar_busy
  case "$1" in
    1)     printf 'working' ;;
    sub)   printf 'idle, subagents still working' ;;
    limit) printf 'parked at the rate limit' ;;
    *)     printf 'idle' ;;
  esac
}

# --- reconstruction: reopen the Claude tabs of a server that is gone ----------
# The pane registry is the record of what was open. The monitor's
# registry_panerefs() drops a row the instant its pane dies, so while anything is
# running the registry tracks the live set; when the server dies WITH the monitor
# (reboot, wsl --shutdown, a crash) it freezes at exactly the set that was open.
# That is what we reopen — and because rows are written for every server a Claude
# pane ran on, not just the ccar fallback, this brings back tabs from the
# operator's own tmux too (a conversation is keyed by its directory, so the tmux
# server it used to live in does not matter).

# Whether socket+pane still exists on a REACHABLE server. A dead server's socket
# just yields nothing, so its rows read as not-live — the ones we reopen.
pane_is_live() { # $1 = socket path, $2 = pane id
  tmux -S "$1" list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$2"
}

# Claude Code files a conversation under a slug of its directory, every character
# outside [A-Za-z0-9-] folded to a dash. No transcript there means `claude -c`
# would fail, so such a window opens a fresh conversation instead.
transcript_count() { # $1 = dir; echoes how many .jsonl transcripts that dir has
  local slug
  slug="$(printf '%s' "$1" | tr -c 'A-Za-z0-9-' '-')"
  set -- "$HOME/.claude/projects/$slug"/*.jsonl
  if [ -e "$1" ]; then printf '%s' "$#"; else printf '0'; fi
}

# Directories to reopen, one per line: every registry row whose pane is NOT still
# live somewhere (so we never duplicate a tab a surviving server still shows),
# whose directory still exists, deduped, oldest registration first so windows
# come back roughly in the order they were opened.
reconstruct_candidates() {
  local f socket session pane dir
  [ -d "$CCAR_PANES_DIR" ] || return 0
  while IFS= read -r f; do
    [ -e "$CCAR_PANES_DIR/$f" ] || continue
    IFS=$'\t' read -r socket session pane dir <"$CCAR_PANES_DIR/$f" || continue
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    pane_is_live "$socket" "$pane" && continue
    printf '%s\n' "$dir"
  done < <(ls -1tr "$CCAR_PANES_DIR" 2>/dev/null) | awk '!seen[$0]++'
}
