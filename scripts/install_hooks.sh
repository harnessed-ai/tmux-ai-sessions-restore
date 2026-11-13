#!/usr/bin/env bash
# install_hooks.sh [--check] [tool...] — register the per-tool prompt hooks that let
# tmux-ai-sessions-restore learn which conversation each pane holds.
#
# We hook the prompt event (Claude UserPromptSubmit / Kiro userPromptSubmit / ...) rather
# than session start, so a pane is only marked once its session actually has a transcript.
#
# Claude Code and Kiro report through the shared harnessed-ai hook (scripts/agent-hook.sh,
# an identical copy of which other tmux plugins ship too): it records @agent_session_id on
# the first prompt, and rewrite_save.sh reads that. With several such plugins installed,
# each agent event runs one hook instead of one per plugin. The other CLIs keep our own
# capture_session.sh.
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
[ "${1:-}" = "--check" ] && { mode=check; shift; }
tools="$*"   # optional tool names (default: every tool in tools.tsv)
[ "$mode" = check ] || command -v jq >/dev/null 2>&1 || { echo "✗ jq is required (brew install jq)"; exit 1; }

# hook_state <file> [script]: "present" if <file> mentions the hook script (default: our
# capture script), else "missing".
hook_state() { if [ -f "$1" ] && grep -qF "${2:-capture_session.sh}" "$1" 2>/dev/null; then echo present; else echo missing; fi; }

