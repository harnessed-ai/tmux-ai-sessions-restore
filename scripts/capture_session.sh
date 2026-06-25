#!/usr/bin/env bash
# capture_session.sh <tool>
#
# Invoked by the AI CLI's first-prompt hook (Claude UserPromptSubmit / Kiro
# userPromptSubmit). Capturing on the first prompt (rather than session start) means we only
# ever mark a pane once the session actually has a transcript to resume.
#
# The hook runs *inside the tmux pane*, so $TMUX_PANE identifies exactly which pane holds
# this conversation. We stamp the live session id onto that pane as tmux pane-options;
# the save step (rewrite_save.sh) later turns them into a resume command.
#
# The hook event JSON arrives on stdin and carries .session_id and .cwd (same shape for
# both tools). This script must never fail or talk to the host tool: it always exits 0 and
# emits nothing on stdout (these hooks would otherwise inject stdout into the conversation).

tool="${1:-}"
[ -n "$tool" ] || exit 0

# Only meaningful when launched inside tmux.
[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0
command -v jq   >/dev/null 2>&1 || exit 0

# From here on, never leak anything to the conversation (stdin still readable on fd 0).
exec >/dev/null 2>&1

json="$(cat)"
id="$(printf '%s' "$json" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$id" ] || exit 0
cwd="$(printf '%s' "$json" | jq -r '.cwd // empty' 2>/dev/null)"

tmux set-option -p -t "$TMUX_PANE" '@ai_tool'       "$tool" 2>/dev/null
tmux set-option -p -t "$TMUX_PANE" '@ai_session_id' "$id"   2>/dev/null
[ -n "$cwd" ] && tmux set-option -p -t "$TMUX_PANE" '@ai_session_cwd' "$cwd" 2>/dev/null

exit 0
