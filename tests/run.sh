#!/usr/bin/env bash
# Unit-style tests by default. --e2e also runs every script that starts a
# tmux server: the *_e2e.sh files, plus busy_format_test.sh and
# reconstruct_test.sh. Those two are format and liveness checks on a
# throwaway socket, gated with the end-to-end runs because CI's Ubuntu
# image has no tmux. tests/run.sh (no flag) is what CI runs.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

e2e=0
case "${1:-}" in
  "") ;;
  --e2e) e2e=1 ;;
  *) echo "usage: tests/run.sh [--e2e]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  echo "usage: tests/run.sh [--e2e]" >&2
  exit 2
fi

needs_tmux() {
  case "$1" in
    *_e2e.sh|busy_format_test.sh|reconstruct_test.sh) return 0 ;;
    *) return 1 ;;
  esac
}

fail=0
ran=0
for path in tests/*_test.sh tests/*_e2e.sh; do
  [ -f "$path" ] || continue
  base="${path#tests/}"
  if needs_tmux "$base"; then
    [ "$e2e" -eq 1 ] || continue
  fi
  ran=$((ran + 1))
  printf '\n== %s\n' "$base"
  bash "$path" || { fail=1; printf 'FAILED %s\n' "$base" >&2; }
done

if [ "$ran" -eq 0 ]; then
  echo "no tests ran" >&2
  exit 1
fi
if [ "$fail" -ne 0 ]; then
  exit 1
fi
