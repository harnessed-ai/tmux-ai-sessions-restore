#!/usr/bin/env bash
# uninstall_hooks.sh [tool...] — remove the capture hooks installed by install_hooks.sh.
# Matches our own capture_session.sh command, so unrelated hooks are left untouched.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
. "$HERE/helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "✗ jq is required"; exit 1; }

# Match on the capture_session.sh script name — NOT its absolute path — so we remove our
# hook wherever the plugin was installed from (~/.tmux/plugins or ~/.config/tmux/plugins).
# Path-matching would leave a stale hook behind if the plugin had since moved.
MARKER="capture_session.sh"
tools="$*"   # optional tool names (default: every tool in tools.tsv)

# remove_hook_groups <json file>: strip our capture command from every event of a Claude-style
# hooks layout (Claude, Codex, Gemini), dropping groups left empty. Returns 1 if no file.
remove_hook_groups() {
	[ -f "$1" ] || return 1
	local tmp; tmp="$(mktemp)"
	jq --arg m "$MARKER" '
		if (.hooks? | type) == "object" then
			.hooks |= with_entries(
				.value |= ( map(.hooks |= map(select((.command // "") | contains($m) | not)))
				          | map(select((.hooks | length) > 0)) )
			)
		else . end
	' "$1" > "$tmp" && mv "$tmp" "$1"
}

# Strip our capture command from every Claude hook event (handles current
# UserPromptSubmit and any legacy SessionStart entries), dropping empty groups.
uninstall_claude() {
	local settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
	remove_hook_groups "$settings" || return 0
	echo "✓ Removed Claude hook from $settings"
}

uninstall_codex() {
	local file="${CODEX_HOME:-$HOME/.codex}/hooks.json"
	remove_hook_groups "$file" || return 0
	echo "✓ Removed Codex hook from $file"
}

# Strip our capture command from every Kiro hook event (userPromptSubmit and legacy
# agentSpawn) across all agent configs.
uninstall_kiro() {
	local f
	for f in "$HOME"/.kiro/agents/*.json; do
		[ -f "$f" ] || continue
		jq -e --arg m "$MARKER" '[.hooks?[]?[]? | select((.command // "") | contains($m))] | length > 0' "$f" >/dev/null 2>&1 || continue
		local tmp; tmp="$(mktemp)"
		jq --arg m "$MARKER" '
			if (.hooks? | type) == "object" then
				.hooks |= with_entries(.value |= map(select((.command // "") | contains($m) | not)))
			else . end
		' "$f" > "$tmp" && mv "$tmp" "$f"
		echo "✓ Removed Kiro hook from $f"
	done
}

# Remove our OpenCode plugin file (only if it is ours), from plugins/ and the older plugin/.
uninstall_opencode() {
	local d f
	d="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
	for f in "$d/plugins/tmux-ai-sessions-restore.js" "$d/plugin/tmux-ai-sessions-restore.js"; do
		[ -f "$f" ] && grep -q "$MARKER" "$f" 2>/dev/null || continue
		rm -f "$f"
		echo "✓ Removed OpenCode plugin $f"
	done
}

for tool in ${tools:-$(air_tools)}; do
	if declare -F "uninstall_$tool" >/dev/null; then "uninstall_$tool"
	else echo "• $tool: no uninstall_$tool in uninstall_hooks.sh — skipping"; fi
done
echo "Done. (The tmux @resurrect-hook-post-save-all entry is removed when you remove the plugin and restart tmux.)"
