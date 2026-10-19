#!/usr/bin/env bash
# Deep idle: the quiet wait forks nothing, and it wakes on a hook stamp, a
# clock jump, or the hourly backstop. Run: tests/deep_idle_test.sh
set -u
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$repo/config.sh" ] && export CCAR_CONFIG="$repo/config.sh" \
                         || export CCAR_CONFIG="$repo/config.example.sh"
# shellcheck source=/dev/null
source "$repo/bin/monitor.sh"
CCAR_LOG=/dev/null

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
CCAR_BUSY_DIR="$tmp/busy"
mkdir -p "$CCAR_BUSY_DIR"
CANCEL_FILE="$tmp/cancel"
CCAR_STATS_JSONL="$tmp/stats.jsonl"
act="$CCAR_BUSY_DIR/.activity"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$3', want '$2')"; fi; }

pr=$'idle-sock\t%1'
pr2=$'idle-sock\t%2'

quiet_panes() { # one idle pane and a stamp old enough for the default 300s
  pane_busy=()
  pane_latch=()
  rc_failed_since=()
  pane_busy[$pr]=0
  : >"$act"
  touch -d '400 seconds ago' "$act"
  unset CCAR_DEEP_IDLE_AFTER_SECONDS
}

echo "deep idle predicate"
quiet_panes
deep_idle_ready && ok "idle panes and an old stamp are quiet" || bad "idle panes and an old stamp are quiet"
for s in 1 sub ask limit; do
  pane_busy[$pr]=$s
  deep_idle_ready && bad "published $s stays on the poll" || ok "published $s stays on the poll"
done
pane_busy[$pr]=0
pane_busy[$pr2]=ask
deep_idle_ready && bad "one asking pane keeps the poll" || ok "one asking pane keeps the poll"
unset 'pane_busy[$pr2]'
pane_latch[$pr]=seen
deep_idle_ready && bad "a latch stays on the poll" || ok "a latch stays on the poll"
unset 'pane_latch[$pr]'
rc_failed_since[$pr]=1
deep_idle_ready && bad "an rc failure stays on the poll" || ok "an rc failure stays on the poll"
unset 'rc_failed_since[$pr]'
: >"$act"
deep_idle_ready && bad "a fresh stamp stays on the poll" || ok "a fresh stamp stays on the poll"
rm -f "$act"
deep_idle_ready && bad "no stamp stays on the poll" || ok "no stamp stays on the poll"
quiet_panes
CCAR_DEEP_IDLE_AFTER_SECONDS=10000
deep_idle_ready && bad "a stamp younger than the knob stays on the poll" || ok "a stamp younger than the knob stays on the poll"
unset CCAR_DEEP_IDLE_AFTER_SECONDS
deep_idle_ready && ok "default quiet window accepts a 400s stamp" || bad "default quiet window accepts a 400s stamp"
pane_busy=()
deep_idle_ready && bad "no watched pane is not deep idle" || ok "no watched pane is not deep idle"

echo "deep-idle wait forks nothing and blocks"
quiet_panes
: >"$act"
CCAR_DEEP_IDLE_SCAN_SECONDS=2
CCAR_BUSY_REFRESH_MS=200
date_n=0; sleep_n=0; tmux_n=0
date() { date_n=$((date_n+1)); printf '1700000000\n'; }
sleep() { sleep_n=$((sleep_n+1)); }
tmux() { tmux_n=$((tmux_n+1)); }
idle_epoch last_scan_epoch
c0=$(cpu_ticks)
deep_idle_wait
c1=$(cpu_ticks)
idle_epoch ended
check "no date forks" "0" "$date_n"
check "no sleep forks" "0" "$sleep_n"
check "no tmux calls" "0" "$tmux_n"
if [ $((ended - last_scan_epoch)) -ge 2 ]; then ok "hourly budget of 2s elapsed"; else bad "hourly budget of 2s elapsed (advanced $((ended - last_scan_epoch))s)"; fi
if [ $((c1 - c0)) -lt 80 ]; then ok "the wait blocked (cpu ticks $((c1 - c0)))"; else bad "the wait blocked (cpu ticks $((c1 - c0)))"; fi
unset -f date sleep tmux

