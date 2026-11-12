# Using claude-autoresume

Everything past the quick start: joining and reopening sessions, rendering, the window
glyphs, the remote-control watchdog, operating the monitor, and the test suites. Detection
and resume are specified in [DESIGN.md](DESIGN.md).

## Sessions

Inside a wrapped session, `/autoresume-cancel` drops that session's pending resume.

Inside tmux, your prefix then `X` is the same cancel (`CCAR_CANCEL_KEY`). Prefix then `d` detaches the fallback session; a later `claude` or `cc-attach` walks back in. Use those commands to attach. They set `TERM` the way the launcher does, so Claude's TUI renders. A hand-rolled `tmux -L ccar attach` uses the shell's `TERM` and garbles the screen.

Non-interactive `claude` is the real CLI: `-p` / `--print`, subcommands (`mcp`, `doctor`, `update`, `auth`, …), `--version`, `--help`, and any piped stdin. The launcher `exec`s `claude`, which bypasses the alias.

A plain `claude` from a shell that already has a wrapped session shows that session and asks before joining. `Y` attaches, on this directory's window when one exists. `N` ends that session, running turns included, and starts over with one window for the current directory.

```
A wrapped session is already running on socket 'ccar':

  1  /home/you/project-a   idle   <- you are here
  2  /home/you/project-b   working
  3  /home/you/project-c   parked at the rate limit

  [Y] attach, on this directory's own window
  [N] end that session — all 3 window(s) above — and start over with just /home/you/project-a

Attach? [Y/n]
```

A prompt, `--resume`, or any other option still gets its own window. Read the state column before answering `N`.

After a reboot or `wsl --shutdown`, tmux has no session to restore. The conversations are still under `~/.claude/projects/`, keyed by directory, and the pane registry still names the tabs that were open. A bare `claude` (or `claude -c`) from a plain shell then offers them in an arrow-key list, including the directory you launched from:

```
  Reopen which sessions?  ↑↓ move · space toggle · a all · n none · enter go · q cancel
 › [x] /home/you/project-a
   [x] /home/you/project-b
   [x] /home/you/project-c
```

Each reopened tab continues its last conversation when one exists, and starts fresh otherwise. `q` falls through to a single new window. `cc-attach` is the same flow, and the entry point when you only want to reattach or reopen. Run it from a plain shell; from inside tmux it stops, because attaching there would nest a server.

### Rendering

Claude's TUI needs `default-terminal tmux-256color` and truecolor (`terminal-features ",*:RGB"`). On your own server, put that in `~/.tmux.conf`. The fallback server loads this repo's [`tmux.conf`](../tmux.conf), which sources yours, applies the same caps, and forwards Claude's terminal title to the outer tab. Scroll with tmux copy-mode (prefix then `[`). If Windows Terminal keeps a stale title, the profile's "Suppress title changes" setting is what blocks it.

### Working glyph

Claude's title glyph stays `✳` for a running turn and for an idle prompt. The monitor swaps a leading `✳` on the window name for the state it has published:

```
1:✽ project-a    Claude, running a turn
2:✳ project-b    Claude, idle at the prompt
3:⧗ project-c    parked at the limit, waiting for the window to reset
4:✻ project-d    Claude idle; subagents, a grok job or a background shell it started are still running
5:⠏ project-e    Grok, running a turn
6:🚹 project-f    Grok, idle
```

Put that leading `✳` on Claude and Grok window names in `~/.tmux.conf`. Naming windows is tmux's job:

```tmux
set -g automatic-rename on
set -g automatic-rename-format '#{?#{||:#{==:#{pane_current_command},claude},#{==:#{pane_current_command},grok}},✳ ,}#{b:pane_current_path}'
```

A window without the anchor — a shell, an editor — is left as it is. The same swap is applied to the terminal title, so the tab and the taskbar follow the busiest watched pane on that tmux server.

Latch and resume apply to Claude panes. Grok panes on a server that already has a registered Claude pane get glyphs only. The Grok MCP server is published at [claude-code-toolkit](https://github.com/ethanez713/claude-code-toolkit).

### Remote control

Claude Code's own Remote Control reconnects across sleep and network blips when *"Enable Remote Control for all sessions"* is on. What remains is a footer that reads `/rc failed` after that recovery is exhausted. Set `CCAR_RC_ENABLE=1` and the monitor re-types `/remote-control` into a pane it can show is idle. The rules are in [DESIGN.md](DESIGN.md) §8a.

### Operating the monitor

Bash reads `monitor.sh` once, at start. After you edit it, stop the pid in `~/.claude/autoresume/monitor.pid` and run `claude` again (or end the session and start it again).

```bash
tmux -L ccar ls                              # fallback session and windows
tail -f ~/.claude/autoresume/monitor.log     # monitor log
tmux -L ccar kill-session -t cc              # end the fallback session
```

`~/.claude/autoresume/stats.jsonl` is a heartbeat the monitor appends: its CPU over the window, and how many panes were registered, running, and busy. Inspect it with `tail` or `jq`. `CCAR_STATS_SECONDS=0` turns it off.

## Test suites

Unit-style, run by default:

| script | covers |
|---|---|
| `tests/attach_plan_test.sh` | what `cc-attach` will reopen, and its guards |
| `tests/busy_glyph_test.sh` | working-vs-idle colour and title checks; tmux stubbed |
| `tests/busy_hook_test.sh` | hook files and `decide_busy` |
| `tests/deep_idle_test.sh` | the quiet wait |
| `tests/launch_join_test.sh` | which launches rejoin an open window |
| `tests/rc_watchdog_test.sh` | remote-control screen reading |
| `tests/tui_test.sh` | the arrow-key pick-list |

These need `tmux` and run only with `--e2e`:

| script | covers |
|---|---|
| `tests/busy_format_test.sh` | glyph formats rendered on a throwaway tmux server |
| `tests/reconstruct_test.sh` | the liveness filter for reopen |
| `tests/attach_rebuild_e2e.sh` | `cc-attach` rebuilding a dead fallback session |
| `tests/busy_glyph_e2e.sh` | a real `monitor.sh` driving the window list |
| `tests/launch_join_e2e.sh` | `claude` from a plain shell when a session is already up |
| `tests/launch_reconstruct_e2e.sh` | `claude` offering tabs after the server is gone |
| `tests/rc_watchdog_e2e.sh` | the watchdog typing into a scratch pane |
