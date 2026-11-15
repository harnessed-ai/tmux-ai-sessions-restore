#!/usr/bin/env bash
# install-hooks.sh — install the shared agent hook and register it with every supported
# agent CLI, so their panes publish the shared @agent_* state.
#
# Shared by the harnessed-ai tmux plugins (each ships an identical copy of this script,
# agent-hook.sh and agent-hook-opencode.js). The hook lives in ONE fixed place,
#
#     ${AGENT_HOOK_HOME:-${XDG_DATA_HOME:-~/.local/share}/harnessed-ai}/agent-hook.sh
#
# and every CLI's config points there. A plugin replaces that copy only with a newer one
# (agent-hook-version, line 2), so an older plugin never downgrades it, and the configs
# never change when plugins come and go. That matters for Codex, which ignores a new or
# changed hook until you approve it once in its /hooks screen.
#
#   Claude Code  ~/.claude/settings.json            (or $CLAUDE_CONFIG_DIR)
#   Kiro CLI     ~/.kiro/agents/<default agent>.json
#   Codex        ~/.codex/hooks.json                (or $CODEX_HOME) — approve in /hooks
#   OpenCode     ~/.config/opencode/plugins/harnessed-ai-agent-hook.js (no shell hooks:
#                a plugin translates its events)
#
# A CLI that isn't installed is skipped. Idempotent: one entry per event, other hooks left
# alone, and a config that is already right isn't rewritten (so reloading tmux changes
# nothing). Each file is backed up (*.agent-hook-bak-<ts>) only when it changes.
# AGENT_HOOK_TOOLS="claude codex" limits it to some CLIs. Reverse with uninstall-hooks.sh.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="${AGENT_HOOK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/harnessed-ai}"
HOOK="$SHARED/agent-hook.sh"
MARKER="agent-hook.sh"
TS="$(date +%Y%m%d-%H%M%S)"

command -v jq >/dev/null 2>&1 || { echo "✗ jq is required (brew install jq)"; exit 1; }

# hook_version <path>: the agent-hook-version on line 2 (copies without one are 1).
hook_version() {
	local v
	v="$(sed -n '2s/^# agent-hook-version: *\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null)"
	printf '%s' "${v:-1}"
}

# write_if_changed <file> <new-content-file>: replace <file>, with a backup, if different.
write_if_changed() {
	if [ -f "$1" ] && cmp -s "$1" "$2"; then
		rm -f "$2"
		return 1
	fi
	[ -f "$1" ] && cp "$1" "$1.agent-hook-bak-$TS"
	mv "$2" "$1"
}

# The shared copy: installed, or upgraded when ours is newer (never downgraded).
install_shared() {
	mkdir -p "$SHARED"
	if [ ! -f "$HOOK" ] || [ "$(hook_version "$HERE/agent-hook.sh")" -gt "$(hook_version "$HOOK")" ]; then
		local f tmp
		for f in agent-hook.sh agent-hook-opencode.js; do
			[ -f "$HERE/$f" ] || continue
			tmp="$(mktemp "$SHARED/.$f.XXXXXX")"
			cp "$HERE/$f" "$tmp" && chmod 755 "$tmp" && mv "$tmp" "$SHARED/$f"
		done
		echo "✓ agent hook v$(hook_version "$HOOK") → $HOOK"
	else
		echo "• agent hook v$(hook_version "$HOOK") already at $HOOK"
	fi
}

