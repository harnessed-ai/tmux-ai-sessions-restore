#!/usr/bin/env bash
# uninstall_hooks.sh — remove the capture hooks installed by install_hooks.sh.
# Matches our own capture_session.sh command, so unrelated hooks are left untouched.

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "✗ jq is required"; exit 1; }

# Match on the capture_session.sh script name — NOT its absolute path — so we remove our
# hook wherever the plugin was installed from (~/.tmux/plugins or ~/.config/tmux/plugins).
# Path-matching would leave a stale hook behind if the plugin had since moved.
MARKER="capture_session.sh"

# Strip our capture command from every Claude hook event (handles current
# UserPromptSubmit and any legacy SessionStart entries), dropping empty groups.
uninstall_claude() {
	local settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
	[ -f "$settings" ] || return
	local tmp; tmp="$(mktemp)"
	jq --arg m "$MARKER" '
		if (.hooks? | type) == "object" then
			.hooks |= with_entries(
				.value |= ( map(.hooks |= map(select((.command // "") | contains($m) | not)))
				          | map(select((.hooks | length) > 0)) )
			)
		else . end
	' "$settings" > "$tmp" && mv "$tmp" "$settings"
	echo "✓ Removed Claude hook from $settings"
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

uninstall_claude
uninstall_kiro
echo "Done. (The tmux @resurrect-hook-post-save-all entry is removed when you remove the plugin and restart tmux.)"
