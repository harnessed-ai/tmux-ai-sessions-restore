#!/usr/bin/env bash
# Round-trip test for rewrite_save.sh.
#
# Spins up a private, config-less tmux server, creates real panes whose *foreground
# process* is named after each tool (copies of `sleep` renamed claude / kiro-cli), stamps
# the @ai_* pane-options that capture_session.sh would set, writes a synthetic resurrect
# save file, runs rewrite_save.sh (routed via a tmux PATH-shim), and asserts field 11:
#   - existing launch flags preserved (resume flag appended)
#   - cold-launch fallback appended
#   - a pane saved with a non-tool command falls back to the configured launcher
#   - STALE marker on a pane no longer running the tool is skipped (R1 guard)
#   - non-AI panes untouched

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMUX_BIN="$(command -v tmux)"
SOCK="air_test_$$"
WORK="$(mktemp -d)"
RDIR="$WORK/resurrect"; mkdir -p "$RDIR"
SHIM="$WORK/bin"; mkdir -p "$SHIM"
FAKE="$WORK/fake"; mkdir -p "$FAKE"

cleanup() { "$TMUX_BIN" -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

cat > "$SHIM/tmux" <<EOF
#!/usr/bin/env bash
exec "$TMUX_BIN" -L "$SOCK" "\$@"
EOF
chmod +x "$SHIM/tmux"

# Real binaries whose process name (comm) is the tool name, so #{pane_current_command} matches.
# On Apple Silicon a plain copy breaks the code signature (SIGKILL on exec), so ad-hoc re-sign.
cp /bin/sleep "$FAKE/claude"
cp /bin/sleep "$FAKE/kiro-cli"
if command -v codesign >/dev/null 2>&1; then
  codesign --force -s - "$FAKE/claude"   2>/dev/null || true
  codesign --force -s - "$FAKE/kiro-cli" 2>/dev/null || true
fi

# Pristine server. First pane = a plain shell (used for the stale-marker case).
"$TMUX_BIN" -L "$SOCK" -f /dev/null new-session -d -s airtest -x 220 -y 60
SHELL_P="$("$TMUX_BIN" -L "$SOCK" list-panes -t airtest -F '#{pane_id}' | head -1)"
PA="$("$TMUX_BIN" -L "$SOCK" split-window -t airtest -P -F '#{pane_id}' "$FAKE/claude 600")"     # claude, flags
PD="$("$TMUX_BIN" -L "$SOCK" split-window -t airtest -P -F '#{pane_id}' "$FAKE/claude 600")"     # claude, base fallback
PB="$("$TMUX_BIN" -L "$SOCK" split-window -t airtest -P -F '#{pane_id}' "$FAKE/kiro-cli 600")"   # kiro

# wait until tmux reports the renamed foreground processes
for i in $(seq 1 20); do
  [ "$("$TMUX_BIN" -L "$SOCK" display -p -t "$PA" '#{pane_current_command}')" = "claude" ] && break
  sleep 0.2
done

idx() { "$TMUX_BIN" -L "$SOCK" display -p -t "$1" "$2"; }

# Stamp markers (capture_session.sh would do this on first prompt).
"$TMUX_BIN" -L "$SOCK" set -p -t "$SHELL_P" @ai_tool claude && "$TMUX_BIN" -L "$SOCK" set -p -t "$SHELL_P" @ai_session_id stale-id
"$TMUX_BIN" -L "$SOCK" set -p -t "$PA" @ai_tool claude && "$TMUX_BIN" -L "$SOCK" set -p -t "$PA" @ai_session_id cafe-claude
"$TMUX_BIN" -L "$SOCK" set -p -t "$PD" @ai_tool claude && "$TMUX_BIN" -L "$SOCK" set -p -t "$PD" @ai_session_id dead-beef
"$TMUX_BIN" -L "$SOCK" set -p -t "$PB" @ai_tool kiro   && "$TMUX_BIN" -L "$SOCK" set -p -t "$PB" @ai_session_id beef-kiro
"$TMUX_BIN" -L "$SOCK" set -g @resurrect-dir "$RDIR"

# Build a resurrect save file (11 tab fields/pane) matching the live indices.
mkline() { local IFS=$'\t'; printf '%s\n' "$*"; }
SAVE="$RDIR/tmux_resurrect_test.txt"
{
  mkline pane airtest 0 1 ':*' "$(idx "$PA" '#{pane_index}')" bash ":$HOME" 1 claude   ':claude --dangerously-skip-permissions'
  mkline pane airtest 0 1 ':'  "$(idx "$PB" '#{pane_index}')" bash ":$HOME" 0 kiro-cli ':kiro-cli chat'
  mkline pane airtest 0 1 ':'  "$(idx "$PD" '#{pane_index}')" bash ":$HOME" 0 claude   ':/bin/zsh --login'
  mkline pane airtest 0 1 ':'  "$(idx "$SHELL_P" '#{pane_index}')" bash ":$HOME" 0 zsh ':vim'
  mkline pane airtest 0 1 ':'  9 bash ":$HOME" 0 vim ':vim'
} > "$SAVE"
ln -sf "$(basename "$SAVE")" "$RDIR/last"

PATH="$SHIM:$PATH" bash "$ROOT/scripts/rewrite_save.sh"

field11() { awk -F'\t' -v p="$1" '$1=="pane"&&$2=="airtest"&&$3=="0"&&$6==p{print $11}' "$RDIR/last"; }
fail=0
check() {
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n       got:  %s\n       want: %s\n' "$1" "$2" "$3"; fail=1; fi
}

check "claude flags preserved" "$(field11 "$(idx "$PA" '#{pane_index}')")" \
  ":claude --dangerously-skip-permissions --resume cafe-claude || claude --dangerously-skip-permissions"
check "kiro resume appended"   "$(field11 "$(idx "$PB" '#{pane_index}')")" \
  ":kiro-cli chat --resume-id beef-kiro || kiro-cli chat"
check "non-tool cmd uses base" "$(field11 "$(idx "$PD" '#{pane_index}')")" \
  ":claude --resume dead-beef || claude"
check "stale marker skipped (R1)" "$(field11 "$(idx "$SHELL_P" '#{pane_index}')")" ":vim"
check "non-AI pane untouched"  "$(field11 9)" ":vim"

if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAILURES"; exit 1; fi
