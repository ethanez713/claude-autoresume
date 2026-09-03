#!/usr/bin/env bash
# Drives install_busy_format and the working-glyph formats against a real tmux
# server on a throwaway socket — your own sessions are never touched. Covers what
# the pure-function tests can't: that the formats splice into whatever the option
# already said, and that they render the spinner exactly when a session works.
# Run: tests/busy_format_test.sh
set -u
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
sock="$tmp/fmt.sock"
trap 'tmux -S "$sock" kill-server 2>/dev/null; rm -rf "$tmp"' EXIT

[ -f "$repo/config.sh" ] && export CCAR_CONFIG="$repo/config.sh" \
                         || export CCAR_CONFIG="$repo/config.example.sh"
# shellcheck source=/dev/null
source "$repo/bin/monitor.sh"

CCAR_LOG="$tmp/monitor.log"
CCAR_PANES_DIR="$tmp/panes"; mkdir -p "$CCAR_PANES_DIR"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$3', want '$2')"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (no '$2' in '$3')" ;; esac; }

tm()   { tmux -S "$sock" "$@"; }
opt()  { tm show-options -gv "$1"; }
render() { tm display-message -p -t "$2" "$1"; }   # $1 = format, $2 = pane

tm -f /dev/null new-session -d -s t -n '✳ adbconnect' -x 80 -y 24 'sleep 300'
pane="$(tm list-panes -t t -F '#{pane_id}' | head -1)"
printf '%s\t%s\t%s\t%s\n' "$sock" t "$pane" "$tmp" >"$CCAR_PANES_DIR/p1"
tm select-pane -t "$pane" -T '✳ adbconnect'
tm set-option -g window-status-format '#I:#W#F'
tm set-option -g set-titles-string '#T'
tm set-option -g set-titles off

echo "install"
install_busy_format
has "window-status-format keeps the text around #W" '#I:' "$(opt window-status-format)"
has "window-status-format reads the per-window flag" '@ccar_busy' "$(opt window-status-format)"
has "set-titles-string reads the per-SERVER flag"    '@ccar_any_busy' "$(opt set-titles-string)"
is  "the pre-patch title format is stashed" '#T' "$(opt @ccar_orig_set-titles-string)"
is  "set-titles is turned on so the title reaches the terminal" 'on' "$(opt set-titles)"
is  "a busy window has a glyph before the first frame tick" "$(busy_glyph 0)" "$(opt @ccar_spin)"
is  "so does one whose subagents are working" \
    "$(busy_glyph 0 "$CCAR_SUBAGENT_GLYPHS")" "$(opt @ccar_sub_spin)"
is  "the limit glyph is static, so it is published once" "$CCAR_LIMIT_GLYPH" "$(opt @ccar_wait)"

# A second install (monitor restarted after a config change) must re-derive from
# the stash, not patch its own output into a nested format.
busy_format_done=(); CCAR_BUSY_NAME_FORMAT='<#{@ccar_busy}#{window_name}>'
install_busy_format
is "re-install re-derives from the stashed original" '#I:<#{@ccar_busy}#{window_name}>#F' "$(opt window-status-format)"
CCAR_BUSY_NAME_FORMAT="$(grep -o "^CCAR_BUSY_NAME_FORMAT=.*" "$CCAR_CONFIG" | cut -d"'" -f2)"

echo "window name"
tm set-option -g @ccar_spin '✽'
tm set-option -g @ccar_sub_spin '🌒'
tm set-option -g @ccar_wait '⏳'
tm set-option -w -t "$pane" @ccar_busy 1
is "working: the leading ✳ becomes the current frame" '✽ adbconnect' "$(render "$CCAR_BUSY_NAME_FORMAT" "$pane")"
tm set-option -w -t "$pane" @ccar_busy sub
is "subagents out: it becomes the subagent frame"     '🌒 adbconnect' "$(render "$CCAR_BUSY_NAME_FORMAT" "$pane")"
tm set-option -w -t "$pane" @ccar_busy limit
is "parked at the limit: it becomes the hourglass"    '⏳ adbconnect' "$(render "$CCAR_BUSY_NAME_FORMAT" "$pane")"
tm set-option -w -t "$pane" @ccar_busy 0
is "parked: the name is untouched"                    '✳ adbconnect' "$(render "$CCAR_BUSY_NAME_FORMAT" "$pane")"
tm set-option -w -t "$pane" @ccar_busy 1
tm rename-window -t "$pane" '🌒 adbconnect'
is "another glyph (subagent moon) is left alone"      '🌒 adbconnect' "$(render "$CCAR_BUSY_NAME_FORMAT" "$pane")"
tm rename-window -t "$pane" '✳ adbconnect'

echo "terminal title"
tm set-option -w -t "$pane" @ccar_busy 0    # the title must ignore the per-window flag
tm set-option -g @ccar_any_busy 1
is "any session working: the title sparkles"     '✽ adbconnect' "$(render "$CCAR_BUSY_TITLE_FORMAT" "$pane")"
tm set-option -g @ccar_any_busy sub
is "only subagents left working: the title moons" '🌒 adbconnect' "$(render "$CCAR_BUSY_TITLE_FORMAT" "$pane")"
tm set-option -g @ccar_any_busy limit
is "everything parked at the limit: the taskbar waits" '⏳ adbconnect' "$(render "$CCAR_BUSY_TITLE_FORMAT" "$pane")"
tm set-option -g @ccar_any_busy 0
is "nothing working: the title keeps its ✳"      '✳ adbconnect' "$(render "$CCAR_BUSY_TITLE_FORMAT" "$pane")"
tm set-option -g @ccar_any_busy 1
tm select-pane -t "$pane" -T 'user@box: ~'
is "a title with no ✳ is left alone"             'user@box: ~' "$(render "$CCAR_BUSY_TITLE_FORMAT" "$pane")"

echo "server-wide flag"
tm set-option -g @ccar_any_busy 0; socket_any_busy=()
pane_busy=(["$sock"$'\t'"$pane"]=0 ["$sock"$'\t'%99]=1)
publish_any_busy
is "one working pane lights the whole server" '1' "$(opt @ccar_any_busy)"
pane_busy["$sock"$'\t'%99]=0
publish_any_busy
is "the last pane going idle clears it"       '0' "$(opt @ccar_any_busy)"

# Precedence, which is NOT the per-window one: the taskbar answers "is anything
# still moving", so a pane that is parked can never speak over one that isn't.
socket_any_busy=()
pane_busy=(["$sock"$'\t'"$pane"]=limit ["$sock"$'\t'%99]=sub)
publish_any_busy
is "working subagents outrank a parked pane"  'sub'   "$(opt @ccar_any_busy)"
socket_any_busy=()
pane_busy=(["$sock"$'\t'"$pane"]=limit ["$sock"$'\t'%99]=1)
publish_any_busy
is "a running turn outranks both"             '1'     "$(opt @ccar_any_busy)"
socket_any_busy=()
pane_busy=(["$sock"$'\t'"$pane"]=limit ["$sock"$'\t'%99]=0)
publish_any_busy
is "nothing moving: the wait reaches the taskbar" 'limit' "$(opt @ccar_any_busy)"
socket_any_busy=()
pane_busy=()
tm set-option -g @ccar_any_busy 0
CCAR_BUSY_TITLE_FORMAT='' publish_any_busy
is "no title format configured => the server flag is left alone" '0' "$(opt @ccar_any_busy)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