# register_groups <file> <tool> <event...>: Claude-style layout (Claude Code, Codex):
# .hooks[<event>] = [ { hooks: [ { type: "command", command } ] } ]. Drops our entries from
# any path first, then adds one per event; a file that is already right is left alone.
register_groups() {
	local file="$1" tool="$2"; shift 2
	local events; events="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
	mkdir -p "$(dirname "$file")"
	[ -f "$file" ] || echo '{}' > "$file"
	if jq -e --arg hook "$HOOK" --arg m "$MARKER" --arg tool "$tool" --argjson events "$events" '
		([.hooks // {} | .[][]?.hooks[]?.command // empty | select(contains($m))] | sort) ==
		([$events[] | "bash \"\($hook)\" \($tool) \(.)"] | sort)' "$file" >/dev/null 2>&1; then
		return 1
	fi
	local tmp; tmp="$(mktemp)"
	jq --arg hook "$HOOK" --arg m "$MARKER" --arg tool "$tool" --argjson events "$events" '
		.hooks = (.hooks // {})
		| .hooks |= with_entries(
			.value |= ( map(.hooks |= map(select((.command // "") | contains($m) | not)))
			          | map(select((.hooks | length) > 0)) ))
		| reduce $events[] as $e (.;
			.hooks[$e] = ((.hooks[$e] // []) + [ { "hooks": [ {
				"type": "command",
				"command": "bash \"\($hook)\" \($tool) \($e)"
			} ] } ]))
	' "$file" > "$tmp"
	write_if_changed "$file" "$tmp"
}

CLAUDE_EVENTS=(SessionStart UserPromptSubmit PreToolUse PostToolUse PermissionRequest Notification Stop SessionEnd)

install_claude() {
	if ! command -v claude >/dev/null 2>&1; then
		echo "• claude not found — skipping Claude hooks"
		return
	fi
	local settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
	if register_groups "$settings" claude "${CLAUDE_EVENTS[@]}"; then
		echo "✓ Claude hooks (${CLAUDE_EVENTS[*]}) → $settings"
	else
		echo "• Claude hooks already installed"
	fi
}

# Codex: same event names and layout as Claude. It skips a new or changed hook until you
# approve it in /hooks; the fixed hook path means that happens once, not on every update.
CODEX_EVENTS=(SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop SessionEnd)

install_codex() {
	if ! command -v codex >/dev/null 2>&1; then
		echo "• codex not found — skipping Codex hooks"
		return
	fi
	local file="${CODEX_HOME:-$HOME/.codex}/hooks.json"
	if register_groups "$file" codex "${CODEX_EVENTS[@]}"; then
		echo "✓ Codex hooks (${CODEX_EVENTS[*]}) → $file"
		echo "  ! Codex ignores new hooks until you approve them: run codex, open /hooks, approve."
	else
		echo "• Codex hooks already installed"
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
	local events; events="$(printf '%s\n' "${KIRO_EVENTS[@]}" | jq -R . | jq -s .)"
	if jq -e --arg hook "$HOOK" --arg m "$MARKER" --argjson events "$events" '
		([.hooks // {} | .[][]?.command // empty | select(contains($m))] | sort) ==
		([$events[] | "bash \"\($hook)\" kiro \(.)"] | sort)' "$file" >/dev/null 2>&1; then
		echo "• Kiro hooks already installed"
		return
	fi
	local tmp; tmp="$(mktemp)"
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

opencode_plugin_file() {
	printf '%s/plugins/harnessed-ai-agent-hook.js' "${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
}

# OpenCode has no shell hooks: install the adapter plugin, pointed at the shared hook.
install_opencode() {
	if ! command -v opencode >/dev/null 2>&1; then
		echo "• opencode not found — skipping OpenCode plugin"
		return
	fi
	local src="$SHARED/agent-hook-opencode.js"
	[ -f "$src" ] || src="$HERE/agent-hook-opencode.js"
	local file hook tmp
	file="$(opencode_plugin_file)"
	hook="$(jq -rn --arg p "$HOOK" '$p | tojson | .[1:-1]')"   # JS-string-escaped path
	mkdir -p "$(dirname "$file")"
	tmp="$(mktemp)"
	HOOK_ESC="$hook" awk '{ i = index($0, "__AGENT_HOOK__"); if (i) $0 = substr($0, 1, i - 1) ENVIRON["HOOK_ESC"] substr($0, i + 14); print }' \
		"$src" > "$tmp"
	if write_if_changed "$file" "$tmp"; then
		echo "✓ OpenCode plugin → $file"
	else
		echo "• OpenCode plugin already installed"
	fi
}

install_shared
for t in ${AGENT_HOOK_TOOLS:-claude kiro codex opencode}; do
	case "$t" in
		claude)   install_claude ;;
		kiro)     install_kiro ;;
		codex)    install_codex ;;
		opencode) install_opencode ;;
	esac
done
echo "Running agents publish their state from their next event (prompt or tool call)."
