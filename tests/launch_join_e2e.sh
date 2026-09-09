#!/usr/bin/env bash
# End-to-end: what `claude` does from a plain shell when a wrapped session is
# already running. Drives the real launcher from a pty (a driver tmux server) so
# its prompt is reachable, against a throwaway ccar socket and a stub `claude`.
# Run: tests/launch_join_e2e.sh
set -u
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want: %q\n       got:  %q\n' "$3" "$2"; }; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1"; printf '       screen has no %q\n' "$3" ;; esac; }

tmp="$(mktemp -d)"
export TMUX_TMPDIR="$tmp"        # both servers' sockets live under $tmp
sock="ccar-join-$$"
drv="drv-join-$$"
cleanup() {
  [ -f "$tmp/state/monitor.pid" ] && kill "$(cat "$tmp/state/monitor.pid")" 2>/dev/null
  tmux -L "$drv" kill-server 2>/dev/null
  tmux -L "$sock" kill-server 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

export HOME="$tmp/home"
mkdir -p "$HOME" "$tmp/state/panes" "$tmp/bin"
printf '%s\n' "set -g automatic-rename on" \
  "set -g automatic-rename-format '#{b:pane_current_path}'" > "$HOME/.tmux.conf"
alpha="$tmp/alpha"; beta="$tmp/beta"; mkdir -p "$alpha" "$beta"

cat > "$tmp/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PWD/.argv"
exec sleep 300
STUB
chmod +x "$tmp/bin/claude"
export PATH="$tmp/bin:$PATH"

cat > "$tmp/config.sh" <<EOF
source "$repo/config.sh"
CCAR_TMUX_SOCKET="$sock"
CCAR_TMUX_SESSION="join"
CCAR_STATE_DIR="$tmp/state"
CCAR_PANES_DIR="$tmp/state/panes"
CCAR_STATE_JSON="$tmp/state/state.json"
CCAR_STATS_JSONL="$tmp/state/stats.jsonl"
CCAR_LOG="$tmp/state/monitor.log"
CCAR_OUTER_TERM=""
EOF
export CCAR_CONFIG="$tmp/config.sh"

tmux -L "$drv" new-session -d -s d -x 150 -y 45 -c "$tmp"
sleep 1

# Run the launcher from a driver pane: a pty, so it takes the wrapped path and
# can prompt. $1 = cwd, $2... = launcher args.
dw=""
launch() {
  local cwd="$1"; shift
  [ -n "$dw" ] && tmux -L "$drv" kill-window -t "$dw" 2>/dev/null
  dw="$(tmux -L "$drv" new-window -P -F '#{window_id}' -t d -c "$cwd")"
  sleep 1
  tmux -L "$drv" send-keys -t "$dw" "env -u TMUX '$repo/bin/cc-run' $*" Enter
  sleep 4
}
screen() { tmux -L "$drv" capture-pane -p -t "$dw"; }
answer() { tmux -L "$drv" send-keys -t "$dw" "$1" Enter; sleep 5; }
windows() { tmux -L "$sock" list-windows -t join -F '#{@ccar_dir}' 2>/dev/null | tr '\n' ' '; }

echo "no session yet"
launch "$alpha"
eq "starts one without asking anything" "$(windows)" "$alpha "
case "$(screen)" in
  *"already running"*) bad "and does not show the join prompt" ;;
  *) ok "and does not show the join prompt" ;;
esac

echo
echo "a session is running, launched from another directory"
launch "$beta"
has "the running windows are listed" "$(screen)" "$alpha"
has "with what each pane is doing"   "$(screen)" "idle"
has "Y opens a window here"          "$(screen)" "attach, and open a window for $beta"
has "N says what it ends"            "$(screen)" "end that session"
answer y
eq "y keeps the old window and adds this one" "$(windows)" "$alpha $beta "

echo
echo "a session is running, launched from a directory it already has"
launch "$alpha"
has "the prompt marks the window you are standing in" "$(screen)" "<- you are here"
has "and Y rejoins it rather than opening another"    "$(screen)" "attach, on this directory's own window"
answer y
eq "y opens no second window for the directory" "$(windows)" "$alpha $beta "
eq "and does not start a second claude there"   "$(wc -l < "$alpha/.argv")" "1"

echo
echo "declining"
launch "$beta"
answer n
eq "n ends the session and starts over with just this directory" "$(windows)" "$beta "
eq "the registry keeps one row, for the new pane" \
   "$(cat "$tmp"/state/panes/* 2>/dev/null | grep -c "$sock")" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
