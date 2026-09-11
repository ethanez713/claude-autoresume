#!/usr/bin/env bash
# reconstruct_candidates(): which directories a lost server's tabs are rebuilt
# from. Drives a real tmux server (throwaway socket) only to prove the liveness
# filter — a row whose pane is still open is NOT reopened. Run: tests/reconstruct_test.sh
set -u
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
is()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want: %q\n       got:  %q\n' "$3" "$2"; }; }

tmp="$(mktemp -d)"
sock="recon-$$"
export TMUX_TMPDIR="$tmp"
trap 'tmux -L "$sock" kill-server 2>/dev/null; rm -rf "$tmp"' EXIT

export CCAR_PANES_DIR="$tmp/panes"; mkdir -p "$CCAR_PANES_DIR"
# shellcheck source=/dev/null
source "$repo/bin/ccar-lib.sh"

# Real live pane, in a directory we must NOT reopen (it is still open).
live="$tmp/live"; mkdir -p "$live"
tmux -L "$sock" new-session -d -s t -c "$live" 'sleep 300'
live_sp="$(tmux -L "$sock" display-message -p '#{socket_path}')"
live_pane="$(tmux -L "$sock" list-panes -t t -F '#{pane_id}' | head -1)"

d1="$tmp/one"; d2="$tmp/two"; mkdir -p "$d1" "$d2"
dead="$tmp/tmux-1000/gone"   # a socket path with no server behind it
row() { printf '%s\t%s\t%s\t%s\n' "$1" cc "$2" "$3" > "$CCAR_PANES_DIR/$4"; }

# Pane numbers are the open order; the result follows them, deduped to one window
# per dir at the dir's earliest pane. A live pane and a gone directory are dropped.
row "$dead"    %0 "$d1"          r1
row "$dead"    %1 "$d2"          r2
row "$dead"    %2 "$d1"          r3  # same dir again, later pane
row "$dead"    %3 "$tmp/removed" r4  # dir gone
row "$live_sp" "$live_pane" "$live" r5  # still open on a live server

got="$(reconstruct_candidates | tr '\n' ',')"
is "dead rows with existing dirs, deduped, in pane order; live + gone-dir dropped" \
   "$got" "$d1,$d2,"

echo
echo "empty registry"
rm -f "$CCAR_PANES_DIR"/*
is "no rows -> nothing to reopen" "$(reconstruct_candidates)" ""

echo
echo "transcript_count"
slug="$(printf '%s' "$d1" | tr -c 'A-Za-z0-9-' '-')"
mkdir -p "$tmp/home/.claude/projects/$slug"; HOME="$tmp/home"
is "no transcript -> 0" "$(transcript_count "$d1")" "0"
touch "$tmp/home/.claude/projects/$slug/a.jsonl" "$tmp/home/.claude/projects/$slug/b.jsonl"
is "two transcripts -> 2" "$(transcript_count "$d1")" "2"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
