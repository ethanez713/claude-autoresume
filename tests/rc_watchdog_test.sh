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
mkfoot() { printf '❯%s\n──────────────────\n  Opus 5 hi 💡 · Ctx 8%% · 🖿 /proj %s\n  ⏵⏵ auto mode on' "$nb" "$1"; }
connected_wide=$(mkfoot "                       /rc")           # collapsed active form
connected_full=$(mkfoot "                 /rc active")
failed=$(mkfoot "                    /rc failed")
reconnecting=$(mkfoot "              /rc reconnecting")
connecting=$(mkfoot "               /rc connecting…")
# Outbound-only / disabled / too-narrow: Claude Code mounts no badge at all.
outbound=$(mkfoot "")
typing=$'❯ how do I fix\n──────────────────\n  Opus 5 hi 💡 · Ctx 8% · 🖿 /proj\n  ⏵⏵ auto mode on'
no_box=$'✻ Proofing… (2m 13s · ↓ 6.1k tokens)\n──────────────────\n  Opus 5 hi 💡 · Ctx 8% · 🖿 /proj\n  ⏵⏵ auto mode on'
menu=$'What do you want to do?\n❯ 1. Stop and wait for limit to reset\n  2. Upgrade your plan\n  Opus 5 hi 💡 · Ctx 8% · 🖿 /proj'
# A conversation that merely MENTIONS /rc failed, with no badge on the footer.
# Reading the tail as "failed" would fire the watchdog at a live pane.
mentions=$'  it said /rc failed earlier\n\n❯'"$nb"$'\n──────────────────\n  Opus 5 hi 💡 · Ctx 8% · 🖿 /proj\n  ⏵⏵ auto mode on'

echo "state classification"
check "collapsed active form '/rc'" connected  "$(rc_state "$connected_wide")"
check "full form '/rc active'"      connected  "$(rc_state "$connected_full")"
check "'/rc failed' is the trigger" failed     "$(rc_state "$failed")"
check "'/rc reconnecting' is transient" transient "$(rc_state "$reconnecting")"
check "'/rc connecting…' is transient"  transient "$(rc_state "$connecting")"
check "no badge => none (not failed)"   none    "$(rc_state "$outbound")"
check "a /rc-failed mention above the box is ignored" none "$(rc_state "$mentions")"

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
