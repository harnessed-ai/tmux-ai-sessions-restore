#!/usr/bin/env bash
# tmux-ai-sessions-restore — TPM entrypoint.
#
# Hooks into tmux-resurrect's save step so AI coding panes (claude / kiro-cli chat) come
# back *resumed* on restore. Layout / panes / cwd remain the job of resurrect+continuum.
#
# Load AFTER tmux-resurrect and BEFORE tmux-continuum (this must set @resurrect-processes
# before continuum's backgrounded auto-restore runs, or restore yields bare shells):
#   set -g @plugin 'tmux-plugins/tmux-resurrect'
#   set -g @plugin '<you>/tmux-ai-sessions-restore'
#   set -g @plugin 'tmux-plugins/tmux-continuum'
#
# On first load this also registers the per-tool capture hooks (Claude SessionStart /
# Kiro agentSpawn) by running scripts/install_hooks.sh once. Disable that with:
#   set -g @ai-restore-auto-install 'off'   # then run scripts/install_hooks.sh yourself

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_CMD="bash '$CURRENT_DIR/scripts/rewrite_save.sh'"

# Append our rewriter to resurrect's post-save hook without clobbering an existing value.
existing="$(tmux show-option -gqv '@resurrect-hook-post-save-all' 2>/dev/null)"
case "$existing" in
	*rewrite_save.sh*)
		: # already wired
		;;
	'')
		tmux set-option -g '@resurrect-hook-post-save-all' "$HOOK_CMD"
		;;
	*)
		tmux set-option -g '@resurrect-hook-post-save-all' "$existing ; $HOOK_CMD"
		;;
esac

# resurrect only re-runs a pane's saved command if it matches @resurrect-processes, so add
# a relaxed (~) match for each enabled tool's binary — without clobbering the user's list.
# Without this, restore brings back the layout but every AI pane is just a bare shell.
enabled="$(tmux show-option -gqv '@ai-restore-enabled-tools' 2>/dev/null)"
enabled="${enabled:-claude kiro}"
procs="$(tmux show-option -gqv '@resurrect-processes' 2>/dev/null)"
add=''
case " $enabled " in *' claude '*) case "$procs" in *'~claude'*) : ;; *) add="$add ~claude" ;; esac ;; esac
case " $enabled " in *' kiro '*)   case "$procs" in *'~kiro-cli'*) : ;; *) add="$add ~kiro-cli" ;; esac ;; esac
if [ -n "$add" ]; then
	procs="${procs}${add}"
	tmux set-option -g '@resurrect-processes' "${procs# }"
fi

# Register the capture hooks once (idempotent). Backgrounded so tmux startup never blocks;
# a stamp file keeps it from re-running (and re-spawning kiro-cli) on every tmux start.
auto_install="$(tmux show-option -gqv '@ai-restore-auto-install' 2>/dev/null)"
if [ "$auto_install" != "off" ] && [ ! -f "$CURRENT_DIR/.hooks_installed" ]; then
	tmux run-shell -b "bash '$CURRENT_DIR/scripts/install_hooks.sh' >/dev/null 2>&1 && touch '$CURRENT_DIR/.hooks_installed'"
fi
