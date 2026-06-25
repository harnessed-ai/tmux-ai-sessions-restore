#!/usr/bin/env bash
# install_hooks.sh — register the per-tool first-prompt hooks that let
# tmux-ai-sessions-restore learn which conversation each pane holds.
#
# We hook the first-prompt event (Claude UserPromptSubmit / Kiro userPromptSubmit) rather
# than session start, so a pane is only marked once its session actually has a transcript.
#
# Idempotent and reversible (see uninstall_hooks.sh). You launch claude / kiro-cli
# exactly as before; these hooks just stamp the live session id onto the tmux pane.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP="$HERE/capture_session.sh"

command -v jq >/dev/null 2>&1 || { echo "✗ jq is required (brew install jq)"; exit 1; }

install_claude() {
	if ! command -v claude >/dev/null 2>&1; then
		echo "• claude not found — skipping Claude hook"
		return
	fi
	local settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
	local cmd="bash \"$CAP\" claude"
	mkdir -p "$(dirname "$settings")"
	[ -f "$settings" ] || echo '{}' > "$settings"
	local tmp; tmp="$(mktemp)"
	jq --arg cmd "$cmd" '
		.hooks = (.hooks // {})
		| .hooks.UserPromptSubmit = (.hooks.UserPromptSubmit // [])
		| if any(.hooks.UserPromptSubmit[]?; (.hooks[]?.command) == $cmd)
		  then .
		  else .hooks.UserPromptSubmit += [ { "hooks": [ { "type": "command", "command": $cmd } ] } ]
		  end
	' "$settings" > "$tmp" && mv "$tmp" "$settings"
	echo "✓ Claude UserPromptSubmit hook → $settings"
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

install_kiro() {
	if ! command -v kiro-cli >/dev/null 2>&1; then
		echo "• kiro-cli not found — skipping Kiro hook"
		return
	fi
	local cmd="bash \"$CAP\" kiro"
	local def file
	def="$(kiro_default_agent)"
	file="$HOME/.kiro/agents/$def.json"
	mkdir -p "$HOME/.kiro/agents"

	# If the default agent is built-in (no file), materialise a same-name, file-backed
	# clone that shadows it. VISUAL/EDITOR=true keeps `agent create` non-interactive.
	if [ ! -f "$file" ]; then
		VISUAL=true EDITOR=true kiro-cli agent create "$def" --from "$def" >/dev/null 2>&1 || true
	fi
	if [ ! -f "$file" ]; then
		echo "! Could not materialise Kiro agent '$def' at $file — skipping Kiro hook" >&2
		return
	fi

	local tmp; tmp="$(mktemp)"
	jq --arg cmd "$cmd" '
		.hooks = (.hooks // {})
		| .hooks.userPromptSubmit = (.hooks.userPromptSubmit // [])
		| if any(.hooks.userPromptSubmit[]?; .command == $cmd)
		  then .
		  else .hooks.userPromptSubmit += [ { "command": $cmd } ]
		  end
	' "$file" > "$tmp" && mv "$tmp" "$file"
	echo "✓ Kiro userPromptSubmit hook → $file (default agent: $def)"
}

install_claude
install_kiro
echo
echo "Done. Newly started/resumed AI sessions are captured automatically;"
echo "existing ones get picked up on their next start."