# drop_capture <json file>: remove our capture_session.sh entries (a CLI that now reports
# through the shared agent hook), from either hooks layout, keeping everything else.
drop_capture() {
	[ -f "$1" ] || return 0
	local tmp; tmp="$(mktemp)"
	jq '
		if (.hooks? | type) == "object" then
			.hooks |= with_entries(.value |= (
				map(if (type == "object" and (.hooks | type) == "array")
				    then .hooks |= map(select((.command // "") | contains("capture_session.sh") | not))
				    else . end)
				| map(select(
					if (type == "object" and (.hooks | type) == "array") then (.hooks | length) > 0
					else ((.command? // "") | contains("capture_session.sh") | not) end))))
		else . end
	' "$1" > "$tmp" && { cmp -s "$1" "$tmp" && rm -f "$tmp" || mv "$tmp" "$1"; }
}

# shared_hook <tool>: register the shared agent hook for one CLI (claude | kiro).
shared_hook() {
	AGENT_HOOK_TOOLS="$1" bash "$HERE/install-hooks.sh" | sed 's/^/  /'
}
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
	drop_capture "$settings"
	shared_hook claude
	echo "✓ Claude reports through the shared agent hook → $settings"
}

# add_hook_group <json file> <event> <command>: the Claude-style hooks layout that Codex and
# Gemini share — .hooks[<event>] is a list of { hooks: [ { type: "command", command } ] }.
# Drops any prior capture_session.sh entry (even one at a different path — e.g. the plugin
# moved between ~/.tmux/plugins and ~/.config/tmux/plugins), then adds exactly one. This
# keeps re-installs from a new location idempotent instead of stacking duplicate hooks.
add_hook_group() {
	local file="$1" event="$2" cmd="$3" tmp
	mkdir -p "$(dirname "$file")"
	[ -f "$file" ] || echo '{}' > "$file"
	tmp="$(mktemp)"
	jq --arg ev "$event" --arg cmd "$cmd" '
		.hooks = (.hooks // {})
		| .hooks[$ev] = ([
			.hooks[$ev][]?
			| select( any(.hooks[]?; (.command // "") | contains("capture_session.sh")) | not )
		  ] + [ { "hooks": [ { "type": "command", "command": $cmd } ] } ])
	' "$file" > "$tmp" && mv "$tmp" "$file"
}

check_claude() {
	local settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
	report claude claude "$(hook_state "$settings" agent-hook.sh)" "$settings" "shared agent hook"
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

	drop_capture "$file"
	shared_hook kiro
	echo "✓ Kiro reports through the shared agent hook → $file (default agent: $def)"
}

check_kiro() {
	local f state=missing
	for f in "$HOME"/.kiro/agents/*.json; do [ "$(hook_state "$f" agent-hook.sh)" = present ] && state=present; done
	report kiro kiro-cli "$state" "$HOME/.kiro/agents/<default agent>.json" "shared agent hook"
}

# Codex reads ~/.codex/hooks.json (or $CODEX_HOME/hooks.json). It runs a new or changed hook
# only after you trust it once in its /hooks screen, and skips it (with a startup warning)
# until then — so say so loudly.
codex_hooks_file() { printf '%s/hooks.json' "${CODEX_HOME:-$HOME/.codex}"; }

install_codex() {
	if ! command -v codex >/dev/null 2>&1; then
		echo "• codex not found — skipping Codex hook"
		return
	fi
	local file; file="$(codex_hooks_file)"
	add_hook_group "$file" UserPromptSubmit "bash \"$CAP\" codex"
	echo "✓ Codex UserPromptSubmit hook → $file"
	echo "  ! Codex skips new hooks until you trust them: run codex, open /hooks, and approve it"
	echo "    (again whenever the plugin moves to a different path)."
}

check_codex() {
	report codex codex "$(hook_state "$(codex_hooks_file)")" "$(codex_hooks_file)" "Codex runs it only once trusted in /hooks"
}

# Gemini reads ~/.gemini/settings.json (the home dir is $GEMINI_CLI_HOME when set). Its prompt
# event is BeforeAgent, and it parses a hook's stdout as JSON, so the command ends with `{}`.
gemini_settings_file() { printf '%s/.gemini/settings.json' "${GEMINI_CLI_HOME:-$HOME}"; }

install_gemini() {
	if ! command -v gemini >/dev/null 2>&1; then
		echo "• gemini not found — skipping Gemini hook"
		return
	fi
	local file; file="$(gemini_settings_file)"
	add_hook_group "$file" BeforeAgent "bash \"$CAP\" gemini; echo '{}'"
	echo "✓ Gemini BeforeAgent hook → $file"
}

check_gemini() {
	local file; file="$(gemini_settings_file)"
	if command -v gemini >/dev/null 2>&1 && [ -f "$file" ] &&
		[ "$(jq '.hooksConfig.enabled == false' "$file" 2>/dev/null)" = true ]; then
		printf '  WARN  %-8s hooksConfig.enabled is false in %s: Gemini runs no hooks\n' gemini "$file"
		return
	fi
	report gemini gemini "$(hook_state "$file")" "$file"
}

# OpenCode loads plugin files from <config dir>/plugins/ (OPENCODE_CONFIG_DIR, when set, is
# an extra config dir it also loads).
opencode_plugin_file() {
	printf '%s/plugins/tmux-ai-sessions-restore.js' "${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
}

# OpenCode has no shell hooks: install a plugin (scripts/opencode_plugin.js, with the path of
# this checkout's capture_session.sh filled in) that runs capture_session.sh on each prompt.
install_opencode() {
	if ! command -v opencode >/dev/null 2>&1; then
		echo "• opencode not found — skipping OpenCode plugin"
		return
	fi
	local file cap tmp
	file="$(opencode_plugin_file)"
	cap="$(jq -rn --arg p "$CAP" '$p | tojson | .[1:-1]')"   # JS-string-escaped path
	mkdir -p "$(dirname "$file")"
	tmp="$(mktemp)"
	CAP_ESC="$cap" awk '{ i = index($0, "__CAPTURE__"); if (i) $0 = substr($0, 1, i - 1) ENVIRON["CAP_ESC"] substr($0, i + 11); print }' \
		"$HERE/opencode_plugin.js" > "$tmp" && mv "$tmp" "$file"
	echo "✓ OpenCode capture plugin → $file"
}

check_opencode() {
	local file; file="$(opencode_plugin_file)"
	report opencode opencode "$(hook_state "$file")" "$file"
}

for tool in ${tools:-$(air_tools)}; do
	if declare -F "${mode}_$tool" >/dev/null; then "${mode}_$tool"
	else echo "• $tool: no ${mode}_$tool in install_hooks.sh — skipping"; fi
done
[ "$mode" = check ] && exit 0
echo
echo "Done. Newly started/resumed AI sessions are captured automatically;"
echo "existing ones get picked up on their next prompt."
