#!/usr/bin/env bash
# Unit tests for the restore plan cc-attach shows before it rebuilds a dead
# fallback session. No tmux, no claude. Run: tests/attach_plan_test.sh
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
# A socket name no server can be listening on: the `main` cases below must fall
# through to the restore plan, never attach to the operator's live session.
CCAR_TMUX_SOCKET="ccar-plan-test-$$"
CCAR_TMUX_SESSION=cc
HOME="$tmp/home"
S="/tmp/tmux-1000/$CCAR_TMUX_SOCKET"

row() { # $1=file $2=socket $3=session $4=pane $5=dir
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" >"$CCAR_PANES_DIR/$1"
}
clear_rows() { rm -f "$CCAR_PANES_DIR"/*; }
mkproj() { mkdir -p "$tmp/$1"; printf '%s' "$tmp/$1"; }

echo "restore_dirs"

a="$(mkproj alpha)"; b="$(mkproj beta)"; c="$(mkproj gamma)"

clear_rows
row r0 "$S" cc %0 "$a"
row r1 "$S" cc %1 "$b"
eq "keeps the fallback session's directories" "$(restore_dirs | tr '\n' ' ')" "$a $b "

# Pane ids are handed out in sequence, so they ARE the window order — but only
# read as numbers: a lexical sort puts %10 between %1 and %2.
clear_rows
row r10 "$S" cc %10 "$c"
row r2  "$S" cc %2  "$b"
row r1  "$S" cc %1  "$a"
eq "orders by pane number, not lexically" "$(restore_dirs | tr '\n' ' ')" "$a $b $c "

# The registry also holds panes launched inside the operator's own tmux, which
# this command does not own and must not reopen.
clear_rows
row own /tmp/tmux-1000/default main %0 "$a"
row fb  "$S"    cc   %1 "$b"
eq "ignores panes on another server" "$(restore_dirs | tr '\n' ' ')" "$b "

clear_rows
row other "$S" scratch %0 "$a"
row ours  "$S" cc      %1 "$b"
eq "ignores another session on the same socket" "$(restore_dirs | tr '\n' ' ')" "$b "

# $TMUX_TMPDIR can move between boots, so the row's socket PATH may not match
# even when it names the same socket.
clear_rows
row moved "/run/user/1000/tmux-1000/$CCAR_TMUX_SOCKET" cc %0 "$a"
eq "matches the socket by name, not by path" "$(restore_dirs | tr '\n' ' ')" "$a "

clear_rows
row r0 "$S" cc %0 "$a"
row r1 "$S" cc %1 "$tmp/deleted-since"
eq "skips a directory that no longer exists" "$(restore_dirs | tr '\n' ' ')" "$a "

# A dir can hold several panes over a session's life (a window closed and
# reopened); it still gets one window back, at its earliest position.
clear_rows
row r0 "$S" cc %0 "$a"
row r1 "$S" cc %1 "$b"
row r2 "$S" cc %2 "$a"
eq "one window per directory" "$(restore_dirs | tr '\n' ' ')" "$a $b "

clear_rows
eq "an empty registry plans nothing" "$(restore_dirs)" ""

echo
echo "transcript_count"

mkdir -p "$HOME/.claude/projects"
eq "no project dir => nothing to continue" "$(transcript_count /home/x/proj)" "0"

mkdir -p "$HOME/.claude/projects/-home-x-proj"
eq "an empty project dir => nothing to continue" "$(transcript_count /home/x/proj)" "0"

touch "$HOME/.claude/projects/-home-x-proj/one.jsonl" \
      "$HOME/.claude/projects/-home-x-proj/two.jsonl"
eq "counts the transcripts" "$(transcript_count /home/x/proj)" "2"

# Claude Code folds every character outside [A-Za-z0-9-] to a dash, so an
# underscore in a directory name is a dash in the slug.
mkdir -p "$HOME/.claude/projects/-home-x-windows-or-ac"
touch "$HOME/.claude/projects/-home-x-windows-or-ac/one.jsonl"
eq "folds an underscore into the slug" "$(transcript_count /home/x/windows_or_ac)" "1"

mkdir -p "$HOME/.claude/projects/-home-x-claude-autoresume"
touch "$HOME/.claude/projects/-home-x-claude-autoresume/one.jsonl"
eq "keeps a hyphen in the slug" "$(transcript_count /home/x/claude-autoresume)" "1"

echo
echo "print_plan"

plan="$(print_plan /home/x/proj /home/x/fresh)"
has "says it will continue, and how many are there" "$plan" "continues the last of 2 conversation(s)"
has "says when there is nothing to continue"        "$plan" "no saved conversation here, starts fresh"
has "warns that scrollback is gone"                 "$plan" "not recoverable"
has "counts the windows"                            "$plan" "Reopen 2 window(s)"

echo
echo "forget_dead_panes"

clear_rows
row ours    "$S" cc %0 "$a"
row ours2   "$S" cc %1 "$b"
row foreign /tmp/tmux-1000/default main %0 "$a"
forget_dead_panes
eq "clears the rows whose pane ids the rebuild reuses" \
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
row r0 "$S" cc %0 "$a"
out="$(main </dev/null 2>&1)"; rc=$?
eq "a plan with no terminal to confirm on refuses" "$rc" "1"
has "and points at the flag that skips the prompt" "$out" "-y"
has "after showing the plan"                       "$out" "$a"

echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
