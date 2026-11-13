#!/usr/bin/env bash
# uninstall-hooks.sh [--provider NAME] — stop this plugin providing agent-hook.sh.
#
# The hook is shared by the harnessed-ai plugins. Each loaded plugin advertises its copy
# in the tmux option @agent-hook-provider-<name>. --provider NAME drops our own
# advertisement first. If another provider is still loaded, the hook is handed over to
# its copy (the highest agent-hook-version wins) so that plugin keeps working; only when
# no provider is left are the entries removed from Claude Code and Kiro CLI configs.
# Entries are matched by script name, not path, so copies from any checkout are found.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINE="$HERE/agent-hook.sh"
MARKER="agent-hook.sh"
command -v jq >/dev/null 2>&1 || { echo "✗ jq is required"; exit 1; }

if [ "${1:-}" = --provider ] && [ -n "${2:-}" ]; then
	tmux set-option -gu "@agent-hook-provider-$2" 2>/dev/null || true
fi

hook_version() {
	local v
	v="$(sed -n '2s/^# agent-hook-version: *\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null)"
	printf '%s' "${v:-1}"
}

# Another loaded plugin's copy (highest version), if any.
other=""
while read -r name; do
	[ -n "$name" ] || continue
	path="$(tmux show-options -gqv "$name" 2>/dev/null || true)"
	[ -n "$path" ] && [ "$path" != "$MINE" ] && [ -f "$path" ] || continue
	if [ -z "$other" ] || [ "$(hook_version "$path")" -gt "$(hook_version "$other")" ]; then
		other="$path"
	fi
done < <(tmux show-options -g 2>/dev/null | sed -n 's/^\(@agent-hook-provider-[^ ]*\) .*/\1/p')

if [ -n "$other" ]; then
	echo "• another plugin still provides agent-hook.sh — handing over to $other"
	exec bash "$HERE/install-hooks.sh" --hook "$other"
fi

uninstall_claude() {
	local settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
	[ -f "$settings" ] || return 0
	local tmp; tmp="$(mktemp)"
	jq --arg m "$MARKER" '
		if (.hooks? | type) == "object" then
			.hooks |= with_entries(
				.value |= ( map(.hooks |= map(select((.command // "") | contains($m) | not)))
				          | map(select((.hooks | length) > 0)) ))
			| .hooks |= with_entries(select((.value | length) > 0))
		else . end
	' "$settings" > "$tmp" && mv "$tmp" "$settings"
	echo "✓ Removed Claude hooks from $settings"
}

uninstall_kiro() {
	local f
	for f in "$HOME"/.kiro/agents/*.json; do
		[ -f "$f" ] || continue
		jq -e --arg m "$MARKER" '[.hooks?[]?[]? | select((.command // "") | contains($m))] | length > 0' "$f" >/dev/null 2>&1 || continue
		local tmp; tmp="$(mktemp)"
		jq --arg m "$MARKER" '
			if (.hooks? | type) == "object" then
				.hooks |= with_entries(.value |= map(select((.command // "") | contains($m) | not)))
				| .hooks |= with_entries(select((.value | length) > 0))
			else . end
		' "$f" > "$tmp" && mv "$tmp" "$f"
		echo "✓ Removed Kiro hooks from $f"
	done
}

for t in ${AGENT_HOOK_TOOLS:-claude kiro}; do
	case "$t" in
		claude) uninstall_claude ;;
		kiro)   uninstall_kiro ;;
	esac
done
