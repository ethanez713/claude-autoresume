#!/usr/bin/env bash
# Unit tests for the hook-driven @ccar_busy detector: read_hook_busy(),
# read_hook_sub(), decide_busy(), and bin/cc-busy-hook itself. No tmux, no real
# claude — the hook is invoked with a fake $TMUX/$TMUX_PANE and the readers and
# decide_busy run directly against CCAR_BUSY_DIR. Run: tests/busy_hook_test.sh
set -u
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$repo/config.sh" ] && export CCAR_CONFIG="$repo/config.sh" \
                         || export CCAR_CONFIG="$repo/config.example.sh"
# shellcheck source=/dev/null
source "$repo/bin/monitor.sh"
CCAR_LOG=/dev/null   # config.sh sets it at source time; re-point after sourcing

busy_dir="$(mktemp -d)"
CCAR_BUSY_DIR="$busy_dir"
cleanup() { rm -rf "$busy_dir"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq() { # $1=label $2=want $3=got
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$3', want '$2')"; fi
}

socket="/tmp/tmux-1000/sock"   # matches the $TMUX socket component run_hook exports below
pane="%7"
pr="$socket"$'\t'"$pane"       # a fake paneref; nothing here actually touches tmux
key="$(printf '%s:%s' "$socket" "$pane" | tr -c 'A-Za-z0-9._-' '_')"

echo "read_hook_busy"
eq "no file -> empty"        "" "$(read_hook_busy "$pr")"
printf '0\t1700000000\n' >"$busy_dir/$key"
eq "file says 0"             "0" "$(read_hook_busy "$pr")"
printf '1\t1700000000\n' >"$busy_dir/$key"
eq "file says 1"             "1" "$(read_hook_busy "$pr")"
printf 'garbage\n' >"$busy_dir/$key"
eq "garbage contents -> empty" "" "$(read_hook_busy "$pr")"
rm -f "$busy_dir/$key"

echo "read_hook_sub"
eq "no file -> no subagents"   "0" "$(read_hook_sub "$pr")"
printf '0\t1700000000\n' >"$busy_dir/$key.sub"
eq "count 0 -> no subagents"   "0" "$(read_hook_sub "$pr")"
printf '2\t1700000000\n' >"$busy_dir/$key.sub"
eq "count 2 -> subagents"      "1" "$(read_hook_sub "$pr")"
printf 'garbage\n' >"$busy_dir/$key.sub"
eq "garbage contents -> no subagents" "0" "$(read_hook_sub "$pr")"
rm -f "$busy_dir/$key.sub"

echo "bin/cc-busy-hook"
# The hook sources config.sh fresh in its own subprocess, and config.sh assigns
# CCAR_BUSY_DIR unconditionally — so pointing it at our mktemp dir needs a config
# override file, not just an env var, the same way any other CCAR_CONFIG override
# would work for a real deployment.
hook_config="$busy_dir/hook_config.sh"
{ cat "$CCAR_CONFIG"; printf 'CCAR_BUSY_DIR=%q\n' "$busy_dir"; } >"$hook_config"
run_hook() { # $1 = event
  TMUX="$socket,999,0" TMUX_PANE="$pane" CCAR_CONFIG="$hook_config" \
    "$repo/bin/cc-busy-hook" "$1"
}
hook_state() { [ -f "$busy_dir/$key" ] && cut -f1 "$busy_dir/$key" || printf '(none)'; }
sub_state()  { [ -f "$busy_dir/$key.sub" ] && cut -f1 "$busy_dir/$key.sub" || printf '(none)'; }

rm -f "$busy_dir/$key"
out="$(run_hook UserPromptSubmit 2>&1)"; rc=$?
eq "UserPromptSubmit: silent"   "" "$out"
eq "UserPromptSubmit: exit 0"   "0" "$rc"
eq "UserPromptSubmit: writes 1" "1" "$(hook_state)"

out="$(run_hook Stop 2>&1)"; rc=$?
eq "Stop: silent"   "" "$out"
eq "Stop: exit 0"   "0" "$rc"
eq "Stop: writes 0" "0" "$(hook_state)"

out="$(run_hook SubagentStart 2>&1)"; rc=$?
eq "SubagentStart: silent"       "" "$out"
eq "SubagentStart: exit 0"       "0" "$rc"
eq "SubagentStart: counts one"   "1" "$(sub_state)"
run_hook SubagentStart
eq "a second subagent is counted, not overwritten" "2" "$(sub_state)"

out="$(run_hook SubagentStop 2>&1)"; rc=$?
eq "SubagentStop: silent"        "" "$out"
eq "SubagentStop: exit 0"        "0" "$rc"
eq "SubagentStop: one still running" "1" "$(sub_state)"
run_hook SubagentStop
eq "the last one finishing clears the count" "0" "$(sub_state)"
run_hook SubagentStop
eq "a stop with nothing running cannot go negative" "0" "$(sub_state)"

printf '1\t1700000000\n' >"$busy_dir/$key"
printf '3\t1700000000\n' >"$busy_dir/$key.sub"
out="$(run_hook SessionStart 2>&1)"; rc=$?
eq "SessionStart: drops subagents stranded by the previous session" "(none)" "$(sub_state)"
eq "SessionStart: silent"                    "" "$out"
eq "SessionStart: exit 0"                    "0" "$rc"
eq "SessionStart: clears a stranded 1 to 0"  "0" "$(hook_state)"

printf '2\t1700000000\n' >"$busy_dir/$key.sub"
out="$(run_hook SessionEnd 2>&1)"; rc=$?
eq "SessionEnd: silent"          "" "$out"
eq "SessionEnd: exit 0"          "0" "$rc"
eq "SessionEnd: removes the file" "(none)" "$(hook_state)"
eq "SessionEnd: removes the subagent count too" "(none)" "$(sub_state)"

printf '1\t1700000000\n' >"$busy_dir/$key"
out="$(run_hook SomeOtherEvent 2>&1)"; rc=$?
eq "unknown event: silent"         "" "$out"
eq "unknown event: exit 0"         "0" "$rc"
eq "unknown event: no-op"          "1" "$(hook_state)"
rm -f "$busy_dir/$key"

out="$(TMUX="$socket,999,0" TMUX_PANE="" CCAR_CONFIG="$hook_config" \
       "$repo/bin/cc-busy-hook" UserPromptSubmit 2>&1)"; rc=$?
eq "empty TMUX_PANE: silent"        "" "$out"
eq "empty TMUX_PANE: exit 0"        "0" "$rc"
eq "empty TMUX_PANE: no-op"         "(none)" "$(hook_state)"

echo "decide_busy (frozen-pane stale-clear rule as a pure function)"
CCAR_BUSY_STALE_SECONDS=20
# Args: hook scrape frozen veto_age
eq "scrape working beats hook=0 (a background wake fires no UserPromptSubmit)" \
   "1" "$(decide_busy 0 1 0 '')"
eq "hook=0, scrape idle -> busy 0"                "0" "$(decide_busy 0 0 1 '')"
eq "hook=1, not attached (scrape empty) -> busy 1" "1" "$(decide_busy 1 '' '' '')"
eq "hook=1, scrape agrees -> busy 1"               "1" "$(decide_busy 1 1 0 '')"
eq "hook='', attached, scrape working -> busy 1"   "1" "$(decide_busy '' 1 0 '')"
eq "hook='', attached, scrape idle -> busy 0"      "0" "$(decide_busy '' 0 1 '')"
eq "hook='', not attached -> busy 0"               "0" "$(decide_busy '' '' '' '')"

# THE regression this rule exists for: while a tool call runs, the pane paints
# the tool's output where the spinner line would be, so the scrape reads idle on
# a turn that is very much alive. The screen still repaints, and that is what
# keeps the flag up — no veto_age, however large, may override it.
eq "hook=1, no spinner but REPAINTING -> busy 1 (long tool call)" \
   "1" "$(decide_busy 1 0 0 '')"
eq "hook=1, no spinner, repainting, huge veto_age -> still busy 1" \
   "1" "$(decide_busy 1 0 0 9999)"

eq "hook=1, frozen and spinnerless, under threshold -> stays busy 1" \
   "1" "$(decide_busy 1 0 1 19)"
eq "hook=1, frozen and spinnerless, at threshold -> busy 0" \
   "0" "$(decide_busy 1 0 1 20)"
eq "hook=1, frozen and spinnerless, past threshold -> busy 0" \
   "0" "$(decide_busy 1 0 1 45)"
# Either disproof resets the clock, which publish_busy models by clearing
# pane_hook_veto so the next poll passes veto_age "".
eq "a repaint resets the clock -> busy 1" "1" "$(decide_busy 1 0 0 '')"
eq "a spinner resets the clock -> busy 1" "1" "$(decide_busy 1 1 1 '')"

echo "decide_busy (subagents and the rate limit)"
# Args: hook scrape frozen veto_age sub limited
eq "main agent idle, subagents running -> sub" \
   "sub" "$(decide_busy 0 0 0 '' 1 0)"
eq "the subagent panel's own spinner is not a turn of the main agent's" \
   "sub" "$(decide_busy 0 1 0 '' 1 0)"
eq "a turn of its own takes the window back from its subagents" \
   "1" "$(decide_busy 1 1 0 '' 1 0)"
eq "frozen and spinnerless past the threshold strands a subagent flag too" \
   "0" "$(decide_busy 0 0 1 45 1 0)"
eq "under the threshold the subagent flag stands" \
   "sub" "$(decide_busy 0 0 1 19 1 0)"
eq "a rate-limit latch outranks a turn the interrupted hook never ended" \
   "limit" "$(decide_busy 1 0 1 '' 0 1)"
eq "a rate-limit latch outranks running subagents" \
   "limit" "$(decide_busy 0 0 1 '' 1 1)"


echo "read_hook_busy: falls back to \$CCAR_STATE_DIR/busy when CCAR_BUSY_DIR is unset"
default_state_dir="$(mktemp -d)"
mkdir -p "$default_state_dir/busy"
printf '1\t1700000000\n' >"$default_state_dir/busy/$key"
out="$(
  unset CCAR_BUSY_DIR
  CCAR_STATE_DIR="$default_state_dir"
  read_hook_busy "$pr"
)"
eq "read_hook_busy resolves \$CCAR_STATE_DIR/busy with no CCAR_BUSY_DIR set" "1" "$out"
rm -rf "$default_state_dir"

