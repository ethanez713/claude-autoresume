#!/usr/bin/env bash
# Unit tests for the working-vs-idle detector behind the @ccar_busy glyph.
# Pure function only — no tmux. Run: tests/busy_glyph_test.sh
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
