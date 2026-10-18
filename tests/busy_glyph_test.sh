#!/usr/bin/env bash
# Unit tests for the working-vs-idle detector behind the @ccar_busy glyph,
# and for the idle poll_sleep (tmux and sleep stubbed). Run: tests/busy_glyph_test.sh
set -u
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$repo/config.sh" ] && export CCAR_CONFIG="$repo/config.sh" \
                         || export CCAR_CONFIG="$repo/config.example.sh"
# shellcheck source=/dev/null
source "$repo/bin/monitor.sh"
CCAR_LOG=/dev/null   # config.sh sets it at source time; re-point after sourcing

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
busy()  { screen_shows_working "$2" && ok "$1" || bad "$1"; }
idle()  { screen_shows_working "$2" && bad "$1" || ok "$1"; }

nb=$'\xc2\xa0'
e=$'\033'
active="$e[38;5;174m"   # the spinner glyph while a turn runs
verb="$e[38;5;216m"     # verb shade; pulses 174/180/216, which is why we match the GLYPH
grey="$e[38;5;246m"     # what BOTH the glyph and the text fade to once the turn ends
off="$e[39m"

chrome=$'\n──────────────────\n  Opus 5 hi 💡 · Ctx 8% · 🖿 /proj                              /rc\n  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents'
prompt=$'❯'"$nb$chrome"

# Captured from real panes with `capture-pane -pe`. The glyph, the verb and the
# elapsed time all vary per turn; the glyph's COLOUR is the only stable signal.
spin_timer="$active✻$off ${verb}Processing…$active $grey(43s · ↓$off ${grey}2.2k tokens)$off$prompt"
spin_alt="$active✽$off ${verb}Beboppin'…$active $grey(11m 58s · ↓$off ${grey}35.8k tokens)$off$prompt"
spin_ascii="$active*$off ${verb}Doodling…$active $grey(6m 29s · ↓$off ${grey}24.5k tokens)$off$prompt"
spin_untimed="$active✻$off ${active}Waiting for 1 background agent to finish$off$prompt"
spin_interrupt="$active✳$off ${verb}Thinking… (12s · ↑ 1.2k tokens · esc to interrupt)$off$prompt"

# THE regression: a finished turn leaves a spinner-SHAPED line on screen. Only
# its colour says the session is parked, so anything matching on glyph or wording
# reads every idle session as working.
done_cooked="$grey✻$off ${grey}Cooked for 24m 49s$off$prompt"
done_churned="$grey✻$off ${grey}Churned for 11m 26s$off$prompt"
parked="$grey●$off ${grey}Done — 25 passed, 0 failed$off$prompt"
typed=$'❯ yes, add the CLAUDE.md section'"$chrome"
# Transcript body is indented, so an active-coloured spinner QUOTED in output
# cannot reach column 1 and trip the anchor.
quoted="  ⎿  $active✻$off ${verb}Processing…$off$prompt"
paused=$'  You\'ve hit your session limit · resets 4am (America/New_York)'"$prompt"

echo "running turns"
busy "timer spinner (✻)"                 "$spin_timer"
busy "alternate spinner glyph (✽)"       "$spin_alt"
busy "ascii spinner frame (*)"           "$spin_ascii"
busy "active line with no timer or parens" "$spin_untimed"
busy "'esc to interrupt' hint"           "$spin_interrupt"

echo "parked sessions"
idle "grey completion line 'Cooked for 24m 49s'"   "$done_cooked"
idle "grey completion line 'Churned for 11m 26s'"  "$done_churned"
idle "empty prompt after a finished turn"          "$parked"
idle "half-typed prompt, nothing sent"             "$typed"
idle "paused at the rate limit"                    "$paused"
idle "active spinner quoted in transcript output"  "$quoted"

