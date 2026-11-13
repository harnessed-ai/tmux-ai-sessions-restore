#!/usr/bin/env bash
# Claude Code / Kiro on the shared agent hook (scripts/agent-hook.sh), end to end:
#   - install_hooks.sh replaces our old capture_session.sh entries with the shared hook
#     (one entry per event), leaving your own hooks and other CLIs' capture hooks alone;
#   - a prompt reported by agent-hook.sh is what rewrite_save.sh resumes;
#   - uninstall_hooks.sh hands the hook over to another loaded plugin, or removes it.
# Runs on a private tmux server with a scratch $HOME and Claude config: never touches yours.
set -u
unset TMUX TMUX_PANE
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMUX_BIN="$(command -v tmux)"
SOCK="air_agent_$$"
WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
export HOME="$WORK/home" CLAUDE_CONFIG_DIR="$WORK/home/.claude" CODEX_HOME="$WORK/home/.codex"
mkdir -p "$CLAUDE_CONFIG_DIR" "$CODEX_HOME"
case "$HOME/$CLAUDE_CONFIG_DIR/$CODEX_HOME" in "$WORK"/*) ;; *) echo "refusing: not sandboxed"; exit 1 ;; esac
SHIM="$WORK/bin"; FAKE="$WORK/fake"; mkdir -p "$SHIM" "$FAKE"
cleanup() { "$TMUX_BIN" -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

T() { "$TMUX_BIN" -L "$SOCK" "$@"; }
cat > "$SHIM/tmux" <<EOF
#!/usr/bin/env bash
exec "$TMUX_BIN" -L "$SOCK" "\$@"
EOF
chmod +x "$SHIM/tmux"
cp /bin/sleep "$FAKE/claude"
command -v codesign >/dev/null 2>&1 && codesign --force -s - "$FAKE/claude" 2>/dev/null

fail=0
check() {
	if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
	else printf '  FAIL %s\n       got:  %s\n       want: %s\n' "$1" "$2" "$3"; fail=1; fi
}
cfg="$CLAUDE_CONFIG_DIR/settings.json"
count() { jq "[.. | strings | select(contains(\"$2\"))] | length" "$1"; }

echo "install (Claude moves from capture_session.sh to the shared hook):"
cat > "$cfg" <<JSON
{"hooks": {
  "UserPromptSubmit": [{"hooks":[{"type":"command","command":"bash \"/old/plugin/scripts/capture_session.sh\" claude"}]},
                       {"hooks":[{"type":"command","command":"my-own-hook"}]}]
}}
JSON
echo '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"bash \"/x/capture_session.sh\" codex"}]}]}}' > "$CODEX_HOME/hooks.json"
cp "$CODEX_HOME/hooks.json" "$WORK/codex.orig"
PATH="$SHIM:$PATH" bash "$ROOT/scripts/install_hooks.sh" claude >/dev/null
check "old capture entry removed" "$(count "$cfg" capture_session.sh)" "0"
check "shared hook registered once per event (8 events)" "$(count "$cfg" agent-hook.sh)" "8"
check "your own hook kept" "$(count "$cfg" my-own-hook)" "1"
cmp -s "$CODEX_HOME/hooks.json" "$WORK/codex.orig"; check "Codex keeps its capture hook" "$?" "0"
before="$(cat "$cfg")"
PATH="$SHIM:$PATH" bash "$ROOT/scripts/install_hooks.sh" claude >/dev/null
check "re-install leaves an up-to-date config untouched" "$(cat "$cfg")" "$before"

echo "a prompt reported by the shared hook is what gets resumed:"
T -f /dev/null new-session -d -s s -x 200 -y 50 -c "$WORK" "$FAKE/claude 600"
P="$(T display -p -t s '#{pane_id}')"
for i in $(seq 1 50); do [ "$(T display -p -t "$P" '#{pane_current_command}')" = claude ] && break; sleep 0.1; done
TMUXSOCK="$(T display -p '#{socket_path}')"
# Fire the hook from the tmux server (run-shell), as Claude would from the pane, so its
# process ancestry has no unrelated `claude` in it (e.g. a Claude Code running this test).
fire() { # fire <event> <json>
	printf '%s' "$2" > "$WORK/payload.json"
	T run-shell "TMUX_PANE='$P' bash '$ROOT/scripts/agent-hook.sh' claude $1 < '$WORK/payload.json'"
}
fire SessionStart '{"session_id":"11111111-2222-3333-4444-555555555555"}'
check "fresh session: no session id recorded yet" "$(T display -p -t "$P" '#{@agent_session_id}')" ""
fire UserPromptSubmit '{"session_id":"11111111-2222-3333-4444-555555555555","prompt":"hi"}'
check "first prompt: session id recorded" "$(T display -p -t "$P" '#{@agent_session_id}')" \
	"11111111-2222-3333-4444-555555555555"
mkline() { local IFS=$'\t'; printf '%s\n' "$*"; }
SAVE="$WORK/save.txt"
mkline pane s 0 1 ':*' "$(T display -p -t "$P" '#{pane_index}')" title ":$WORK" 1 claude ":$FAKE/claude 600" > "$SAVE"
PATH="$SHIM:$PATH" bash "$ROOT/scripts/rewrite_save.sh" "$SAVE"
check "save file resumes it" "$(awk -F'\t' '{print $11}' "$SAVE")" \
	":claude --resume 11111111-2222-3333-4444-555555555555"

echo "uninstall:"
mkdir -p "$WORK/sibling"; cp "$ROOT/scripts/agent-hook.sh" "$WORK/sibling/agent-hook.sh"
T set -g @agent-hook-provider-sibling "$WORK/sibling/agent-hook.sh"
TMUX="$TMUXSOCK,0,0" PATH="$SHIM:$PATH" bash "$ROOT/scripts/uninstall_hooks.sh" claude >/dev/null
check "another plugin loaded: hook handed over to its copy" \
	"$(count "$cfg" "$WORK/sibling/agent-hook.sh")" "8"
T set -gu @agent-hook-provider-sibling
TMUX="$TMUXSOCK,0,0" PATH="$SHIM:$PATH" bash "$ROOT/scripts/uninstall_hooks.sh" claude >/dev/null
check "no other plugin: hook removed" "$(count "$cfg" agent-hook.sh)" "0"
check "your own hook still there" "$(count "$cfg" my-own-hook)" "1"

if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAILURES"; exit 1; fi
