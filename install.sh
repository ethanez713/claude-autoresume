#!/usr/bin/env bash
# claude-autoresume installer — one command to set up the launcher, the monitor's
# state dir, the config, the status-line signal patch, and the `claude` alias.
# Idempotent and safe to re-run. 100% local: it installs nothing from the network
# and never auto-installs system packages (it only checks + reports tmux/python3).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
STATE_DIR="$CLAUDE_DIR/autoresume"
STATUSLINE="$CLAUDE_DIR/statusline.py"
BASHRC="${BASHRC:-$HOME/.bashrc}"
ALIAS_LINE="alias claude=\"$here/bin/cc-run\""

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_off=$'\033[0m'
ok()   { printf '%s✓%s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s!%s %s\n' "$c_warn" "$c_off" "$*" >&2; }
info() { printf '  %s\n' "$*"; }

echo "claude-autoresume installer"
echo

# 1. Preflight — report, never auto-install (PLAN §7: no silent installs).
if command -v tmux >/dev/null 2>&1; then ok "tmux present ($(tmux -V))"
else warn "tmux NOT found — install it yourself (e.g. sudo apt install tmux) before running claude."; fi
if command -v python3 >/dev/null 2>&1; then ok "python3 present ($(python3 -V 2>&1))"
else warn "python3 NOT found — the monitor and the status-line signal need it."; fi

# 2. Make the launcher/monitor/cancel scripts executable.
chmod +x "$here"/bin/* && ok "bin/* marked executable"

# 3. Local config (never clobber an existing one).
if [ -f "$here/config.sh" ]; then ok "config.sh already exists (left untouched)"
else cp "$here/config.example.sh" "$here/config.sh"; ok "created config.sh from config.example.sh"; fi

# 4. Runtime state dir, locked down (0700).
umask 077
mkdir -p "$STATE_DIR/panes"
chmod 700 "$STATE_DIR" "$STATE_DIR/panes"
ok "state dir $STATE_DIR (0700)"

# 5. Status-line signal patch. The monitor's authoritative trigger is the 5-hour
#    used_percentage + resets_at, which the patched statusline.py writes to
#    state.json on every render. The injector below is idempotent, keeps a .bak,
#    and is fail-soft: the added code can never raise or slow the status bar.
patch_statusline() {
  if [ ! -f "$STATUSLINE" ]; then
    warn "no $STATUSLINE — skipping the status-line patch."
    info "claude-autoresume still works via the on-screen-text fallback, but the"
    info "authoritative used_percentage trigger needs a python statusline that"
    info "parses the session JSON. Add one, then re-run ./install.sh."
    return 0
  fi
  rc=0
  CCAR_STATUSLINE="$STATUSLINE" python3 - <<'PY' || rc=$?
import os, re, sys

path = os.environ["CCAR_STATUSLINE"]
with open(path) as f:
    src = f.read()

if "dump_rate_limits" in src:
    print("\033[32m✓\033[0m status line already patched (dump_rate_limits present)")
    raise SystemExit(0)

# Anchor: the line that parses the session JSON off stdin. We insert the dump call
# right after it, at the same indentation, so we hook into the real parsed `data`.
anchor = re.search(r'^([ \t]*)([A-Za-z_]\w*)\s*=\s*json\.load\(\s*sys\.stdin\s*\)\s*$',
                   src, re.M)
if not anchor:
    raise SystemExit(2)  # caller prints manual instructions
indent, var = anchor.group(1), anchor.group(2)

# Back up once.
bak = path + ".bak"
if not os.path.exists(bak):
    with open(bak, "w") as f:
        f.write(src)

func = '''
def dump_rate_limits(data):
    """claude-autoresume: persist the 5h rate-limit block for the tmux monitor.

    Must never raise or block — this runs on every status-line render, and an
    exception here would blank the status bar. Local file write only.
    Skips the write when the five_hour block is absent so a fresh session
    doesn't clobber the last known resets_at with nulls.
    """
    try:
        import json, os, time
        five = (data.get("rate_limits") or {}).get("five_hour")
        if not five:
            return
        path = os.environ.get("CCAR_STATE_JSON") or os.path.expanduser(
            "~/.claude/autoresume/state.json"
        )
        state_dir = os.path.dirname(path)
        os.makedirs(state_dir, mode=0o700, exist_ok=True)
        os.chmod(state_dir, 0o700)
        payload = {
            "resets_at": five.get("resets_at"),
            "used_percentage": five.get("used_percentage"),
            "captured_at": int(time.time()),
        }
        tmp = path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, path)
        os.chmod(path, 0o600)
    except Exception:
        pass

'''

# Insert the function just before main()/the entrypoint, else append it.
defmain = re.search(r'^def main\(', src, re.M) or re.search(r'^if __name__', src, re.M)
if defmain:
    src = src[:defmain.start()] + func.lstrip("\n") + "\n\n" + src[defmain.start():]
else:
    src = src.rstrip("\n") + "\n\n" + func

# Insert the call after the (now possibly shifted) anchor line.
anchor = re.search(r'^([ \t]*)' + re.escape(var) + r'\s*=\s*json\.load\(\s*sys\.stdin\s*\)\s*$',
                   src, re.M)
call = f"{indent}dump_rate_limits({var})  # claude-autoresume\n"
src = src[:anchor.end()] + "\n" + call + src[anchor.end():]

with open(path, "w") as f:
    f.write(src)
print("\033[32m✓\033[0m patched %s (backup at %s.bak)" % (path, path))
PY
  if [ "$rc" -eq 2 ]; then
    warn "could not auto-patch $STATUSLINE (no 'data = json.load(sys.stdin)' anchor)."
    info "Add this call after you parse the session JSON, plus the dump_rate_limits"
    info "function (see the copy in your installed statusline.py / PLAN.md §3):"
    info "    dump_rate_limits(data)"
    info "It must be fail-soft (wrapped in try/except) so it can never break the bar."
  fi
  return 0
}
patch_statusline

# 6. The `claude` alias (interactive shells). Append once, with a marker, unless
#    the user already aliases claude. Set CCAR_NO_ALIAS=1 to skip editing rc.
if [ "${CCAR_NO_ALIAS:-0}" = "1" ]; then
  ok "skipped alias (CCAR_NO_ALIAS=1). Add manually: $ALIAS_LINE"
elif command -v claude >/dev/null 2>&1 && alias claude >/dev/null 2>&1; then
  ok "claude alias already defined (left untouched)"
elif [ -f "$BASHRC" ] && grep -qF "bin/cc-run" "$BASHRC"; then
  ok "$BASHRC already aliases claude to cc-run (left untouched)"
else
  {
    printf '\n# claude-autoresume: wrap interactive `claude` with auto-resume\n'
    printf '%s\n' "$ALIAS_LINE"
  } >>"$BASHRC"
  ok "added the claude alias to $BASHRC"
  info "open a new shell or run: source $BASHRC"
fi

echo
echo "Done. Start a tmux window per project and run: claude"
echo "Cancel a pending resume: your tmux prefix then X, or run bin/cc-cancel."
