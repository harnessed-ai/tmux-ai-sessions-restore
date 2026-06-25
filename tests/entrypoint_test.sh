#!/usr/bin/env bash
# Entrypoint test: sourcing ai_sessions_restore.tmux must wire resurrect correctly —
#   - append our rewriter to @resurrect-hook-post-save-all
#   - add ~<tool> matches to @resurrect-processes (so resurrect actually replays the
#     resume commands on restore; without this the layout restores but panes are bare)
#   - stay idempotent across reloads
# Runs against a private, config-less tmux server via a tmux PATH-shim.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMUX_BIN="$(command -v tmux)"
SOCK="air_ep_$$"
WORK="$(mktemp -d)"
SHIM="$WORK/bin"; mkdir -p "$SHIM"
cleanup() { "$TMUX_BIN" -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

cat > "$SHIM/tmux" <<EOF
#!/usr/bin/env bash
exec "$TMUX_BIN" -L "$SOCK" "\$@"
EOF
chmod +x "$SHIM/tmux"

"$TMUX_BIN" -L "$SOCK" -f /dev/null new-session -d -s t -x 80 -y 24
"$TMUX_BIN" -L "$SOCK" set -g @ai-restore-auto-install off   # don't touch real tool configs

# load the entrypoint twice (idempotency check)
PATH="$SHIM:$PATH" bash "$ROOT/ai_sessions_restore.tmux"
PATH="$SHIM:$PATH" bash "$ROOT/ai_sessions_restore.tmux"

procs="$("$TMUX_BIN" -L "$SOCK" show -gv @resurrect-processes 2>/dev/null)"
hook="$("$TMUX_BIN"  -L "$SOCK" show -gv @resurrect-hook-post-save-all 2>/dev/null)"

fail=0
contains() { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
assert() { # assert <label> <condition-result 0/1>
  if [ "$2" -eq 0 ]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fail=1; fi
}

contains '~claude'   "$procs"; assert "@resurrect-processes has ~claude"   $?
contains '~kiro-cli' "$procs"; assert "@resurrect-processes has ~kiro-cli" $?
contains 'rewrite_save.sh' "$hook"; assert "post-save hook wired"          $?

# idempotency: ~claude must appear exactly once after two loads
n="$(printf '%s\n' "$procs" | grep -o '~claude' | wc -l | tr -d ' ')"
[ "$n" = "1" ]; assert "no duplicate ~claude after 2 loads (got $n)" $?

echo "procs=[$procs]"
if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAILURES"; exit 1; fi
