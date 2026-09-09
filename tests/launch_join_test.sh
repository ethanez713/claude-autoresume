#!/usr/bin/env bash
# Unit tests for the two decisions behind the launcher's join prompt: which
# invocations a window that is already open can satisfy, and how a pane's
# published state reads. Run: tests/launch_join_test.sh
set -u
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$repo/bin/ccar-lib.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want: %q\n       got:  %q\n' "$3" "$2"; }; }
yes() { wants_rejoin "${@:2}" && ok "$1" || bad "$1"; }
no()  { wants_rejoin "${@:2}" && bad "$1" || ok "$1"; }

echo "wants_rejoin"
yes "a bare launch takes you back to the window"
yes "so does --continue"           --continue
yes "and its short form"           -c
no  "a prompt has to go somewhere new"        "fix the bug"
no  "--resume wants the session picker"       --resume
no  "and its short form"                      -r
no  "any other option is a new session"       --model opus
no  "a prompt alongside --continue"           -c "fix the bug"

echo
echo "busy_label"
eq "a running turn"        "$(busy_label 1)"     "working"
eq "delegated work"        "$(busy_label sub)"   "idle, subagents still working"
eq "parked at the limit"   "$(busy_label limit)" "parked at the rate limit"
eq "nothing happening"     "$(busy_label 0)"     "idle"
eq "a window the monitor has never published for" "$(busy_label '')" "idle"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