echo "grok titles (live captures: working panes prefix a braille spinner, idle do not)"
gbusy()  { title_shows_working "$2" && ok "$1" || bad "$1"; }
gidle()  { title_shows_working "$2" && bad "$1" || ok "$1"; }
gbusy "thinking"  "⠋ - Thinking - Widget UV yellow cloud-white detail styl… - grok"
gbusy "tool call" "⠦ - Running: Read \`/home/ezhou/claude-autor… - Grok status indicators for autoresume mo… - grok"
gbusy "activity line with no Running:/Thinking" "⠧ - Capture idle vs working Grok pane screen… - Grok status indicators for autoresume mo… - grok"
gbusy "every braille frame" "⠏ - Thinking - x - grok"
gidle "idle session summary" "Delete unused screens and outdated spec … - grok"
gidle "another idle summary" "UV and cloud widget color theming - grok"
gidle "the word Thinking in an idle summary is not a spinner" "Thinking about widgets - grok"
gidle "a spinner quoted mid-title is not working" "notes on ⠋ - Thinking - grok"
gidle "Claude's title glyph is not grok's spinner" "✳ Claude.md default model removal and self-improve summary"
gidle "empty title" ""
CCAR_GROK_BUSY_TITLE_REGEX='' title_shows_working "⠋ - Thinking - x - grok" && bad "empty grok regex matches nothing" || ok "empty grok regex matches nothing"

echo "disabled"
CCAR_BUSY_REGEX='' screen_shows_working "$spin_timer" && bad "matched with an empty regex" || ok "empty regex matches nothing"

echo "spinner frames"
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$3', want '$2')"; fi; }
CCAR_BUSY_GLYPHS='✻ ✽ ✢ * ·'
check "frame 0"                 '✻' "$(busy_glyph 0)"
check "frame 3 is a bare * , not a glob of the cwd" '*' "$(busy_glyph 3)"
check "frame 4"                 '·' "$(busy_glyph 4)"
check "wraps past the last frame" '✻' "$(busy_glyph 5)"
check "wraps repeatedly"        '✢' "$(busy_glyph 22)"
check "a single glyph is a static indicator" '●' "$(CCAR_BUSY_GLYPHS='●' busy_glyph 7)"
check "no glyphs configured => nothing to paint" '' "$(CCAR_BUSY_GLYPHS='' busy_glyph 0)"
CCAR_GROK_BUSY_GLYPHS='⠹ ⠼ ⠧ ⠏'
check "grok frame 0 is the first 4-pip glyph" '⠹' "$(busy_glyph 0 "$CCAR_GROK_BUSY_GLYPHS")"
check "grok frame 3 is the last 4-pip glyph"  '⠏' "$(busy_glyph 3 "$CCAR_GROK_BUSY_GLYPHS")"
check "grok frame 4 wraps to the start"       '⠹' "$(busy_glyph 4 "$CCAR_GROK_BUSY_GLYPHS")"

echo "idle poll_sleep touches tmux only when a hook file moves"
# Stub tmux and sleep the way publish_busy's tests stub txp: the functions
# under test call them as commands, so a shell function replaces the binary
# for the rest of this file. sleep records the argument and returns, so a
# poll finishes without waiting out CCAR_POLL_SECONDS.
idle_dir="$(mktemp -d)"
trap 'rm -rf "$idle_dir"' EXIT
CCAR_BUSY_DIR="$idle_dir"
CCAR_BUSY_REGEX='x'
CCAR_BUSY_GLYPHS='✻ *'
CCAR_BUSY_ANIM_MS=400
CCAR_BUSY_REFRESH_MS=2000
CCAR_POLL_SECONDS=5
tmux_n=0
tmux_log=""
sleep_args=""
tmux() { tmux_n=$((tmux_n + 1)); tmux_log+="$*"$'\n'; }
sleep() { sleep_args+="$1"$'\n'; }

