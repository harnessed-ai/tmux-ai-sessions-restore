#!/usr/bin/env bash
# install_hooks.sh [--check] — register the per-tool prompt hooks that let
# tmux-ai-sessions-restore learn which conversation each pane holds.
#
# We hook the prompt event (Claude UserPromptSubmit / Kiro userPromptSubmit / ...) rather
# than session start, so a pane is only marked once its session actually has a transcript.
#
# One install_<tool> (and check_<tool>) function per tool in tools.tsv; a CLI that isn't
# installed is skipped. Idempotent and reversible (see uninstall_hooks.sh). You launch the
# CLIs exactly as before; these hooks just stamp the live session id onto the tmux pane.
#
# --check changes nothing: it reports, per tool, whether the CLI and our hook are present.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP="$HERE/capture_session.sh"
# shellcheck source=scripts/helpers.sh
. "$HERE/helpers.sh"

mode=install
[ "${1:-}" = "--check" ] && mode=check
[ "$mode" = check ] || command -v jq >/dev/null 2>&1 || { echo "✗ jq is required (brew install jq)"; exit 1; }

# hook_state <file>: "present" if <file> mentions our capture script, else "missing".
hook_state() { if [ -f "$1" ] && grep -q 'capture_session\.sh' "$1" 2>/dev/null; then echo present; else echo missing; fi; }
report() { # report <tool> <cli> <state> <where> [note]
	if ! command -v "$2" >/dev/null 2>&1; then printf '  -     %-8s %s not on PATH\n' "$1" "$2"
	elif [ "$3" = present ]; then printf '  ok    %-8s hook in %s%s\n' "$1" "$4" "${5:+ ($5)}"
	else printf '  WARN  %-8s no hook in %s: run scripts/install_hooks.sh%s\n' "$1" "$4" "${5:+ ($5)}"; fi
}

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
	# Drop any prior capture_session.sh entry (even one at a different path — e.g. the plugin
	# moved between ~/.tmux/plugins and ~/.config/tmux/plugins), then add exactly one. This
	# keeps re-installs from a new location idempotent instead of stacking duplicate hooks.
	jq --arg cmd "$cmd" '
		.hooks = (.hooks // {})
		| .hooks.UserPromptSubmit = ([
			.hooks.UserPromptSubmit[]?
			| select( any(.hooks[]?; (.command // "") | contains("capture_session.sh")) | not )
		  ] + [ { "hooks": [ { "type": "command", "command": $cmd } ] } ])
	' "$settings" > "$tmp" && mv "$tmp" "$settings"
	echo "✓ Claude UserPromptSubmit hook → $settings"
}

check_claude() {
	local settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
	report claude claude "$(hook_state "$settings")" "$settings"
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
	# Same self-healing dedup as Claude: drop any prior capture_session.sh entry (any path)
	# then add exactly one, so re-installing from a moved location never stacks duplicates.
	jq --arg cmd "$cmd" '
		.hooks = (.hooks // {})
		| .hooks.userPromptSubmit = ([
			.hooks.userPromptSubmit[]?
			| select( (.command // "") | contains("capture_session.sh") | not )
		  ] + [ { "command": $cmd } ])
	' "$file" > "$tmp" && mv "$tmp" "$file"
	echo "✓ Kiro userPromptSubmit hook → $file (default agent: $def)"
}

check_kiro() {
	local f state=missing
	for f in "$HOME"/.kiro/agents/*.json; do [ "$(hook_state "$f")" = present ] && state=present; done
	report kiro kiro-cli "$state" "$HOME/.kiro/agents/<default agent>.json"
}

for tool in $(air_tools); do
	if declare -F "${mode}_$tool" >/dev/null; then "${mode}_$tool"
	else echo "• $tool: no ${mode}_$tool in install_hooks.sh — skipping"; fi
done
[ "$mode" = check ] && exit 0
echo
echo "Done. Newly started/resumed AI sessions are captured automatically;"
echo "existing ones get picked up on their next prompt."