echo "wakes when .activity is touched"
: >"$act"
before="$(stat -c %y "$act")"
CCAR_DEEP_IDLE_SCAN_SECONDS=5
CCAR_BUSY_REFRESH_MS=100
idle_epoch last_scan_epoch
tmux_n=0
tmux() { tmux_n=$((tmux_n+1)); }
( command sleep 0.4; : >"$act" ) &
bg=$!
deep_idle_wait
wait "$bg"
idle_epoch ended
after="$(stat -c %y "$act")"
if [ "$before" != "$after" ]; then ok "activity touch woke the wait"; else bad "activity touch woke the wait"; fi
if [ $((ended - last_scan_epoch)) -le 3 ]; then ok "activity wake returned before the budget"; else bad "activity wake returned before the budget (took $((ended - last_scan_epoch))s)"; fi
check "activity wake calls no tmux" "0" "$tmux_n"
unset -f tmux

echo "wakes when the cancel file appears"
rm -f "$CANCEL_FILE"
: >"$act"
CCAR_DEEP_IDLE_SCAN_SECONDS=5
CCAR_BUSY_REFRESH_MS=100
idle_epoch last_scan_epoch
( command sleep 0.4; : >"$CANCEL_FILE" ) &
bg=$!
deep_idle_wait
wait "$bg"
idle_epoch ended
if [ -e "$CANCEL_FILE" ]; then ok "cancel file woke the wait"; else bad "cancel file woke the wait"; fi
if [ $((ended - last_scan_epoch)) -le 3 ]; then ok "cancel wake returned before the budget"; else bad "cancel wake returned before the budget (took $((ended - last_scan_epoch))s)"; fi
rm -f "$CANCEL_FILE"

echo "wakes on a clock jump and reconciles"
fake_now=6000000000
idle_epoch() { printf -v "$1" '%s' "$fake_now"; }
pauses=0
idle_pause() { pauses=$((pauses+1)); fake_now=$((fake_now + 80)); }
reconcile_n=0
reconcile_clock() { [ "${1:-}" = force ] && reconcile_n=$((reconcile_n+1)); }
last_scan_epoch=$fake_now
CCAR_DEEP_IDLE_SCAN_SECONDS=3600
CCAR_BUSY_REFRESH_MS=2000
: >"$act"
deep_idle_wait
check "clock jump pauses once" "1" "$pauses"
check "clock jump forces one reconcile" "1" "$reconcile_n"
check "clock jump does not run out the hour" "6000000080" "$fake_now"

echo "hourly backstop"
fake_now=4000000000
pauses=0
idle_pause() { pauses=$((pauses+1)); fake_now=$((fake_now + 2)); }
last_scan_epoch=$fake_now
CCAR_DEEP_IDLE_SCAN_SECONDS=10
CCAR_BUSY_REFRESH_MS=2000
deep_idle_wait
check "10s budget sleeps five 2s chunks" "5" "$pauses"
check "10s budget ends on the budget" "4000000010" "$fake_now"
unset CCAR_DEEP_IDLE_SCAN_SECONDS
fake_now=5000000000
pauses=0
last_scan_epoch=$((fake_now - 3599))
deep_idle_wait
check "default hour waits until 3600s" "1" "$pauses"
check "default hour is 3600s" "5000000002" "$fake_now"

echo "entering and leaving closes the stats window and arms rc"
fake_now=7000000000
pauses=0
idle_pause() { pauses=$((pauses+1)); fake_now=$((fake_now + 2)); }
last_scan_epoch=$fake_now
CCAR_DEEP_IDLE_SCAN_SECONDS=10
CCAR_BUSY_REFRESH_MS=2000
date() {
  case "$1" in
    +%s) printf '%s\n' "$fake_now" ;;
    *) printf '2026-01-01T00:00:00+00:00\n' ;;
  esac
}
stats_last_ts=$((fake_now - 40))
stats_last_cpu=$(cpu_ticks)
stats_polls=4
stats_frames=2
rc_last_check=999
: >"$CCAR_STATS_JSONL"
run_deep_idle
check "rc gate is bypassed after a quiet wait" "0" "$rc_last_check"
check "enter and leave each emit a row" "2" "$(grep -c . "$CCAR_STATS_JSONL")"
grep -q '"window_s":40' "$CCAR_STATS_JSONL" && ok "enter row covers the pre-quiet window" || bad "enter row covers the pre-quiet window"
grep -q '"window_s":10' "$CCAR_STATS_JSONL" && ok "leave row covers the quiet window" || bad "leave row covers the quiet window"
stats_emit
check "a short window does not emit again" "2" "$(grep -c . "$CCAR_STATS_JSONL")"
fake_now=$((fake_now + 5))
stats_emit force
check "force emits a short window" "3" "$(grep -c . "$CCAR_STATS_JSONL")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
