#!/usr/bin/env bash
# cc-attach's control flow when the fallback server is gone: the preview it
# shows, and main()'s guards. The candidate list and pick-list are covered by
# reconstruct_test.sh and tui_test.sh. Run: tests/attach_plan_test.sh
set -u
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$repo/config.sh" ] && export CCAR_CONFIG="$repo/config.sh" \
                         || export CCAR_CONFIG="$repo/config.example.sh"
# shellcheck source=/dev/null
source "$repo/bin/cc-attach"
set +e   # cc-attach sets errexit for itself; the cases below assert on exit codes

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want: %q\n       got:  %q\n' "$3" "$2"; }; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1"; printf '       %q does not contain %q\n' "$2" "$3" ;; esac; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export CCAR_PANES_DIR="$tmp/panes"; mkdir -p "$CCAR_PANES_DIR"
# A socket name no server can be listening on, so main() never attaches to a real
# session and always falls through to the reopen path.
CCAR_TMUX_SOCKET="ccar-plan-test-$$"
CCAR_TMUX_SESSION=cc
HOME="$tmp/home"
DEAD="/tmp/tmux-1000/ccar-plan-test-dead-$$"   # a socket path with no server behind it

row() { printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" >"$CCAR_PANES_DIR/$1"; }
clear_rows() { rm -f "$CCAR_PANES_DIR"/*; }
mkproj() { mkdir -p "$tmp/$1"; printf '%s' "$tmp/$1"; }

a="$(mkproj alpha)"; b="$(mkproj beta)"

echo "preview_list"
mkdir -p "$HOME/.claude/projects/$(printf '%s' "$a" | tr -c 'A-Za-z0-9-' '-')"
touch "$HOME/.claude/projects/$(printf '%s' "$a" | tr -c 'A-Za-z0-9-' '-')/x.jsonl"
plan="$(preview_list "$a" "$b")"
has "shows a dir that will continue"       "$plan" "continues the last of 1"
has "shows a dir that will start fresh"     "$plan" "starts fresh"

echo
echo "forget_dead_panes"
clear_rows
row ours    "/tmp/tmux-1000/$CCAR_TMUX_SOCKET" cc %0 "$a"
row ours2   "/tmp/tmux-1000/$CCAR_TMUX_SOCKET" cc %1 "$b"
row foreign /tmp/tmux-1000/default            main %0 "$a"
forget_dead_panes
eq "clears only the rows whose pane ids a ccar rebuild reuses" \
   "$(ls "$CCAR_PANES_DIR" | tr '\n' ' ')" "foreign "

echo
echo "main"
TMUX="/tmp/tmux-1000/default,1,0"
out="$(main </dev/null 2>&1)"; rc=$?
eq "refuses to attach from inside tmux" "$rc" "1"
has "and says how to get out first" "$out" "Detach first"
unset TMUX

clear_rows
out="$(main </dev/null 2>&1)"; rc=$?
eq "an empty registry is an error, not an empty rebuild" "$rc" "1"
has "and says where it looked" "$out" "$CCAR_PANES_DIR"

clear_rows
row r0 "$DEAD" cc %0 "$a"
out="$(main </dev/null 2>&1)"; rc=$?
eq "no terminal to pick on, without -y, refuses" "$rc" "1"
has "and points at the flag that skips picking" "$out" "-y"
has "after showing what it would reopen"        "$out" "$a"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