sock="/tmp/tmux-test/idle"
prA="$sock"$'\t'"%11"
prB="$sock"$'\t'"%22"
prC="$sock"$'\t'"%33"
keyA="$(pane_key "$prA")"
keyB="$(pane_key "$prB")"
keyC="$(pane_key "$prC")"
printf '0\t1700000000\n' >"$idle_dir/$keyA"
printf '1\t1700000000\n' >"$idle_dir/$keyB"   # parked panes keep the hourglass
printf '1\t1700000000\n' >"$idle_dir/$keyC"   # stranded flag, already cleared
pane_busy=()
pane_parked=()
pane_kind=()
pane_hook_seen=()
pane_sub_seen=()
socket_any_busy=()
attached=()
pane_busy[$prA]=0
pane_busy[$prB]=limit
pane_parked[$prB]=1
pane_busy[$prC]=0
pane_hook_seen[$prC]=1          # last publish folded this file in and went idle
pane_sub_seen[$prC]=0

poll_sleep
check "unchanged hook files make zero tmux calls" "0" "$tmux_n"
check "idle poll sleeps in refresh chunks, totalling the poll" $'2.000\n2.000\n1.000\n' "$sleep_args"
check "parked pane stays on the hourglass" "limit" "${pane_busy[$prB]}"
check "a stranded hook already cleared stays idle" "0" "${pane_busy[$prC]}"

tmux_n=0
tmux_log=""
sleep_args=""
printf '1\t1700000000\n' >"$idle_dir/$keyA"
poll_sleep
check "hook flipping to 1 publishes that pane" "1" "${pane_busy[$prA]}"
case "$tmux_log" in
  *"-t %11"*) ok "hook flip calls tmux for that pane" ;;
  *) bad "hook flip calls tmux for that pane" ;;
esac
case "$tmux_log" in
  *"-t %22"*) bad "parked pane is not republished when another hook flips" ;;
  *) ok "parked pane is not republished when another hook flips" ;;
esac
case "$tmux_log" in
  *"-t %33"*) bad "stranded hook is not republished when another hook flips" ;;
  *) ok "stranded hook is not republished when another hook flips" ;;
esac
case "$sleep_args" in
  *"0.400"*) bad "a detached hook flip does not start the frame loop" ;;
  *) ok "a detached hook flip does not start the frame loop" ;;
esac

# Seen was recorded by the publish above. A second poll with the file still at
# 1 must not capture again.
tmux_n=0
tmux_log=""
poll_sleep
check "hook that stays 1 does not publish again" "0" "$tmux_n"

pane_busy[$prA]=0
unset 'pane_hook_seen[$prA]' 'pane_sub_seen[$prA]'
printf 'ask\t1700000000\n' >"$idle_dir/$keyA"
tmux_n=0
poll_sleep
check "hook ask publishes ask" "ask" "${pane_busy[$prA]}"

pane_busy[$prA]=0
unset 'pane_hook_seen[$prA]' 'pane_sub_seen[$prA]'
printf '0\t1700000000\n' >"$idle_dir/$keyA"
printf '2\t1700000000\n' >"$idle_dir/$keyA.sub"
tmux_n=0
poll_sleep
check "subagent count publishes sub" "sub" "${pane_busy[$prA]}"
rm -f "$idle_dir/$keyA.sub"

echo "animated poll_sleep still frames"
pane_busy=()
pane_parked=()
socket_any_busy=()
attached=()
pane_busy[$prA]=1
pane_hook_seen[$prA]=1
pane_sub_seen[$prA]=0
printf '1\t1700000000\n' >"$idle_dir/$keyA"
socket_attached() { return 0; }   # this server has a client, so the spinner runs
CCAR_POLL_SECONDS=1
tmux_n=0
tmux_log=""
sleep_args=""
poll_sleep
case "$tmux_log" in
  *"@ccar_spin"*) ok "a working attached pane advances the spinner" ;;
  *) bad "a working attached pane advances the spinner" ;;
esac
check "animated poll sleeps in frames, not refresh chunks" $'0.400\n0.400\n' "$sleep_args"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
