#!/usr/bin/env bash
# Round-trip test for rewrite_save.sh against a real tmux server (no resurrect needed).
#
# Spins up a private, config-less tmux server, creates real panes whose process is named
# after each tool (copies of `sleep` renamed claude / kiro-cli), stamps the @ai_* pane
# options that capture_session.sh would set, writes a synthetic resurrect save file for the
# live layout, runs rewrite_save.sh (routed via a tmux PATH-shim) and asserts field 11:
#   - a live marker (its @ai_pid still running in the pane) is resumed
#   - a marker whose CLI has exited is ignored: the pane relaunches cold
#   - the relaunch is built from the CLI's own argv (the positional "600" is dropped)
#   - a stale marker on a pane no longer running the tool is ignored; non-AI panes untouched
# and the plumbing: the file argument (post-save-layout) vs. the file `last` points to
# (post-save-all / manual run), file mode preserved, --explain leaves the file alone.

set -u
unset TMUX TMUX_PANE
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMUX_BIN="$(command -v tmux)"
SOCK="air_test_$$"
WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
RDIR="$WORK/resurrect"; mkdir -p "$RDIR"
SHIM="$WORK/bin"; mkdir -p "$SHIM"
FAKE="$WORK/fake"; mkdir -p "$FAKE"

cleanup() {
  "$TMUX_BIN" -L "$SOCK" kill-server 2>/dev/null || true
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK"; rm -rf "$WORK"
}
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

T() { "$TMUX_BIN" -L "$SOCK" "$@"; }
T -f /dev/null new-session -d -s airtest -x 220 -y 60 -c "$WORK"
SHELL_P="$(T list-panes -t airtest -F '#{pane_id}' | head -1)"
PA="$(T split-window -t airtest -c "$WORK" -P -F '#{pane_id}' "$FAKE/claude 600")"   # live marker
PC="$(T split-window -t airtest -c "$WORK" -P -F '#{pane_id}' "$FAKE/claude 600")"   # marker of an exited CLI
PB="$(T split-window -t airtest -c "$WORK" -P -F '#{pane_id}' "$FAKE/kiro-cli 600")" # kiro
T select-layout -t airtest tiled >/dev/null

for i in $(seq 1 50); do   # wait until tmux reports the renamed foreground processes
  [ "$(T display -p -t "$PB" '#{pane_current_command}')" = "kiro-cli" ] && break
  sleep 0.1
done
d() { T display -p -t "$1" "$2"; }
cli_pid() { pgrep -P "$(d "$1" '#{pane_pid}')" 2>/dev/null | head -1 || true; }
pid_of() { local p; p="$(d "$1" '#{pane_pid}')"; [ "$(ps -o comm= -p "$p" | sed 's#.*/##')" = "$2" ] && echo "$p" || cli_pid "$1"; }
mark() { T set -p -t "$1" @ai_tool "$2" \; set -p -t "$1" @ai_session_id "$3" \; set -p -t "$1" @ai_pid "$4"; }

mark "$SHELL_P" claude stale-id 1                          # no claude in this pane any more
mark "$PA" claude cafe-claude "$(pid_of "$PA" claude)"
mark "$PC" claude dead-beef 999999                         # the CLI that stamped it is gone
mark "$PB" kiro beef-kiro "$(pid_of "$PB" kiro-cli)"
T set -g @resurrect-dir "$RDIR"

# A resurrect save file (11 tab fields/pane) for the live layout.
mkline() { local IFS=$'\t'; printf '%s\n' "$*"; }
saved() { mkline pane airtest 0 1 ':*' "$(d "$1" '#{pane_index}')" title ":$(d "$1" '#{pane_current_path}')" 0 "$(d "$1" '#{pane_current_command}')" "$2"; }
SAVE="$RDIR/tmux_resurrect_test.txt"
{
  saved "$PA" ":$FAKE/claude 600"
  saved "$PC" ":$FAKE/claude 600"
  saved "$PB" ":$FAKE/kiro-cli 600"
  saved "$SHELL_P" ':vim'
  mkline pane airtest 0 1 ':' 9 title ":$WORK" 0 vim ':vim'
} > "$SAVE"
chmod 644 "$SAVE"
cp "$SAVE" "$SAVE.orig"

field11() { awk -F'\t' -v p="$(d "$2" '#{pane_index}')" '$1=="pane" && $6==p {print $11}' "$1"; }
fail=0
check() {
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n       got:  %s\n       want: %s\n' "$1" "$2" "$3"; fail=1; fi
}

# --explain first: it must not modify anything
PATH="$SHIM:$PATH" bash "$ROOT/scripts/rewrite_save.sh" --explain "$SAVE" > "$WORK/explain.txt"
cmp -s "$SAVE" "$SAVE.orig"; check "--explain leaves the file alone" "$?" "0"
grep -q 'session cafe-claude from prompt-hook marker' "$WORK/explain.txt"; check "--explain reports the decision" "$?" "0"

# post-save-layout style: resurrect passes the new file; `last` doesn't exist yet
PATH="$SHIM:$PATH" bash "$ROOT/scripts/rewrite_save.sh" "$SAVE"
check "live marker resumed, relaunch from the CLI's argv" "$(field11 "$SAVE" "$PA")" \
  ":$FAKE/claude --resume cafe-claude || $FAKE/claude"
check "marker of an exited CLI ignored: cold relaunch" "$(field11 "$SAVE" "$PC")" ":$FAKE/claude"
check "kiro resumed (non-chat argv -> configured launcher)" "$(field11 "$SAVE" "$PB")" \
  ":kiro-cli chat --resume-id beef-kiro || kiro-cli chat"
check "stale marker on a pane without the tool ignored" "$(field11 "$SAVE" "$SHELL_P")" ":vim"
check "non-AI pane untouched" "$(awk -F'\t' '$6==9 {print $11}' "$SAVE")" ":vim"
check "file mode preserved" "$(stat -f '%Lp' "$SAVE" 2>/dev/null || stat -c '%a' "$SAVE")" "644"

# legacy post-save-all style: no argument -> the file `last` points to
cp "$SAVE.orig" "$RDIR/tmux_resurrect_other.txt"
ln -sf tmux_resurrect_other.txt "$RDIR/last"
PATH="$SHIM:$PATH" bash "$ROOT/scripts/rewrite_save.sh"
check "no argument: rewrites the file last points to" "$(field11 "$RDIR/tmux_resurrect_other.txt" "$PA")" \
  ":$FAKE/claude --resume cafe-claude || $FAKE/claude"
[ -L "$RDIR/last" ]; check "  ... and last is still a symlink" "$?" "0"

if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAILURES"; exit 1; fi
