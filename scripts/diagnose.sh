#!/usr/bin/env bash
# diagnose.sh — read-only health check of tmux-ai-sessions-restore on the running tmux server.
#
# Changes nothing: it only reads tmux options, the process table and the resurrect save dir.
# Run it from inside tmux:
#   bash ~/.config/tmux/plugins/tmux-ai-sessions-restore/scripts/diagnose.sh
#
# It answers: is the save hook wired, is continuum actually auto-saving in *this* server,
# how old is the save a restore would use, and — pane by pane — what that save would bring
# back compared with what is running now.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
. "$HERE/helpers.sh"

ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }
info() { printf '        %s\n' "$*"; }
ago()  {
    local s="$1"
    if [ "$s" -lt 120 ]; then echo "${s}s ago"; elif [ "$s" -lt 7200 ]; then echo "$((s / 60))m ago"
    elif [ "$s" -lt 172800 ]; then echo "$((s / 3600))h ago"; else echo "$((s / 86400)) days ago"; fi
}
mtime() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null; }

command -v tmux >/dev/null 2>&1 || { echo "tmux is not on PATH"; exit 1; }
tmux list-sessions >/dev/null 2>&1 || { echo "no tmux server reachable — run this inside tmux"; exit 1; }
now="$(date +%s)"

echo "== wiring   ($(tmux -V); plugin at ${HERE%/scripts})"
layout="$(tmux show-option -gqv '@resurrect-hook-post-save-layout')"
all="$(tmux show-option -gqv '@resurrect-hook-post-save-all')"
case "$layout" in
    *"$HERE/rewrite_save.sh"*) ok "save hook: post-save-layout runs this copy of rewrite_save.sh" ;;
    *rewrite_save.sh*) warn "post-save-layout runs a different copy: $layout" ;;
    *)  case "$all" in
            *rewrite_save.sh*) warn "save hook is post-save-all (older wiring): reload the tmux config to move it to post-save-layout" ;;
            *) warn "no resurrect save hook runs rewrite_save.sh — is the plugin loaded (after tmux-resurrect)?" ;;
        esac ;;
esac
save_script="$(tmux show-option -gqv '@resurrect-save-script-path')"
if [ -n "$save_script" ]; then ok "tmux-resurrect loaded ($save_script)"; else warn "tmux-resurrect doesn't look loaded (@resurrect-save-script-path unset)"; fi
procs="$(tmux show-option -gqv '@resurrect-processes')"
case "$procs" in *'~claude'*) ok "@resurrect-processes: $procs" ;; *) warn "@resurrect-processes lacks ~claude — restore would leave AI panes as bare shells ($procs)" ;; esac

echo "== auto-save (tmux-continuum)"
status_opts="$(tmux show-option -gqv status-right) $(tmux show-option -gqv status-left)"
case "$status_opts" in
    *continuum_save.sh*)
        ok "auto-save is on, every $(air_tmux_get '@continuum-save-interval' 15) min"
        [ "$(tmux show-option -gqv status)" = off ] &&
            warn "…but the status line is off, and continuum's save only runs when the status line is drawn"
        ;;
    *)
        warn "auto-save is NOT running in this tmux server."
        info "continuum only enables it if it sees no other tmux server when this one starts;"
        info "several terminals starting tmux at once (or any tmux client running then) count."
        info "Until you save by hand (prefix + Ctrl-s), a restore uses whatever an earlier server saved."
        ;;
esac
ts="$(tmux show-option -gqv '@continuum-save-last-timestamp')"
[ -n "$ts" ] && info "continuum's last save: $(ago $((now - ts)))"

echo "== save files"
dir="$(air_resurrect_dir)"
last="$dir/last"
if [ -e "$last" ]; then
    target="$(readlink "$last" 2>/dev/null || echo "$last")"
    m="$(mtime "$last")"
    ok "last -> $target (written $(ago $((now - m))))"
    info "$(ls "$dir" | grep -c '^tmux_resurrect_.*\.txt$') save file(s) in $dir"
    info "(identical saves are not kept, so an old 'last' is fine if nothing changed since)"
else
    warn "no save yet: $last does not exist"
    exit 0
fi

echo "== panes: what a restore from 'last' brings back, and what a save now would write"
bash "$HERE/rewrite_save.sh" --explain
legacy="$(tmux list-panes -a -F '#{@ai_session_id}|#{@ai_pid}' | grep -c '^[^|][^|]*|$')"
[ "$legacy" -gt 0 ] && info "($legacy pane(s) carry a marker from before @ai_pid existed; their next prompt upgrades it)"
exit 0
