#!/usr/bin/env bash
# The pick-list's pure core: tui_apply_key (state transitions) and _tui_readkey
# (byte -> token). No terminal. Run: tests/tui_test.sh
set -u
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$repo/bin/ccar-lib.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
is()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want: %q\n       got:  %q\n' "$3" "$2"; }; }

echo "tui_apply_key"
is "down moves the cursor"            "$(tui_apply_key 3 0 111 down)"   "1 111 none"
is "down wraps at the end"            "$(tui_apply_key 3 2 111 down)"   "0 111 none"
is "up wraps at the top"             "$(tui_apply_key 3 0 111 up)"     "2 111 none"
is "toggle clears the item at cursor" "$(tui_apply_key 3 1 111 toggle)" "1 101 none"
is "toggle sets it back"              "$(tui_apply_key 3 1 101 toggle)" "1 111 none"
is "all selects every item"           "$(tui_apply_key 3 1 000 all)"    "1 111 none"
is "none clears every item"           "$(tui_apply_key 3 1 111 none)"   "1 000 none"
is "enter confirms"                   "$(tui_apply_key 3 0 111 confirm)" "0 111 confirm"
is "q cancels"                        "$(tui_apply_key 3 0 111 cancel)"  "0 111 cancel"

# A short interaction: drop items 2 and 3, keep 1, then confirm.
apply_seq() { # $1=n $2=cursor $3=sel, rest=keys -> final "cursor sel action"
  local n="$1" cur="$2" sel="$3" k action=none; shift 3
  for k in "$@"; do read -r cur sel action <<<"$(tui_apply_key "$n" "$cur" "$sel" "$k")"; done
  printf '%s %s %s' "$cur" "$sel" "$action"
}
is "navigate + deselect two, confirm" \
   "$(apply_seq 3 0 111 down toggle down toggle confirm)" "2 100 confirm"

echo
echo "_tui_readkey"
key() { local out; exec 3< <(printf '%b' "$1"); out="$(_tui_readkey)"; exec 3<&-; printf '%s' "$out"; }
is "space is toggle"        "$(key ' ')"        "toggle"
is "j is down"              "$(key 'j')"        "down"
is "k is up"               "$(key 'k')"        "up"
is "a is all"              "$(key 'a')"        "all"
is "arrow-up is up"        "$(key '\x1b[A')"   "up"
is "arrow-down is down"    "$(key '\x1b[B')"   "down"
is "lone ESC cancels"      "$(key '\x1b')"     "cancel"
is "CR (raw-mode Enter) confirms" "$(key '\r')" "confirm"
is "q cancels"             "$(key 'q')"        "cancel"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
