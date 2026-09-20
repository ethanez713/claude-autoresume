#!/usr/bin/env bash
# End-to-end: a real monitor.sh process drives the working glyph onto a real
# tmux tab. The unit tests call install_busy_format / publish_busy directly, so
# they cannot catch a break in the LOOP that is supposed to call them — which is
# exactly how the "glyph never showed after a server rebuild" regression shipped.
# This boots the monitor against a throwaway socket, flags a pane busy through
# the hook state file (no attached client needed, so no tty and no scrape), and
# asserts the rendered tab. Run: tests/busy_glyph_e2e.sh
set -u
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want: %q\n       got:  %q\n' "$3" "$2"; }; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1"; printf '       %q has no %q\n' "$2" "$3" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1"; printf '       %q still has %q\n' "$2" "$3" ;; *) ok "$1" ;; esac; }

tmp="$(mktemp -d)"
sock="glyph-e2e-$$"
export TMUX_TMPDIR="$tmp"
export HOME="$tmp/home"; mkdir -p "$HOME"
: > "$HOME/.tmux.conf"   # a bare, predictable server config

cleanup() {
  [ -f "$tmp/state/monitor.pid" ] && kill "$(cat "$tmp/state/monitor.pid")" 2>/dev/null
  tmux -L "$sock" kill-server 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/state/panes" "$tmp/state/busy" "$tmp/bin"
# The monitor only *resumes* panes whose foreground command is claude/node
# (CCAR_FOREGROUND_CMDS). Glyphs also follow grok, discovered by command name
# on the same socket. Copies of `sleep` named `claude`/`grok` block a pane open
# with the right pane_current_command, no tokens spent.
cp "$(command -v sleep)" "$tmp/bin/claude"
cp "$(command -v sleep)" "$tmp/bin/grok"
export PATH="$tmp/bin:$PATH"
cat > "$tmp/config.sh" <<EOF
source "$repo/config.sh"
CCAR_TMUX_SOCKET="$sock"
CCAR_TMUX_SESSION="e2e"
CCAR_STATE_DIR="$tmp/state"
CCAR_PANES_DIR="$tmp/state/panes"
CCAR_BUSY_DIR="$tmp/state/busy"
CCAR_STATE_JSON="$tmp/state/state.json"
CCAR_STATS_JSONL="$tmp/state/stats.jsonl"
CCAR_LOG="$tmp/state/monitor.log"
CCAR_POLL_SECONDS=1
CCAR_OUTER_TERM=""
EOF
export CCAR_CONFIG="$tmp/config.sh"
socket_path=""   # the real path tmux gives the -L socket; set once the server is up

tm() { tmux -L "$sock" "$@"; }

# Stand up a session with one window named as Claude's title leaves it (a ✳ and
# the dir), and a stock window-status-format with a #W anchor to splice. Sets the
# globals $pane and $socket_path — the real path tmux derives from $TMUX_TMPDIR +
# the -L name, which the monitor's registry rows must carry. Called plain, never
# in a command substitution: a subshell would swallow the assignments.
pane=""
build_server() {
  tm -f "$HOME/.tmux.conf" new-session -d -s e2e -n '✳ work' 'claude 600'
  tm set-option -g window-status-format '#I:#W'
  tm set-option -g window-status-current-format '#I:#W'
  socket_path="$(tm display-message -p '#{socket_path}')"
  pane="$(tm list-panes -t e2e -F '#{pane_id}' | head -1)"
}

# The hook state file the monitor reads as the primary busy signal (bin/cc-busy-hook
# writes it). "1" = a turn is running; "0" = idle.
set_busy() { # $1 = pane id, $2 = 0|1
  local key; key="$(printf '%s:%s' "$socket_path" "$1" | tr -c 'A-Za-z0-9._-' '_')"
  printf '%s\t%s\n' "$2" "$(date +%s)" > "$tmp/state/busy/$key"
}
register() { # $1 = pane id
  printf '%s\t%s\t%s\t%s\n' "$socket_path" e2e "$1" "$tmp" > "$tmp/state/panes/r0"
}
rendered() { tm display-message -p -t e2e:0 '#{T:window-status-format}'; }

# Poll until $1 evaluates true, up to ~$2 seconds; keeps the test fast when the
# monitor reacts in one poll and honest when a machine is slow.
wait_for() { # $1 = predicate command string, $2 = seconds
  local i=0
  while ! eval "$1" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -ge "$(( ${2:-10} * 2 ))" ] && return 1
    sleep 0.5
  done
}

build_server
register "$pane"
set_busy "$pane" 1

