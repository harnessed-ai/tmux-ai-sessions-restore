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
export XDG_DATA_HOME="$WORK/home/.local/share" XDG_CONFIG_HOME="$WORK/home/.config"
unset AGENT_HOOK_HOME OPENCODE_CONFIG_DIR AGENT_HOOK_TOOLS
mkdir -p "$CLAUDE_CONFIG_DIR" "$CODEX_HOME"
case "$HOME/$CLAUDE_CONFIG_DIR/$CODEX_HOME/$XDG_DATA_HOME/$XDG_CONFIG_HOME" in "$WORK"/*) ;; *) echo "refusing: not sandboxed"; exit 1 ;; esac
SH="$XDG_DATA_HOME/harnessed-ai/agent-hook.sh"
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
check "  ... at the shared fixed path" "$(count "$cfg" "$SH")" "8"
check "your own hook kept" "$(count "$cfg" my-own-hook)" "1"
cmp -s "$CODEX_HOME/hooks.json" "$WORK/codex.orig"; check "Codex keeps its capture hook" "$?" "0"
echo "OpenCode moves from our capture plugin to the shared hook's plugin:"
printf '#!/bin/sh\nexit 0\n' > "$SHIM/opencode"; chmod +x "$SHIM/opencode"
OCD="$XDG_CONFIG_HOME/opencode/plugins"; mkdir -p "$OCD"
echo '// old: runs capture_session.sh' > "$OCD/tmux-ai-sessions-restore.js"
PATH="$SHIM:$PATH" bash "$ROOT/scripts/install_hooks.sh" opencode >/dev/null
[ ! -e "$OCD/tmux-ai-sessions-restore.js" ]; check "old capture plugin removed" "$?" "0"
grep -qF "$SH" "$OCD/harnessed-ai-agent-hook.js" 2>/dev/null; check "shared plugin installed, pointing at the fixed path" "$?" "0"
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

echo "Codex run by its shared server: our capture must not stamp the server's pane:"
cp /bin/bash "$FAKE/codex-server"; command -v codesign >/dev/null 2>&1 && codesign --force -s - "$FAKE/codex-server" 2>/dev/null
mkdir -p "$FAKE/srv"; ln -sf "$FAKE/codex-server" "$FAKE/srv/codex"
STALE="$(T new-window -d -P -F '#{pane_id}')"
printf '{"session_id":"thr_srv","cwd":"/x"}' > "$WORK/srv.json"
TMUX="$TMUXSOCK,0,0" TMUX_PANE="$STALE" "$FAKE/srv/codex" -c "bash '$ROOT/scripts/capture_session.sh' codex < '$WORK/srv.json'" app-server
check "stale pane not stamped" "$(T display -p -t "$STALE" '#{@ai_session_id}')" ""
printf '{"session_id":"thr_tui","cwd":"/x"}' > "$WORK/tui.json"
TMUX="$TMUXSOCK,0,0" TMUX_PANE="$STALE" "$FAKE/srv/codex" -c "bash '$ROOT/scripts/capture_session.sh' codex < '$WORK/tui.json'"
check "  ... while Codex in the pane itself (--no-daemon) still is" "$(T display -p -t "$STALE" '#{@ai_session_id}')" "thr_tui"

echo "uninstall:"
T set -g @agent-hook-provider-sibling x            # another plugin still using the hook
TMUX="$TMUXSOCK,0,0" PATH="$SHIM:$PATH" bash "$ROOT/scripts/uninstall_hooks.sh" claude opencode >/dev/null
check "another plugin still uses it: hook left in place" "$(count "$cfg" agent-hook.sh)" "8"
[ -f "$OCD/harnessed-ai-agent-hook.js" ]; check "  ... OpenCode plugin left in place" "$?" "0"
T set -gu @agent-hook-provider-sibling
TMUX="$TMUXSOCK,0,0" PATH="$SHIM:$PATH" bash "$ROOT/scripts/uninstall_hooks.sh" claude opencode >/dev/null
check "no other plugin: hook unregistered" "$(count "$cfg" agent-hook.sh)" "0"
[ ! -e "$OCD/harnessed-ai-agent-hook.js" ]; check "  ... OpenCode plugin removed" "$?" "0"
check "your own hook still there" "$(count "$cfg" my-own-hook)" "1"
# full uninstall as the last plugin: also Codex entries a sibling registered, and the shared copy
PATH="$SHIM:$PATH" bash "$ROOT/scripts/install_hooks.sh" claude >/dev/null
jq '.hooks.Stop = [{"hooks":[{"type":"command","command":"bash \"'"$SH"'\" codex Stop"}]}]' "$CODEX_HOME/hooks.json" > "$WORK/x" && mv "$WORK/x" "$CODEX_HOME/hooks.json"
TMUX="$TMUXSOCK,0,0" PATH="$SHIM:$PATH" bash "$ROOT/scripts/uninstall_hooks.sh" >/dev/null
check "full uninstall, last plugin: Claude hook gone" "$(count "$cfg" agent-hook.sh)" "0"
check "  ... Codex shared entries gone (our capture removed too)" "$(count "$CODEX_HOME/hooks.json" agent-hook.sh)" "0"
[ ! -e "$SH" ]; check "  ... shared copy removed" "$?" "0"

if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAILURES"; exit 1; fi
