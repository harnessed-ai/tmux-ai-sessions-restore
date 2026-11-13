#!/usr/bin/env bash
# capture_session.sh <tool>
#
# Invoked by the AI CLI's prompt hook (Claude UserPromptSubmit / Kiro userPromptSubmit / ...,
# see install_hooks.sh) on every prompt. <tool> is a tool name from tools.tsv. Capturing on a prompt (rather than session start) means we only ever mark a
# pane once the session actually has a transcript to resume.
#
# The hook runs *inside the tmux pane*, so $TMUX_PANE identifies exactly which pane holds
# this conversation. We stamp the live session id onto that pane as tmux pane-options,
# together with the pid of the CLI process that fired the hook: the save step
# (rewrite_save.sh) only trusts a marker while that same process is still running in the
# pane, so a CLI that exited and was replaced by another can't leave a stale id behind.
#
# The hook event JSON arrives on stdin and carries .session_id and .cwd (same shape for
# every tool; a tool without shell hooks gets a shim that writes this JSON). This script must never fail or talk to the host tool: it always exits 0 and
# emits nothing on stdout (these hooks would otherwise inject stdout into the conversation).

tool="${1:-}"
[ -n "$tool" ] || exit 0

# Only meaningful when launched inside tmux.
[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0
command -v jq   >/dev/null 2>&1 || exit 0

# From here on, never leak anything to the conversation (stdin still readable on fd 0).
exec >/dev/null 2>&1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
. "$HERE/helpers.sh"

json="$(cat)"
id="$(printf '%s' "$json" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$id" ] || exit 0
cwd="$(printf '%s' "$json" | jq -r '.cwd // empty' 2>/dev/null)"

# The CLI process this hook belongs to: the nearest ancestor that is the tool's CLI (hooks run
# through a shell, which may or may not exec us). Matched by comm, argv[0], or a node/bun
# script name (air_is_cli) — the same rule plan.awk uses at save time.
air_tool_regex "$tool" >/dev/null || exit 0
cli_pid=""
cli_args=""
pid="$PPID"
for _ in 1 2 3 4 5 6; do
    case "$pid" in ''|0|1) break ;; esac
    info="$(ps -o ppid=,comm= -p "$pid" 2>/dev/null)" || break
    read -r ppid comm <<< "$info"
    args="$(ps -o args= -p "$pid" 2>/dev/null)"
    if air_is_cli "$tool" "$comm" "$args"; then cli_pid="$pid"; cli_args="$args"; break; fi
    pid="$ppid"
done

# A one-shot run inside the pane (e.g. `claude -p ...` started by the interactive session's
# Bash tool, or a --bg session) fires the same hook; it must not take over the pane's marker.
# What counts as one-shot is the tool's oneshot column in tools.tsv.
if [ -n "$cli_pid" ] && air_is_oneshot "$tool" "$cli_args"; then exit 0; fi

tmux set-option -p -t "$TMUX_PANE" '@ai_tool' "$tool" \; \
     set-option -p -t "$TMUX_PANE" '@ai_session_id' "$id" \; \
     set-option -p -t "$TMUX_PANE" '@ai_pid' "$cli_pid" \; \
     set-option -p -t "$TMUX_PANE" '@ai_session_cwd' "$cwd" 2>/dev/null

exit 0
