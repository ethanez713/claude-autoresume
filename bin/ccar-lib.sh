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
# whose directory still exists, deduped to one window each. Ordered by pane
# number, which tmux hands out in sequence, so windows come back roughly in the
# order they were opened (read as a number: a lexical sort puts %10 before %2).
# Registry-file mtime can't do this — /tmp here has second-granularity mtimes, so
# tabs opened in the same second would order arbitrarily.
reconstruct_candidates() {
  local f socket session pane dir
  [ -d "$CCAR_PANES_DIR" ] || return 0
  for f in "$CCAR_PANES_DIR"/*; do
    [ -e "$f" ] || continue
    IFS=$'\t' read -r socket session pane dir <"$f" || continue
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    pane_is_live "$socket" "$pane" && continue
    printf '%s\t%s\n' "${pane#%}" "$dir"
  done | sort -n -k1,1 | awk -F'\t' '!seen[$2]++ { print $2 }'
}

# --- interactive pick-list ---------------------------------------------------
# One selection state transition, kept pure so it is testable with no terminal.
# State is a cursor index and a string of one 0/1 flag per item ("selected").
# Echoes the next state and an action: "<cursor> <sel> none|confirm|cancel".
tui_apply_key() { # $1=n $2=cursor $3=sel $4=key
  local n="$1" cur="$2" sel="$3" key="$4" action=none i out=""
  case "$key" in
    up)     cur=$(( (cur - 1 + n) % n )) ;;
    down)   cur=$(( (cur + 1) % n )) ;;
    toggle) for ((i = 0; i < n; i++)); do
              if [ "$i" -eq "$cur" ]; then
                [ "${sel:$i:1}" = 1 ] && out+=0 || out+=1
              else out+="${sel:$i:1}"; fi
            done; sel="$out" ;;
    all)    sel=""; for ((i = 0; i < n; i++)); do sel+=1; done ;;
    none)   sel=""; for ((i = 0; i < n; i++)); do sel+=0; done ;;
    confirm) action=confirm ;;
    cancel)  action=cancel ;;
  esac
  printf '%s %s %s' "$cur" "$sel" "$action"
}

# Read one keypress from fd 3 and map it to a tui_apply_key token. Arrow keys
# arrive as a 3-byte escape sequence (ESC [ A/B); we read the tail only after
# seeing ESC-[ so a lone ESC still reads as cancel.
_tui_readkey() {
  local a b c
  IFS= read -rsn1 a <&3 || { printf 'cancel'; return; }
  case "$a" in
    $'\x1b') IFS= read -rsn1 -t 0.05 b <&3
             if [ "$b" = '[' ]; then
               IFS= read -rsn1 -t 0.05 c <&3
               case "$c" in A) printf 'up' ;; B) printf 'down' ;; *) printf 'none' ;; esac
             else printf 'cancel'; fi ;;
    ' ')        printf 'toggle' ;;
    k|K)        printf 'up' ;;
    j|J)        printf 'down' ;;
    a|A)        printf 'all' ;;
    n|N)        printf 'none' ;;
    q|Q)        printf 'cancel' ;;
    ''|$'\r'|$'\n') printf 'confirm' ;;  # Enter: CR in raw mode, empty when read hits the newline delimiter
    *)          printf 'none' ;;
  esac
}

# Draw the list on the terminal (fd 3). After the first frame it rewinds the
# cursor over its own output so each redraw lands in place.
_tui_render() { # $1=n $2=cursor $3=sel $4=drawn-before(0/1); items in $tui_items
  local n="$1" cur="$2" sel="$3" drawn="$4" i mark point
  [ "$drawn" = 1 ] && printf '\033[%dA' "$((n + 2))" >&3
  printf '\r\033[K  \033[1mReopen which sessions?\033[0m  ↑↓ move · space toggle · a all · n none · enter go · q cancel\n' >&3
  for ((i = 0; i < n; i++)); do
    [ "${sel:$i:1}" = 1 ] && mark='[\033[32mx\033[0m]' || mark='[ ]'
    [ "$i" -eq "$cur" ] && point='\033[1m›\033[0m' || point=' '
    printf '\r\033[K %b %b %s\n' "$point" "$mark" "${tui_items[$i]}" >&3
  done
  printf '\r\033[K\n' >&3
}

# Interactive multi-select. Items arrive one per line on stdin; the chosen ones
# are printed one per line on stdout; return 1 if the user cancels. All items
# start selected. With no controlling terminal (a pipe, cc-attach -y) it cannot
# prompt, so it selects everything and returns 0.
tui_multiselect() {
  local -a tui_items=(); local line n cur=0 sel="" i tok action drawn=0 saved
  while IFS= read -r line; do tui_items+=("$line"); done
  n=${#tui_items[@]}
  [ "$n" -gt 0 ] || return 1
  for ((i = 0; i < n; i++)); do sel+=1; done
  if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    printf '%s\n' "${tui_items[@]}"; return 0
  fi
  saved="$(stty -g <&3 2>/dev/null)"
  stty -echo -icanon <&3 2>/dev/null
  printf '\033[?25l' >&3   # hide cursor
  _tui_render "$n" "$cur" "$sel" "$drawn"; drawn=1
  while :; do
    tok="$(_tui_readkey)"
    read -r cur sel action <<<"$(tui_apply_key "$n" "$cur" "$sel" "$tok")"
    _tui_render "$n" "$cur" "$sel" "$drawn"
    case "$action" in confirm|cancel) break ;; esac
  done
  printf '\033[?25h' >&3   # show cursor
  [ -n "$saved" ] && stty "$saved" <&3 2>/dev/null
  exec 3>&- 3<&-
  [ "$action" = cancel ] && return 1
  for ((i = 0; i < n; i++)); do [ "${sel:$i:1}" = 1 ] && printf '%s\n' "${tui_items[$i]}"; done
}

# tmux on the ccar fallback socket.
cx() { tmux -L "$CCAR_TMUX_SOCKET" "$@"; }

# Build (or extend) the ccar fallback session with one window per directory, each
# launching claude -c where a conversation exists there and a fresh claude
# otherwise, then bind cancel, start the monitor, and focus $1's window (the
# first window when $1 is empty or unmatched). Shared by cc-attach's rebuild and
# cc-run's post-crash reopen. Does NOT attach — the caller does.
rebuild_session() { # $1 = dir to focus; $2.. = dirs to open, in order
  local focus="$1"; shift
  local dir name win first_win="" focus_win="" pane sock cmd
  umask 077
  mkdir -p "$CCAR_STATE_DIR" "$CCAR_PANES_DIR"
  chmod 700 "$CCAR_STATE_DIR" "$CCAR_PANES_DIR"
  forget_dead_panes
  for dir in "$@"; do
    name="$(basename -- "$dir")"; [ -n "$name" ] || name="/"
    if ! cx has-session -t "$CCAR_TMUX_SESSION" 2>/dev/null; then
      tmux -L "$CCAR_TMUX_SOCKET" -f "$CCAR_TMUX_CONF" \
        new-session -d -s "$CCAR_TMUX_SESSION" -c "$dir" -n "$name"
      win="$(cx display-message -p -t "$CCAR_TMUX_SESSION" '#{window_id}')"
    else
      win="$(cx new-window -P -F '#{window_id}' -t "$CCAR_TMUX_SESSION" -c "$dir" -n "$name")"
    fi
    [ -n "$first_win" ] || first_win="$win"
    [ "$dir" = "$focus" ] && focus_win="$win"
    cx set-option -w -t "$win" @ccar_dir "$dir"
    # Creating a window with -n freezes automatic-rename for it, which would pin
    # the static name and hide the live status glyph; restore the global setting.
    if [ "$(cx show-options -gv automatic-rename 2>/dev/null)" = "on" ]; then
      cx set-option -w -t "$win" automatic-rename on
    fi
    if [ "$(transcript_count "$dir")" -gt 0 ]; then cmd="exec claude -c"; else cmd="exec claude"; fi
    pane="$(cx display-message -p -t "$win" '#{pane_id}')"
    sock="$(cx display-message -p '#{socket_path}')"
    cx send-keys -t "$pane" -l "$cmd"
    cx send-keys -t "$pane" Enter
    register_pane "$sock" "$CCAR_TMUX_SESSION" "$pane" "$dir"
  done
  [ -n "$first_win" ] || return 1   # nothing built
  cx bind-key "$CCAR_CANCEL_KEY" run-shell "$here/bin/cc-cancel"
  start_monitor
  cx select-window -t "${focus_win:-$first_win}"
}