echo "publish_busy: stale-veto timer must not survive hook leaving 1 (regression)"
# Stub the tmux-touching internals so publish_busy runs with no real tmux
# server: socket_attached/capture_ansi/screen_shows_working/txp are ordinary
# functions, redefinable after sourcing monitor.sh for the rest of this file.
test_scrape_working=0   # 0 = scrape disagrees ("not working"), 1 = agrees
test_screen="frame-a"   # what the pane is "showing"; change it to simulate a repaint
socket_attached() { return 0; }   # every pane looks attached to this test
capture_ansi() { printf '%s' "$test_screen"; }
screen_shows_working() { [ "$test_scrape_working" = 1 ]; }
txp() { return 0; }               # no real tmux server to talk to

pr2="veto-sock"$'\t'"%9"
key2="$(pane_key "$pr2")"
veto_state() { [ -n "${pane_hook_veto[$1]:-}" ] && echo armed || echo clear; }

printf '1\t%s\n' "$(date +%s)" >"$busy_dir/$key2"   # UserPromptSubmit fired
test_scrape_working=0                                  # spinner not visible yet
publish_busy "$pr2"                                    # first poll only snapshots the screen
eq "first poll cannot arm the veto — nothing to compare against yet" \
   "clear" "$(veto_state "$pr2")"
