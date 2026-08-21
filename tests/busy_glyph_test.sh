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
chrome=$'──────────────────\n  Opus 5 hi 💡 · Ctx 8% · 🖿 /proj                              /rc\n  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents'
prompt=$'❯'"$nb"$'\n'"$chrome"

# Captured from four real panes. The spinner GLYPH cycles and the wording is
# randomised per turn, so the detector keys on the column-1 glyph, not the text.
spin_timer=$'● Verifying tmux glyphs\n  ⎿  $ tmux list-windows\n✻ Processing… (4m 27s · ↓ 16.3k tokens)\n'"$prompt"
spin_alt=$'✽ Beboppin\'… (11m 58s · ↓ 35.8k tokens · thinking)\n'"$prompt"
spin_ascii=$'* Processing… (43s · ↓ 2.2k tokens)\n'"$prompt"
spin_untimed=$'✻ Waiting for 1 background agent to finish\n'"$prompt"   # no timer, no parens
spin_interrupt=$'✳ Thinking… (12s · ↑ 1.2k tokens · esc to interrupt)\n'"$prompt"

parked=$'● Done — 25 passed, 0 failed\n'"$prompt"
typed=$'❯ yes, add the CLAUDE.md section\n'"$chrome"
# Transcript body is indented two spaces, so content that merely LOOKS like a
# spinner line can't reach column 1 — this is what makes the anchor safe.
quoted=$'● Here is the line it prints:\n  ⎿  ✻ Processing… (43s · ↓ 2.2k tokens)\n     * a markdown bullet\n'"$prompt"
paused=$'  You\'ve hit your session limit · resets 4am (America/New_York)\n'"$prompt"

echo "running turns"
busy "timer spinner (✻)"                 "$spin_timer"
busy "alternate spinner glyph (✽)"       "$spin_alt"
busy "ascii spinner frame (*)"           "$spin_ascii"
busy "spinner with no timer or parens"   "$spin_untimed"
busy "'esc to interrupt' hint"           "$spin_interrupt"

echo "parked sessions"
idle "empty prompt after a finished turn" "$parked"
idle "half-typed prompt, nothing sent"    "$typed"
idle "paused at the rate limit"           "$paused"
idle "spinner text quoted in transcript"  "$quoted"

echo "disabled"
CCAR_BUSY_REGEX='' screen_shows_working "$spin_timer" && bad "matched with an empty regex" || ok "empty regex matches nothing"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
