#!/usr/bin/env bash
# Unit tests for the remote-control watchdog's screen-reading helpers.
# Pure functions only — no tmux, no key injection. Run: tests/rc_watchdog_test.sh
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
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$3', want '$2')"; fi; }

# Fixtures below reproduce real captured screens, including the U+00A0 that
# Claude Code uses to pad an EMPTY input line (an ASCII space would hide the
# bug that normalisation exists to fix).
nb=$'\xc2\xa0'
connected_wide=$'  Some conversation text here\n\n❯'"$nb"$'\n──────────────────\n  Opus 5 hi 💡 · Ctx 8% · ⧗ 99% 03:10 · 🖿 /proj                        /rc\n  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents'
connected_full=$'❯'"$nb"$'\n──────────────────\n  Opus 5 hi 💡 · Ctx 8% · 🖿 /proj                              /rc active\n  ⏵⏵ auto mode on (shift+tab to cycle)'
disconnected=$'  Some conversation text here\n\n❯'"$nb"$'\n──────────────────\n  Opus 5 hi 💡 · Ctx 8% · ⧗ 99% 03:10 · 🖿 /proj\n  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents'
typing=$'❯ how do I fix\n──────────────────\n  Opus 5 hi 💡 · Ctx 8% · 🖿 /proj\n  ⏵⏵ auto mode on'
no_box=$'✻ Proofing… (2m 13s · ↓ 6.1k tokens)\n──────────────────\n  Opus 5 hi 💡 · Ctx 8% · 🖿 /proj\n  ⏵⏵ auto mode on'
menu=$'What do you want to do?\n❯ 1. Stop and wait for limit to reset\n  2. Upgrade your plan\n  Opus 5 hi 💡 · Ctx 8% · 🖿 /proj'
# A conversation that merely MENTIONS /rc, with the indicator genuinely gone.
# Reading it as "connected" would silently disable the watchdog for that pane.
mentions=$'  I told you to run /rc in the pane\n\n❯'"$nb"$'\n──────────────────\n  Opus 5 hi 💡 · Ctx 8% · 🖿 /proj\n  ⏵⏵ auto mode on'

echo "indicator detection"
rc_indicator_present "$connected_wide" && ok "narrow-pane form '/rc'"        || bad "narrow-pane form '/rc'"
rc_indicator_present "$connected_full" && ok "full form '/rc active'"        || bad "full form '/rc active'"
rc_indicator_present "$disconnected"   && bad "absent indicator read as present" || ok "absent indicator => disconnected"
rc_indicator_present "$mentions"       && bad "conversation mention read as indicator" || ok "conversation mention above the box ignored"

echo "input-box readiness"
rc_input_ready "$connected_wide" && ok "empty box (U+00A0 padded) is ready" || bad "empty box (U+00A0 padded) is ready"
rc_input_ready "$typing"         && bad "half-typed box accepted"          || ok "half-typed box refused"
rc_input_ready "$no_box"         && bad "missing box accepted"             || ok "missing box refused"
rc_input_ready "$menu"           && bad "menu marker read as an input box" || ok "menu (marker carries text) refused"

echo "input-box readback"
check "empty box reads empty" ""             "$(rc_input_text "$connected_wide")"
check "typed text read back"  "how do I fix" "$(rc_input_text "$typing")"
check "no box reads empty"    ""             "$(rc_input_text "$no_box")"

echo "completion-popup residue"
cmd="/remote-control"
rc_residue_is_ours "/remote-control" "$cmd"       && ok "exact command => submit it"       || bad "exact command => submit it"
rc_residue_is_ours "/remote-cont" "$cmd"          && ok "partial completion => submit it"  || bad "partial completion => submit it"
rc_residue_is_ours "/recap" "$cmd"                && bad "a DIFFERENT command was submitted" || ok "different command refused"
rc_residue_is_ours "/remote-control extra" "$cmd" && bad "command plus junk was submitted"   || ok "command plus junk refused"
rc_residue_is_ours "" "$cmd"                      && bad "empty box treated as residue"      || ok "empty box is not residue"

echo "backoff schedule"
CCAR_RC_BACKOFF_MINUTES="1 2 4 8 16 30 60"
check "attempt 1" 1  "$(rc_backoff_minutes 1)"
check "attempt 2" 2  "$(rc_backoff_minutes 2)"
check "attempt 3" 4  "$(rc_backoff_minutes 3)"
check "attempt 4" 8  "$(rc_backoff_minutes 4)"
check "attempt 7" 60 "$(rc_backoff_minutes 7)"
check "attempt 99 holds at the longest interval, never gives up" 60 "$(rc_backoff_minutes 99)"

echo "gating"
CCAR_RC_ENABLE=1 CCAR_RC_COMMAND="/remote-control" rc_enabled && ok "armed when enabled" || bad "armed when enabled"
CCAR_RC_ENABLE=0 rc_enabled                         && bad "ran while disabled"          || ok "inert when disabled"
CCAR_RC_ENABLE=1 CCAR_RC_COMMAND="" rc_enabled      && bad "ran with no command"         || ok "inert with no command"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
