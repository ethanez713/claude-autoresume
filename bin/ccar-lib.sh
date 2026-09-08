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
