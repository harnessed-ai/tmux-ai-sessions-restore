#!/usr/bin/env bash
# install-hooks.sh [--hook PATH] — register agent-hook.sh for every lifecycle event of
# Claude Code and Kiro CLI, so their panes publish the shared @agent_* state.
#
# Shared by the harnessed-ai plugins (each ships an identical copy). Idempotent: any
# existing agent-hook.sh entry (any plugin, any path) is replaced by exactly one per
# event, so the hook never runs twice. When another plugin's copy is already registered
# and is at least as new (agent-hook-version), that copy is kept: an older plugin never
# downgrades a newer one, and two plugins with the same version don't keep swapping. --hook PATH registers a specific copy (used for hand-over by
# uninstall-hooks.sh). AGENT_HOOK_TOOLS="claude" limits it to some tools. Each file is backed up (*.agent-hook-bak-<ts>) only when it
# changes. Reverse with uninstall-hooks.sh.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/agent-hook.sh"
MARKER="agent-hook.sh"
TS="$(date +%Y%m%d-%H%M%S)"
FORCE=""
if [ "${1:-}" = --hook ] && [ -n "${2:-}" ]; then HOOK="$2"; FORCE=1; fi

command -v jq >/dev/null 2>&1 || { echo "✗ jq is required (brew install jq)"; exit 1; }

# hook_version <path>: the agent-hook-version on line 2 (copies without one are 1).
hook_version() {
	local v
	v="$(sed -n '2s/^# agent-hook-version: *\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null)"
	printf '%s' "${v:-1}"
}

# registered_hook <config.json>: path of the agent-hook.sh currently registered there.
registered_hook() {
	[ -f "$1" ] || return 0
	jq -r '[.. | objects | .command? // empty | strings | select(contains("agent-hook.sh"))][0] // empty' "$1" 2>/dev/null |
		sed -n 's/^bash "\([^"]*\)".*/\1/p'
}

# prefer_newer <config.json>: keep a registered copy that is at least as new as ours.
prefer_newer() {
	[ -z "$FORCE" ] || return 0
	local cur; cur="$(registered_hook "$1")"
	if [ -n "$cur" ] && [ "$cur" != "$HOOK" ] && [ -f "$cur" ] &&
		[ "$(hook_version "$cur")" -ge "$(hook_version "$HOOK")" ]; then
		echo "• keeping registered agent-hook.sh (v$(hook_version "$cur")) at $cur"
		HOOK="$cur"
	fi
}

# write_if_changed <file> <new-content-file>
write_if_changed() {
	if cmp -s "$1" "$2"; then
		rm -f "$2"
		return 1
	fi
	cp "$1" "$1.agent-hook-bak-$TS"
	mv "$2" "$1"
}

CLAUDE_EVENTS=(SessionStart UserPromptSubmit PreToolUse PostToolUse PermissionRequest Notification Stop SessionEnd)

install_claude() {
	if ! command -v claude >/dev/null 2>&1; then
		echo "• claude not found — skipping Claude hooks"
		return
	fi
	local settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
	mkdir -p "$(dirname "$settings")"
	[ -f "$settings" ] || echo '{}' > "$settings"
	prefer_newer "$settings"
	local events; events="$(printf '%s\n' "${CLAUDE_EVENTS[@]}" | jq -R . | jq -s .)"
	local tmp; tmp="$(mktemp)"
	if jq -e --arg hook "$HOOK" --arg m "$MARKER" --argjson events "$events" '
		# already exactly right (one entry per event, this copy, nowhere else)? leave the file
		# alone, so plugins re-installing on every tmux load do not reshuffle hook order.
		([.hooks // {} | .[][]?.hooks[]?.command // empty | select(contains($m))] | sort) ==
		([$events[] | "bash \"\($hook)\" claude \(.)"] | sort)' "$settings" >/dev/null 2>&1; then
		echo "• Claude hooks already installed"
		return
	fi
	jq --arg hook "$HOOK" --arg m "$MARKER" --argjson events "$events" '
		.hooks = (.hooks // {})
		# drop our entries everywhere (any path, any event), keeping unrelated hooks
		| .hooks |= with_entries(
			.value |= ( map(.hooks |= map(select((.command // "") | contains($m) | not)))
			          | map(select((.hooks | length) > 0)) ))
		| reduce $events[] as $e (.;
			.hooks[$e] = ((.hooks[$e] // []) + [ { "hooks": [ {
				"type": "command",
				"command": "bash \"\($hook)\" claude \($e)"
			} ] } ]))
	' "$settings" > "$tmp"
	if write_if_changed "$settings" "$tmp"; then
		echo "✓ Claude hooks (${CLAUDE_EVENTS[*]}) → $settings"
	else
		echo "• Claude hooks already installed"
	fi
}

# Current default Kiro agent (the entry marked with '*' in `kiro-cli agent list`).
kiro_default_agent() {
	local name
	name="$(kiro-cli agent list 2>/dev/null \
		| sed 's/\x1b\[[0-9;]*m//g' \
		| sed -n 's/^[[:space:]]*\*[[:space:]]*\([A-Za-z0-9_-][A-Za-z0-9_-]*\).*/\1/p' \
		| head -1)"
	printf '%s' "${name:-kiro_default}"
}

KIRO_EVENTS=(agentSpawn userPromptSubmit preToolUse postToolUse stop)

install_kiro() {
	if ! command -v kiro-cli >/dev/null 2>&1; then
		echo "• kiro-cli not found — skipping Kiro hooks"
		return
	fi
	local def file
	def="$(kiro_default_agent)"
	file="$HOME/.kiro/agents/$def.json"
	mkdir -p "$HOME/.kiro/agents"
	# A built-in default agent has no file: materialise a same-name, file-backed clone.
	if [ ! -f "$file" ]; then
		VISUAL=true EDITOR=true kiro-cli agent create "$def" --from "$def" >/dev/null 2>&1 || true
	fi
	if [ ! -f "$file" ]; then
		echo "! Could not materialise Kiro agent '$def' at $file — skipping Kiro hooks" >&2
		return
	fi
	prefer_newer "$file"
	local events; events="$(printf '%s\n' "${KIRO_EVENTS[@]}" | jq -R . | jq -s .)"
	local tmp; tmp="$(mktemp)"
	if jq -e --arg hook "$HOOK" --arg m "$MARKER" --argjson events "$events" '
		([.hooks // {} | .[][]?.command // empty | select(contains($m))] | sort) ==
		([$events[] | "bash \"\($hook)\" kiro \(.)"] | sort)' "$file" >/dev/null 2>&1; then
		echo "• Kiro hooks already installed"
		return
	fi
	jq --arg hook "$HOOK" --arg m "$MARKER" --argjson events "$events" '
		.hooks = (.hooks // {})
		| .hooks |= with_entries(.value |= map(select((.command // "") | contains($m) | not)))
		| reduce $events[] as $e (.;
			.hooks[$e] = ((.hooks[$e] // []) + [ { "command": "bash \"\($hook)\" kiro \($e)" } ]))
	' "$file" > "$tmp"
	if write_if_changed "$file" "$tmp"; then
		echo "✓ Kiro hooks (${KIRO_EVENTS[*]}) → $file (default agent: $def)"
	else
		echo "• Kiro hooks already installed"
	fi
}

# AGENT_HOOK_TOOLS limits which tools are wired (default: both), e.g. for tests.
for t in ${AGENT_HOOK_TOOLS:-claude kiro}; do
	case "$t" in
		claude) install_claude ;;
		kiro)   install_kiro ;;
	esac
done
echo "Running agents publish their state from their next event (prompt or tool call)."
