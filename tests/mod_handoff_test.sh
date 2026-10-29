#!/usr/bin/env bash
# Mod handoff: a fresh <pane>.mod claim suppresses the latch and the resume.
# The hourglass still follows a parked claim. No tmux.
# Run: tests/mod_handoff_test.sh
set -u
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$repo/config.sh" ] && export CCAR_CONFIG="$repo/config.sh" \
                         || export CCAR_CONFIG="$repo/config.example.sh"
# shellcheck source=/dev/null
source "$repo/bin/monitor.sh"
# shellcheck source=/dev/null
source "$repo/bin/ccar-lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
CCAR_BUSY_DIR="$tmp/busy"
mkdir -p "$CCAR_BUSY_DIR"
CCAR_LOG="$tmp/monitor.log"
CCAR_STATE_JSON="$tmp/state.json"
: >"$CCAR_LOG"
# A user config.sh can set this to anything. The stale case is 10 minutes.
CCAR_MOD_FRESH_SECONDS=180
CCAR_DETECT_REGEX="(hit your (session|usage) limit|usage limit reached|session limit.*reset)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$3', want '$2')"; fi; }

pr=$'mod-sock\t%9'
key="$(pane_key "$pr")"
poll_panes="$pr"
poll_busy="$pr"
fake_usage=limited
fake_screen="You've hit your session limit · resets 4am"
pause_screen="$fake_screen"
idle_screen="idle prompt"
dismiss_n=0
tmux_n=0
saw_parked=""
: >"$tmp/caps"

usage_state() { printf '%s\n' "$fake_usage"; }
# capture runs inside $(...), so a counter variable would not survive. A file does.
capture() { printf 'x\n' >>"$tmp/caps"; printf '%s' "$fake_screen"; }
cap_n() { grep -c . "$tmp/caps" || true; }
publish_busy() {
  if [ -n "${pane_parked[$1]:-}" ]; then saw_parked=1; else saw_parked=0; fi
}
dismiss_limit_prompt() { dismiss_n=$((dismiss_n + 1)); return 1; }
sleep() { :; }
tmux() { tmux_n=$((tmux_n + 1)); }

latch_of() {
  if [ -n "${pane_latch[$pr]+x}" ]; then printf '%s' "${pane_latch[$pr]}"; else printf 'none'; fi
}
parked_of() {
  if [ -n "${pane_parked[$pr]+x}" ]; then printf '1'; else printf '0'; fi
}
owns_n() { grep -c 'Mod owns this pane' "$CCAR_LOG" || true; }
drop_n() { grep -c 'Mod claim expired' "$CCAR_LOG" || true; }
write_claim() { printf '%s\t1700000000\n' "$1" >"$CCAR_BUSY_DIR/$key.mod"; }

echo "no claim latches on the pause text"
dismiss_n=0
scan_panes
check "pause text latches seen" "seen" "$(latch_of)"
check "pause text parks" "1" "$(parked_of)"
check "no claim does not log ownership" "0" "$(owns_n)"
check "usage not clear still dismisses" "1" "$dismiss_n"

echo "fresh watch claim"
write_claim watch
dismiss_n=0
fake_screen="$pause_screen"
fake_usage=limited
scan_panes
check "watch claim does not latch" "none" "$(latch_of)"
check "watch claim does not park" "0" "$(parked_of)"
check "watch claim still dismisses the choice prompt" "1" "$dismiss_n"
check "publish saw the pane unparked" "0" "$saw_parked"
check "ownership is logged once" "1" "$(owns_n)"
[ -f "$CCAR_BUSY_DIR/$key.mod" ] && ok "a live pane keeps its .mod" || bad "a live pane keeps its .mod"
scan_panes
check "a second scan does not log ownership again" "1" "$(owns_n)"

echo "parked claim"
write_claim parked
fake_screen="$idle_screen"
fake_usage=limited
dismiss_n=0
scan_panes
check "parked claim does not latch" "none" "$(latch_of)"
check "parked claim sets pane_parked" "1" "$(parked_of)"
check "publish saw the pane parked" "1" "$saw_parked"
check "parked does not log ownership again" "1" "$(owns_n)"
check "parked claim still dismisses when usage is limited" "1" "$dismiss_n"
fake_usage=clear
dismiss_n=0
scan_panes
check "clear usage does not dismiss" "0" "$dismiss_n"
check "clear usage still follows the parked claim" "1" "$(parked_of)"
check "clear usage does not latch" "none" "$(latch_of)"

