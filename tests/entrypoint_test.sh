#!/usr/bin/env bash
# Entrypoint test: sourcing ai_sessions_restore.tmux must wire resurrect correctly —
#   - put our rewriter in @resurrect-hook-post-save-layout (runs before `last` is repointed),
#     migrating it out of @resurrect-hook-post-save-all where older versions put it, and
#     keeping any hook commands of the user's own in both options
#   - fall back to post-save-all only for a resurrect too old to have post-save-layout
#   - add ~<tool> matches to @resurrect-processes (so resurrect actually replays the
#     resume commands on restore; without this the layout restores but panes are bare)
#   - stay idempotent across reloads
# Runs against private, config-less tmux servers via a tmux PATH-shim.

set -u
unset TMUX TMUX_PANE
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMUX_BIN="$(command -v tmux)"
SOCK="air_ep_$$"
WORK="$(mktemp -d)"
SHIM="$WORK/bin"; mkdir -p "$SHIM"
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

T() { "$TMUX_BIN" -L "$SOCK" "$@"; }
fresh_server() {
  T kill-server 2>/dev/null
  T -f /dev/null new-session -d -s t -x 80 -y 24
  T set -g @ai-restore-auto-install off   # don't touch real tool configs
}
load() { PATH="$SHIM:$PATH" bash "$ROOT/ai_sessions_restore.tmux"; }

fail=0
contains() { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
assert() { # assert <label> <condition-result 0/1>
  if [ "$2" -eq 0 ]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fail=1; fi
}
count() { printf '%s\n' "$2" | grep -o "$1" | wc -l | tr -d ' '; }
HOOK="bash '$ROOT/scripts/rewrite_save.sh'"

# 1. clean install, loaded twice
fresh_server; load; load
procs="$(T show -gv @resurrect-processes 2>/dev/null)"
layout="$(T show -gv @resurrect-hook-post-save-layout 2>/dev/null)"
all="$(T show -gv @resurrect-hook-post-save-all 2>/dev/null)"
contains '~claude'   "$procs"; assert "@resurrect-processes has ~claude"   $?
contains '~kiro-cli' "$procs"; assert "@resurrect-processes has ~kiro-cli" $?
[ "$layout" = "$HOOK" ]; assert "post-save-layout hook wired" $?
[ -z "$all" ]; assert "nothing added to post-save-all" $?
[ "$(count '~claude' "$procs")" = 1 ]; assert "no duplicate ~claude after 2 loads" $?

# 2. upgrade from a version that used post-save-all (from another plugin path), with the
#    user's own hooks around it in both options
fresh_server
T set -g @resurrect-hook-post-save-all "echo before ; bash '/old/plugins/tmux-ai-sessions-restore/scripts/rewrite_save.sh' ; echo after"
T set -g @resurrect-hook-post-save-layout "echo mine"
load; load
layout="$(T show -gv @resurrect-hook-post-save-layout 2>/dev/null)"
all="$(T show -gv @resurrect-hook-post-save-all 2>/dev/null)"
[ "$all" = "echo before ; echo after" ]; assert "migrated out of post-save-all, user hooks kept (got: $all)" $?
[ "$layout" = "echo mine ; $HOOK" ]; assert "appended to the user's post-save-layout once (got: $layout)" $?

# 3. only our old hook in post-save-all: the option is unset, not left empty
fresh_server
T set -g @resurrect-hook-post-save-all "bash '/old/scripts/rewrite_save.sh'"
load
T show -g @resurrect-hook-post-save-all >/dev/null 2>&1; [ $? -ne 0 ] || [ -z "$(T show -gv @resurrect-hook-post-save-all 2>/dev/null)" ]
assert "post-save-all cleared when it only held our hook" $?

# 4. a resurrect without post-save-layout gets post-save-all
fresh_server
printf '#!/usr/bin/env bash\nexecute_hook "post-save-all"\n' > "$WORK/old_save.sh"
T set -g @resurrect-save-script-path "$WORK/old_save.sh"
load
[ "$(T show -gv @resurrect-hook-post-save-all 2>/dev/null)" = "$HOOK" ]; assert "old resurrect: wired to post-save-all" $?
[ -z "$(T show -gv @resurrect-hook-post-save-layout 2>/dev/null)" ]; assert "old resurrect: post-save-layout left empty" $?

if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAILURES"; exit 1; fi