publish_busy "$pr2"                                    # screen unchanged => frozen
eq "veto armed once the pane is frozen AND spinnerless under hook=1" \
   "armed" "$(veto_state "$pr2")"

test_screen="frame-b"                                  # the turn repaints
publish_busy "$pr2"
eq "a repaint disproves the veto and resets the clock" "clear" "$(veto_state "$pr2")"
eq "still busy through the repaint" "1" "${pane_busy[$pr2]:-}"

publish_busy "$pr2"; eq "re-armed after freezing again" "armed" "$(veto_state "$pr2")"

printf '0\t%s\n' "$(date +%s)" >"$busy_dir/$key2"   # Stop fired
publish_busy "$pr2"
eq "veto cleared once hook drops to 0 (the defect 3 fix)" "clear" "$(veto_state "$pr2")"
eq "veto_logged cleared too" "" "${pane_hook_veto_logged[$pr2]:-}"

printf '1\t%s\n' "$(date +%s)" >"$busy_dir/$key2"   # a NEW turn starts
test_scrape_working=0                                  # spinner still catching up
publish_busy "$pr2"
eq "new turn's first disagreeing poll is not immediately stale" "1" "${pane_busy[$pr2]:-}"
eq "veto re-armed fresh for the new turn, not left dangling" "armed" "$(veto_state "$pr2")"
rm -f "$busy_dir/$key2"

echo "publish_busy: the state it publishes for each signal"
pr3="state-sock"$'\t'"%3"; key3="$(pane_key "$pr3")"
test_scrape_working=0; test_screen="frame-a"
printf '0\t%s\n' "$(date +%s)" >"$busy_dir/$key3"        # main agent parked
printf '2\t%s\n' "$(date +%s)" >"$busy_dir/$key3.sub"    # two subagents out
publish_busy "$pr3"
eq "idle main agent with subagents out -> sub" "sub" "${pane_busy[$pr3]:-}"
printf '1\t%s\n' "$(date +%s)" >"$busy_dir/$key3"        # it starts a turn itself
publish_busy "$pr3"
eq "its own turn outranks its subagents"       "1"   "${pane_busy[$pr3]:-}"
pane_latch[$pr3]=seen
publish_busy "$pr3"
eq "a rate-limit latch outranks both"          "limit" "${pane_busy[$pr3]:-}"
unset 'pane_latch[$pr3]'
rm -f "$busy_dir/$key3" "$busy_dir/$key3.sub"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
