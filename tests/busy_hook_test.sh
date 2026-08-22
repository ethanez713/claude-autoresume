#!/usr/bin/env bash
# Unit tests for the hook-driven @ccar_busy detector: read_hook_busy(),
# decide_busy(), and bin/cc-busy-hook itself. No tmux, no real claude — the hook
# is invoked with a fake $TMUX/$TMUX_PANE and read_hook_busy/decide_busy are
# exercised directly against CCAR_BUSY_DIR. Run: tests/busy_hook_test.sh
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

rm -f "$busy_dir/$key"
out="$(run_hook UserPromptSubmit 2>&1)"; rc=$?
eq "UserPromptSubmit: silent"   "" "$out"
eq "UserPromptSubmit: exit 0"   "0" "$rc"
eq "UserPromptSubmit: writes 1" "1" "$(hook_state)"

out="$(run_hook Stop 2>&1)"; rc=$?
eq "Stop: silent"   "" "$out"
eq "Stop: exit 0"   "0" "$rc"
eq "Stop: writes 0" "0" "$(hook_state)"

printf '1\t1700000000\n' >"$busy_dir/$key"
out="$(run_hook SessionStart 2>&1)"; rc=$?
eq "SessionStart: silent"                    "" "$out"
eq "SessionStart: exit 0"                    "0" "$rc"
eq "SessionStart: clears a stranded 1 to 0"  "0" "$(hook_state)"

out="$(run_hook SessionEnd 2>&1)"; rc=$?
eq "SessionEnd: silent"          "" "$out"
eq "SessionEnd: exit 0"          "0" "$rc"
eq "SessionEnd: removes the file" "(none)" "$(hook_state)"

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

echo "decide_busy (stale-clear rule as a pure function)"
CCAR_BUSY_STALE_SECONDS=20
eq "hook=0 -> busy 0, regardless of scrape" "0" "$(decide_busy 0 1 '')"
eq "hook=1, not attached (scrape empty) -> busy 1" "1" "$(decide_busy 1 '' '')"
eq "hook=1, scrape agrees -> busy 1"        "1" "$(decide_busy 1 1 '')"
eq "hook='', attached, scrape working -> busy 1"  "1" "$(decide_busy '' 1 '')"
eq "hook='', attached, scrape idle -> busy 0"     "0" "$(decide_busy '' 0 '')"
eq "hook='', not attached -> busy 0"              "0" "$(decide_busy '' '' '')"
eq "hook=1, scrape disagrees, held under stale threshold -> stays busy 1" \
   "1" "$(decide_busy 1 0 19)"
eq "hook=1, scrape disagrees, at stale threshold -> busy 0" \
   "0" "$(decide_busy 1 0 20)"
eq "hook=1, scrape disagrees, past stale threshold -> busy 0" \
   "0" "$(decide_busy 1 0 45)"
# A scrape agreeing in between resets the clock: publish_busy models this by
# clearing pane_hook_veto (veto_age reset to ""), which is what the caller would
# pass on the next poll after a scrape says "working".
eq "scrape agreeing resets: veto_age '' after a working scrape -> busy 1" \
   "1" "$(decide_busy 1 1 '')"


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
socket_attached() { return 0; }   # every pane looks attached to this test
capture_ansi() { :; }             # content is irrelevant; screen_shows_working is stubbed below
screen_shows_working() { [ "$test_scrape_working" = 1 ]; }
txp() { return 0; }               # no real tmux server to talk to

pr2="veto-sock"$'\t'"%9"
key2="$(pane_key "$pr2")"
veto_state() { [ -n "${pane_hook_veto[$1]:-}" ] && echo armed || echo clear; }

printf '1\t%s\n' "$(date +%s)" >"$busy_dir/$key2"   # UserPromptSubmit fired
test_scrape_working=0                                  # spinner not visible yet
publish_busy "$pr2"
eq "veto armed once hook=1 disagrees with the scrape" "armed" "$(veto_state "$pr2")"

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