echo "a fresh watch claim clears a latch taken earlier"
fake_usage=limited
fake_screen="$pause_screen"
pane_latch[$pr]=seen
pane_parked[$pr]=1
pane_snap[$pr]=abc
pane_snap_ok[$pr]=1
write_claim watch
scan_panes
check "pre-claim latch is cleared" "none" "$(latch_of)"
check "watch claim leaves the pane unparked" "0" "$(parked_of)"
[ -z "${pane_snap[$pr]:-}" ] && ok "pre-claim snapshot is cleared" || bad "pre-claim snapshot is cleared"

echo "stale claim latches as before"
write_claim watch
touch -d '10 minutes ago' "$CCAR_BUSY_DIR/$key.mod"
fake_usage=limited
fake_screen="$pause_screen"
scan_panes
check "stale claim latches seen" "seen" "$(latch_of)"
check "stale claim parks from the pause text" "1" "$(parked_of)"
check "expiry is logged once" "1" "$(drop_n)"
scan_panes
check "a second stale scan does not log expiry again" "1" "$(drop_n)"
check "the pane stays latched" "seen" "$(latch_of)"

echo "should_resume"
write_claim watch
pane_latch[$pr]=seen
pane_snap_ok[$pr]=1
pane_snap[$pr]="$(hash_of "$pause_screen")"
fake_screen="$pause_screen"
: >"$tmp/caps"
should_resume "$pr"
rc=$?
check "an owned pane is not resumed" "1" "$rc"
check "an owned pane is not captured" "0" "$(cap_n)"
rm -f "$CCAR_BUSY_DIR/$key.mod"
: >"$tmp/caps"
should_resume "$pr"
rc=$?
check "a static pause screen with no claim is resumed" "0" "$rc"
check "that resume captured twice" "2" "$(cap_n)"

echo "dead-pane prune removes .mod"
dead=$'dead-sock\t%2'
dkey="$(pane_key "$dead")"
printf '0\t1\n' >"$CCAR_BUSY_DIR/$dkey"
printf '1\t1\n' >"$CCAR_BUSY_DIR/$dkey.sub"
printf 'watch\t1\n' >"$CCAR_BUSY_DIR/$dkey.mod"
: >"$CCAR_BUSY_DIR/.$dkey.sublock"
pane_busy[$dead]=0
pane_mod[$dead]=1
poll_panes=""
poll_busy=""
scan_panes
[ ! -e "$CCAR_BUSY_DIR/$dkey" ] && ok "prune removes the busy file" || bad "prune removes the busy file"
[ ! -e "$CCAR_BUSY_DIR/$dkey.sub" ] && ok "prune removes .sub" || bad "prune removes .sub"
[ ! -e "$CCAR_BUSY_DIR/$dkey.mod" ] && ok "prune removes .mod" || bad "prune removes .mod"
[ ! -e "$CCAR_BUSY_DIR/.$dkey.sublock" ] && ok "prune removes the sub lock" || bad "prune removes the sub lock"
[ -z "${pane_mod[$dead]:-}" ] && ok "prune forgets Mod ownership" || bad "prune forgets Mod ownership"
[ -z "${pane_busy[$dead]:-}" ] && ok "prune forgets the busy glyph" || bad "prune forgets the busy glyph"

echo "plugin dir on the typed claude command"
saved_here="$here"
here="$tmp/no-mod"
check "absent plugin quotes nothing" "" "$(mod_plugin_quoted)"
mod_plugin_dir >/dev/null && bad "absent plugin has no directory" || ok "absent plugin has no directory"
mod_q="$(mod_plugin_quoted)"
check "continue command is unchanged" "exec claude -c" "exec claude${mod_q:+ $mod_q} -c"
check "fresh command is unchanged" "exec claude --session-id abc" "exec claude${mod_q:+ $mod_q} --session-id abc"
check "plain command is unchanged" "exec claude" "exec claude${mod_q:+ $mod_q}"

here="$tmp/tree with space"
mkdir -p "$here/mod/.claude-plugin"
printf '{}\n' >"$here/mod/.claude-plugin/plugin.json"
mod_q="$(mod_plugin_quoted)"
check "present plugin is a quoted --plugin-dir" "--plugin-dir $(printf '%q' "$here/mod")" "$mod_q"
parse_cmd() { bash -c 'eval "set -- $1"; printf "%s\n" "$@"' bash "$1"; }
got="$(parse_cmd "exec claude${mod_q:+ $mod_q} -c" | tr '\n' ' ')"
check "a path with a space survives the pane shell" "exec claude --plugin-dir $here/mod -c " "$got"
got="$(parse_cmd "exec claude${mod_q:+ $mod_q} --session-id abc" | tr '\n' ' ')"
check "session-id stays after the plugin dir" "exec claude --plugin-dir $here/mod --session-id abc " "$got"
here="$saved_here"

check "no tmux" "0" "$tmux_n"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