echo "monitor start"
CCAR_CONFIG="$tmp/config.sh" nohup "$repo/bin/monitor.sh" >/dev/null 2>&1 &
echo $! > "$tmp/state/monitor.pid"

wait_for '[ "$(tm show-options -w -t e2e:0 -v @ccar_busy 2>/dev/null)" = 1 ]' 10
eq  "the busy flag reaches the window"          "$(tm show-options -w -t e2e:0 -v @ccar_busy)" "1"
has "the window list format is patched"         "$(tm show-options -gv window-status-format)" '@ccar_busy'
wait_for '! rendered | grep -q ✳' 10
hasnt "a working tab drops the idle ✳"          "$(rendered)" "✳"
has  "and keeps the window text"                "$(rendered)" "work"

echo
echo "rebuild under a live monitor"
# The regression: a kill-server + rebuild from cc-run/cc-attach leaves the
# monitor running, and the rebuilt server comes up with stock formats. Everything
# a rebuild wipes is server-lifetime state, so reproduce exactly that — reset the
# formats and drop @ccar_fmt_sig plus the stashes — in place, keeping the pane
# alive. This is deterministic (a real kill + immediate recreate on the same
# socket races its own teardown) and is the precise state the monitor must heal:
# an in-memory "already patched" flag would leave the glyph gone for good.
tm set-option -g window-status-format '#I:#W'
tm set-option -g window-status-current-format '#I:#W'
tm set-option -gu @ccar_fmt_sig
tm set-option -gu @ccar_orig_window-status-format 2>/dev/null
tm set-option -gu @ccar_orig_window-status-current-format 2>/dev/null
eq "the rebuilt server starts with a stock format" "$(tm show-options -gv window-status-format)" '#I:#W'
wait_for 'tm show-options -gv window-status-format | grep -q @ccar_busy' 10
has "the monitor re-patches the stock format"   "$(tm show-options -gv window-status-format)" '@ccar_busy'
wait_for '! rendered | grep -q ✳' 10
hasnt "the glyph returns after the rebuild"     "$(rendered)" "✳"
has  "on the window's text"                     "$(rendered)" "work"

echo
echo "turn ends"
set_busy "$pane" 0
wait_for '[ "$(tm show-options -w -t e2e:0 -v @ccar_busy 2>/dev/null)" = 0 ]' 10
wait_for 'rendered | grep -q "✳ work"' 10
has "an idle tab shows the plain ✳ again"       "$(rendered)" "✳ work"

echo
echo "grok pane discovered on the same socket, glyph from the title"
# Not registered: grok_panes_on walks list-panes on the claude pane's socket.
# No client attached: title scrape is cheap enough to run anyway.
tm new-window -t e2e -n '✳ grokproj' 'grok 600'
gropane="$(tm list-panes -t e2e:1 -F '#{pane_id}' | head -1)"
tm select-pane -t "$gropane" -T '⠋ - Thinking - widget - grok'
wait_for '[ "$(tm show-options -w -t e2e:1 -v @ccar_busy 2>/dev/null)" = 1 ]' 10
eq  "a grok title spinner publishes working" "$(tm show-options -w -t e2e:1 -v @ccar_busy)" "1"
grendered() { tm display-message -p -t e2e:1 '#{T:window-status-format}'; }
eq  "a grok pane is tagged grok, not claude" "$(tm show-options -w -t e2e:1 -v @ccar_kind)" "grok"
wait_for '! grendered | grep -q ✳' 10
hasnt "a working grok tab drops Claude's idle ✳" "$(grendered)" "✳"
hasnt "and does not use Claude's star spinner"   "$(grendered)" "✻"
hasnt "nor the idle glyph while working"         "$(grendered)" "🚹"
has  "and keeps the grok window text"            "$(grendered)" "grokproj"
case "$(grendered)" in
  *[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]\ grokproj*) ok "a working grok tab uses the braille spinner" ;;
  *) bad "a working grok tab uses the braille spinner"; printf '       got: %q\n' "$(grendered)" ;;
esac
tm select-pane -t "$gropane" -T 'UV and cloud widget color theming - grok'
wait_for '[ "$(tm show-options -w -t e2e:1 -v @ccar_busy 2>/dev/null)" = 0 ]' 10
eq  "an idle grok title publishes idle" "$(tm show-options -w -t e2e:1 -v @ccar_busy)" "0"
wait_for 'grendered | grep -q "🚹 grokproj"' 10
has "an idle grok tab shows the mens-symbol emoji" "$(grendered)" "🚹 grokproj"
hasnt "idle grok is not Claude's ✳"              "$(grendered)" "✳"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
