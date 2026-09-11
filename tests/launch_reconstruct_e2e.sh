#!/usr/bin/env bash
# End-to-end: what `claude` does from a plain shell when the ccar server is GONE
# but the registry still names tabs from the last session. It should offer them
# in the pick-list and, on confirm, reopen them plus the directory you launched
# from. Driven from a pty (a driver tmux) so the picker is reachable.
# Run: tests/launch_reconstruct_e2e.sh
set -u
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want: %q\n       got:  %q\n' "$3" "$2"; }; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1"; printf '       screen has no %q\n' "$3" ;; esac; }

tmp="$(mktemp -d)"
export TMUX_TMPDIR="$tmp"
sock="ccar-recon-$$"
drv="drv-recon-$$"
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
alpha="$tmp/alpha"; beta="$tmp/beta"; gamma="$tmp/gamma"; mkdir -p "$alpha" "$beta" "$gamma"

# alpha has a saved conversation (so it reopens with `claude -c`); beta does not.
mkdir -p "$HOME/.claude/projects/$(printf '%s' "$alpha" | tr -c 'A-Za-z0-9-' '-')"
touch "$HOME/.claude/projects/$(printf '%s' "$alpha" | tr -c 'A-Za-z0-9-' '-')/a.jsonl"

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
CCAR_TMUX_SESSION="recon"
CCAR_STATE_DIR="$tmp/state"
CCAR_PANES_DIR="$tmp/state/panes"
CCAR_STATE_JSON="$tmp/state/state.json"
CCAR_STATS_JSONL="$tmp/state/stats.jsonl"
CCAR_LOG="$tmp/state/monitor.log"
CCAR_OUTER_TERM=""
EOF
export CCAR_CONFIG="$tmp/config.sh"

# The registry as the dead server left it: two tabs, on a socket with no server
# behind it (so reconstruct_candidates reads them as not-live and reopenable).
dead="$tmp/tmux-1000/gone-$$"
row() { printf '%s\t%s\t%s\t%s\n' "$dead" recon "$1" "$2" > "$tmp/state/panes/$3"; }
row %0 "$alpha" r0
row %1 "$beta"  r1

tmux -L "$drv" new-session -d -s d -x 150 -y 45 -c "$tmp"
sleep 1

dw="$(tmux -L "$drv" new-window -P -F '#{window_id}' -t d -c "$gamma")"
sleep 1
screen()  { tmux -L "$drv" capture-pane -p -t "$dw"; }
windows() { tmux -L "$sock" list-windows -t recon -F '#{@ccar_dir}' 2>/dev/null | tr '\n' ' '; }

echo "server gone, registry names other tabs"
# Launch a bare `claude` from gamma (a directory not in the registry). It should
# show the picker with alpha, beta AND gamma.
tmux -L "$drv" send-keys -t "$dw" "env -u TMUX '$repo/bin/cc-run'" Enter
sleep 4
scr="$(screen)"
has "announces it is reopening the last session" "$scr" "reopening the Claude tabs"
has "offers the dead server's alpha tab"          "$scr" "alpha"
has "offers the dead server's beta tab"           "$scr" "beta"
has "offers the directory you launched from"      "$scr" "gamma"

# Confirm with everything selected (the default).
tmux -L "$drv" send-keys -t "$dw" Enter
sleep 5

eq "reopens one window per tab, launch dir last" "$(windows)" "$alpha $beta $gamma "
eq "the tab with a conversation continues it"   "$(cat "$alpha/.argv" 2>/dev/null | tr -d '\n')" "-c"
eq "the tab without one starts fresh"           "$(cat "$beta/.argv"  2>/dev/null | tr -d '\n')" ""
eq "the launch directory starts fresh"          "$(cat "$gamma/.argv" 2>/dev/null | tr -d '\n')" ""
eq "and it lands focused on the launch directory" \
   "$(tmux -L "$sock" display-message -p -t recon '#{@ccar_dir}')" "$gamma"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
