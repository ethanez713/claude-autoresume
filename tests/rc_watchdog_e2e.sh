#!/usr/bin/env bash
# End-to-end: drive rc_check against real tmux panes painted with fake Claude
# footers, on a throwaway socket and registry. Your real sessions are never
# touched — the panes run `cat`, so anything typed into them is just echoed.
# Run: tests/rc_watchdog_e2e.sh
set -u
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
sock="$tmp/rc.sock"
trap 'tmux -S "$sock" kill-server 2>/dev/null; rm -rf "$tmp"' EXIT

[ -f "$repo/config.sh" ] && export CCAR_CONFIG="$repo/config.sh" \
                         || export CCAR_CONFIG="$repo/config.example.sh"
# shellcheck source=/dev/null
source "$repo/bin/monitor.sh"

# Test-only overrides, applied AFTER sourcing so they win over the config file.
CCAR_LOG="$tmp/monitor.log"
CCAR_PANES_DIR="$tmp/panes"; mkdir -p "$CCAR_PANES_DIR"
CCAR_FOREGROUND_CMDS="cat"        # the scratch panes run `cat`, not claude
CCAR_RC_ENABLE=1
CCAR_RC_COMMAND="/remote-control"
CCAR_RC_CHECK_SECONDS=0
CCAR_RC_GRACE_SECONDS=1
CCAR_RC_BUSY_RETRY_SECONDS=60
CCAR_SETTLE_SECONDS=1
CCAR_RC_BACKOFF_MINUTES="1 2 4"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

nb=$'\xc2\xa0'   # Claude Code pads an empty input line with U+00A0, not a space
footer_connected="  Opus 5 hi 💡 · Ctx 8% · ⧗ 99% 03:10 · 🖿 /proj                            /rc"
footer_gone="  Opus 5 hi 💡 · Ctx 8% · ⧗ 99% 03:10 · 🖿 /proj"

make_pane() { # $1 = window name, $2 = footer line, $3 = optional body command
  local name="$1" footer="$2" body="${3:-}" id
  tmux -S "$sock" new-window -t rc -n "$name" \
    "clear; printf '  a previous answer\n\n'; ${body}${body:+;} printf '❯${nb}\n──────────────────────\n%s\n  ⏵⏵ auto mode on (shift+tab to cycle)\n' '$footer'; cat"
  sleep 0.6
  id="$(tmux -S "$sock" display-message -p -t "$name" '#{pane_id}')"
  [ -n "$id" ] || { echo "make_pane $name failed to start" >&2; exit 1; }
  printf '%s' "$id"
}

tmux -S "$sock" -f /dev/null new-session -d -s rc -x 130 -y 20 'sleep 300'
sleep 0.4

idle_gone="$(make_pane gone "$footer_gone")"
idle_conn="$(make_pane conn "$footer_connected")"
# A pane that repaints every second, exactly like a session mid-turn.
busy="$(make_pane busy "$footer_gone" "(while :; do tput cup 1 0; printf '✻ Working… (%ss)' \$SECONDS; sleep 1; done &)")"

for p in "$idle_gone" "$idle_conn" "$busy"; do
  printf '%s\t%s\t%s\t%s\n' "$sock" rc "$p" "$tmp" \
    > "$CCAR_PANES_DIR/$(printf '%s' "$p" | tr -c 'a-zA-Z0-9' _)"
done
# rc_check reads the registry walk the main loop shares with every consumer
# (poll_panes), so a bare call would scan nothing at all.
poll() { refresh_poll_panes; rc_check; }

pr_gone="$sock"$'\t'"$idle_gone"
pr_conn="$sock"$'\t'"$idle_conn"
pr_busy="$sock"$'\t'"$busy"

echo "first sighting only arms the grace window"
poll
[ -n "${rc_missing_since[$pr_gone]:-}" ] && ok "disconnected pane armed"     || bad "disconnected pane armed"
[ -z "${rc_missing_since[$pr_conn]:-}" ] && ok "connected pane left alone"   || bad "connected pane left alone"
[ -n "${rc_missing_since[$pr_busy]:-}" ] && ok "busy disconnected pane armed" || bad "busy disconnected pane armed"
capture "$pr_gone" | grep -q -- '/remote-control' && bad "typed during the grace window" || ok "nothing typed during the grace window"

echo "after the grace window"
sleep 2
rc_last_check=0
poll
sleep 0.5
capture "$pr_gone" | grep -q -- '/remote-control' && ok "idle pane received the reconnect command" || bad "idle pane received the reconnect command"
[ "${rc_attempts[$pr_gone]:-0}" = 1 ] && ok "attempt counter advanced to 1" || bad "attempt counter advanced to 1 (got ${rc_attempts[$pr_gone]:-unset})"
gap=$(( ${rc_next_attempt[$pr_gone]:-0} - $(now_epoch) ))
[ "$gap" -ge 50 ] && [ "$gap" -le 61 ] && ok "backed off ~1 min (${gap}s)" || bad "backed off ~1 min (got ${gap}s)"
capture "$pr_conn" | grep -q -- '/remote-control' && bad "typed into a CONNECTED pane" || ok "connected pane never typed into"
capture "$pr_busy" | grep -q -- '/remote-control' && bad "typed into a REPAINTING pane" || ok "repainting pane never typed into"
[ "${rc_attempts[$pr_busy]:-0}" = 0 ] && ok "a busy pane doesn't consume a backoff step" || bad "a busy pane doesn't consume a backoff step"

echo "backoff holds the pane off until it expires"
rc_last_check=0
before="$(capture "$pr_gone" | grep -c -- '/remote-control')"
poll
[ "$before" = "$(capture "$pr_gone" | grep -c -- '/remote-control')" ] \
  && ok "no second send inside the backoff window" || bad "no second send inside the backoff window"

echo "the indicator returning resets the episode"
rc_next_attempt[$pr_gone]=0
tmux -S "$sock" respawn-pane -k -t "$idle_gone" \
  "clear; printf '❯${nb}\n──────────────────────\n%s\n' '$footer_connected'; cat"
sleep 0.8
rc_last_check=0
poll
[ -z "${rc_missing_since[$pr_gone]:-}" ] && ok "per-pane state cleared" || bad "per-pane state cleared"

echo "a pane that disappears is forgotten"
tmux -S "$sock" kill-window -t busy 2>/dev/null
rm -f "$CCAR_PANES_DIR"/*"$(printf '%s' "$busy" | tr -c 'a-zA-Z0-9' _)"
sleep 0.4
rc_last_check=0
poll
[ -z "${rc_missing_since[$pr_busy]:-}" ] && ok "dead pane's state dropped" || bad "dead pane's state dropped"

printf '\n--- monitor.log ---\n'; cat "$CCAR_LOG"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
