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
# On first load this also registers the per-tool capture hooks (Claude / Kiro prompt hooks)
# by running scripts/install_hooks.sh once. Disable that with:
#   set -g @ai-restore-auto-install 'off'   # then run scripts/install_hooks.sh yourself

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_CMD="bash '$CURRENT_DIR/scripts/rewrite_save.sh'"

# wire_hook <option>: make <option> run our rewriter exactly once, at this path, without
# clobbering anything else the user put there.
wire_hook() {
	local existing
	existing="$(tmux show-option -gqv "$1" 2>/dev/null)"
	case "$existing" in
		*"$HOOK_CMD"*)
			: # already wired to this exact path
			;;
		*rewrite_save.sh*)
			# Wired to a *different* rewrite_save.sh path — e.g. the plugin moved between
			# ~/.tmux/plugins and ~/.config/tmux/plugins. Point that stale segment here.
			tmux set-option -g "$1" "$(printf '%s' "$existing" | sed -E "s#bash '[^']*rewrite_save\.sh'#${HOOK_CMD}#g")"
			;;
		'')
			tmux set-option -g "$1" "$HOOK_CMD"
			;;
		*)
			tmux set-option -g "$1" "$existing ; $HOOK_CMD"
			;;
	esac
}

# unwire_hook <option>: drop our rewriter from <option> (any path), keeping the rest.
unwire_hook() {
	local existing rest seg kept=''
	existing="$(tmux show-option -gqv "$1" 2>/dev/null)"
	case "$existing" in *rewrite_save.sh*) ;; *) return ;; esac
	rest="$existing"
	while [ -n "$rest" ]; do
		seg="${rest%% ; *}"
		if [ "$seg" = "$rest" ]; then rest=''; else rest="${rest#* ; }"; fi
		case "$seg" in *rewrite_save.sh*) ;; *) kept="${kept:+$kept ; }$seg" ;; esac
	done
	if [ -n "$kept" ]; then tmux set-option -g "$1" "$kept"; else tmux set-option -gu "$1"; fi
}

# Rewrite the save file in post-save-layout: resurrect runs it right after writing the file
# and *before* repointing `last` at it, so `last` never names a file we haven't rewritten
# (a post-save-all hook runs after the repoint — kill the server in between and restore
# replays stale commands). Only a resurrect too old to have that hook gets post-save-all.
save_script="$(tmux show-option -gqv '@resurrect-save-script-path' 2>/dev/null)"
if [ -f "$save_script" ] && ! grep -q 'post-save-layout' "$save_script" 2>/dev/null; then
	unwire_hook '@resurrect-hook-post-save-layout'
	wire_hook '@resurrect-hook-post-save-all'
else
	unwire_hook '@resurrect-hook-post-save-all'   # migrate installs wired by older versions
	wire_hook '@resurrect-hook-post-save-layout'
fi

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
