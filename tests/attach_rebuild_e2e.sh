#!/usr/bin/env bash
# End-to-end: cc-attach rebuilding a dead fallback session. Runs a real tmux
# server on a throwaway socket with a stub `claude` on PATH, so it exercises the
# window creation, the launch command and the registry write without touching the
# operator's session or spending tokens. Run: tests/attach_rebuild_e2e.sh
set -u
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want: %q\n       got:  %q\n' "$3" "$2"; }; }

tmp="$(mktemp -d)"
sock="ccar-e2e-$$"
export TMUX_TMPDIR="$tmp"   # so the named socket lands under $tmp and goes with it
cleanup() {
  local pidfile="$tmp/state/monitor.pid"
  [ -f "$pidfile" ] && kill "$(cat "$pidfile")" 2>/dev/null
  tmux -L "$sock" kill-server 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

export HOME="$tmp/home"          # no ~/.bashrc here, so the pane's `claude` is the stub
mkdir -p "$HOME" "$tmp/state/panes" "$tmp/bin"
# The fallback server sources ~/.tmux.conf, and cc-attach deliberately re-enables
# automatic-rename so the live glyph can track. Name windows off the directory
# here, standing in for the operator's own glyph+directory format.
printf '%s\n' "set -g automatic-rename on" \
  "set -g automatic-rename-format '#{b:pane_current_path}'" > "$HOME/.tmux.conf"
alpha="$tmp/alpha"; beta="$tmp/beta"
mkdir -p "$alpha" "$beta"

# One directory has a saved conversation and one does not, so the run has to pick
# `claude -c` for the first and a plain `claude` for the second.
mkdir -p "$HOME/.claude/projects/$(printf '%s' "$alpha" | tr -c 'A-Za-z0-9-' '-')"
touch "$HOME/.claude/projects/$(printf '%s' "$alpha" | tr -c 'A-Za-z0-9-' '-')/a.jsonl"

cat > "$tmp/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$PWD/.argv"
exec sleep 600
STUB
chmod +x "$tmp/bin/claude"
export PATH="$tmp/bin:$PATH"

cat > "$tmp/config.sh" <<EOF
source "$repo/config.sh"
CCAR_TMUX_SOCKET="$sock"
CCAR_TMUX_SESSION="e2e"
CCAR_STATE_DIR="$tmp/state"
CCAR_PANES_DIR="$tmp/state/panes"
CCAR_STATE_JSON="$tmp/state/state.json"
CCAR_STATS_JSONL="$tmp/state/stats.jsonl"
CCAR_LOG="$tmp/state/monitor.log"
CCAR_OUTER_TERM=""
EOF
export CCAR_CONFIG="$tmp/config.sh"

row() { printf '%s\t%s\t%s\t%s\n' "$1" e2e "$2" "$3" > "$tmp/state/panes/$4"; }
row "/tmp/tmux-1000/$sock" %0 "$alpha" r0
row "/tmp/tmux-1000/$sock" %1 "$beta"  r1

echo "rebuild"
unset TMUX
"$repo/bin/cc-attach" -y </dev/null >"$tmp/out" 2>&1 || true   # the final attach has no tty
sleep 6

eq "the session is back" "$(tmux -L "$sock" has-session -t e2e 2>&1 && echo yes)" "yes"
eq "with one window per registered directory" \
   "$(tmux -L "$sock" list-windows -t e2e -F '#{window_name}' | tr '\n' ' ')" "alpha beta "
eq "each window keeps its directory tag" \
   "$(tmux -L "$sock" list-windows -t e2e -F '#{@ccar_dir}' | tr '\n' ' ')" "$alpha $beta "
eq "the directory with a transcript continues it" "$(cat "$alpha/.argv" 2>&1)" "-c"
eq "the one without starts fresh"                 "$(cat "$beta/.argv" 2>&1)"  ""
eq "the cancel key is bound on the new server" \
   "$(tmux -L "$sock" list-keys 2>/dev/null | grep -c cc-cancel)" "1"

echo
echo "registry"
new_rows="$(cat "$tmp"/state/panes/* 2>/dev/null | grep -c "$sock")"
eq "one fresh row per rebuilt pane" "$new_rows" "2"
eq "rows for the dead panes are gone" \
   "$(cat "$tmp"/state/panes/* 2>/dev/null | grep -c "	%0	$alpha\$")" "1"

echo
echo "already up"
out="$("$repo/bin/cc-attach" -y </dev/null 2>&1 || true)"
case "$out" in
  *"not a terminal"*|*"open terminal failed"*|*"no current client"*) ok "a live server is attached, not rebuilt" ;;
  *) bad "a live server is attached, not rebuilt"; printf '       got: %q\n' "$out" ;;
esac
eq "and it did not open more windows" \
   "$(tmux -L "$sock" list-windows -t e2e -F '#{window_name}' | wc -l)" "2"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
