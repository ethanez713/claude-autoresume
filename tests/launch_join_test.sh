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

echo
echo "monitor_alive"
# A live process whose argv names monitor.sh is the monitor; one that does not,
# even when alive, is a recycled pid the pidfile must not be trusted for. exec -a
# forges each argv[0] without needing a real monitor.sh on disk.
bash -c 'exec -a /x/monitor.sh sleep 60' & mine=$!
bash -c 'exec -a /x/sleeper   sleep 60' & other=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -n "$(tr '\0' ' ' </proc/$mine/cmdline 2>/dev/null)" ] &&
  [ -n "$(tr '\0' ' ' </proc/$other/cmdline 2>/dev/null)" ] && break
done
monitor_alive "$mine"  && ok "a live monitor.sh process is the monitor" || bad "a live monitor.sh process is the monitor"
monitor_alive "$other" && bad "a foreign live pid is not the monitor (pid recycling)" || ok "a foreign live pid is not the monitor (pid recycling)"
kill "$mine" "$other" 2>/dev/null; wait "$mine" "$other" 2>/dev/null
monitor_alive "$mine" && bad "a dead pid is not the monitor" || ok "a dead pid is not the monitor"
monitor_alive ""      && bad "an empty pidfile is not the monitor" || ok "an empty pidfile is not the monitor"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
