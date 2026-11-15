#!/usr/bin/env bash
# uninstall-hooks.sh [--provider NAME] — stop this plugin using the shared agent hook.
#
# Each loaded harnessed-ai plugin advertises itself in the tmux option
# @agent-hook-provider-<name>; --provider NAME drops ours first. While another plugin
# still uses the hook, nothing else changes: the hook lives in one shared place
# (see install-hooks.sh), so there is nothing to hand over. When no plugin is left, the
# hook is unregistered from every CLI (Claude Code, Kiro, Codex, OpenCode) and the shared
# copy is removed. Entries are matched by script name, not path, so copies registered by
# older versions (from a plugin's own folder) are removed too. AGENT_HOOK_TOOLS limits the
# unregistering to some CLIs (and then keeps the shared copy).

set -euo pipefail
MARKER="agent-hook.sh"
SHARED="${AGENT_HOOK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/harnessed-ai}"
command -v jq >/dev/null 2>&1 || { echo "✗ jq is required"; exit 1; }

if [ "${1:-}" = --provider ] && [ -n "${2:-}" ]; then
	tmux set-option -gu "@agent-hook-provider-$2" 2>/dev/null || true
fi

others="$(tmux show-options -g 2>/dev/null | sed -n 's/^@agent-hook-provider-\([^ ]*\) .*/\1/p' | paste -sd, - || true)"
if [ -n "$others" ]; then
	echo "• the shared agent hook is still used by: $others — leaving it in place"
	exit 0
fi

# Claude-style layout (Claude Code, Codex): strip our command, drop emptied groups/events.
remove_groups() {
	[ -f "$1" ] || return 0
	jq -e --arg m "$MARKER" '[.. | objects | .command? // empty | strings | select(contains($m))] | length > 0' "$1" >/dev/null 2>&1 || return 0
	local tmp; tmp="$(mktemp)"
	jq --arg m "$MARKER" '
		if (.hooks? | type) == "object" then
			.hooks |= with_entries(
				.value |= ( map(.hooks |= map(select((.command // "") | contains($m) | not)))
				          | map(select((.hooks | length) > 0)) ))
			| .hooks |= with_entries(select((.value | length) > 0))
		else . end
	' "$1" > "$tmp" && mv "$tmp" "$1"
	echo "✓ Removed $2 hooks from $1"
}

uninstall_claude() { remove_groups "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" Claude; }
uninstall_codex()  { remove_groups "${CODEX_HOME:-$HOME/.codex}/hooks.json" Codex; }

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

uninstall_opencode() {
	local f
	f="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}/plugins/harnessed-ai-agent-hook.js"
	[ -f "$f" ] && rm -f "$f" && echo "✓ Removed OpenCode plugin $f"
	return 0
}

for t in ${AGENT_HOOK_TOOLS:-claude kiro codex opencode}; do
	case "$t" in
		claude)   uninstall_claude ;;
		kiro)     uninstall_kiro ;;
		codex)    uninstall_codex ;;
		opencode) uninstall_opencode ;;
	esac
done

if [ -z "${AGENT_HOOK_TOOLS:-}" ]; then
	rm -f "$SHARED/agent-hook.sh" "$SHARED/agent-hook-opencode.js"
	rmdir "$SHARED" 2>/dev/null || true
	echo "✓ Removed the shared agent hook ($SHARED)"
fi
