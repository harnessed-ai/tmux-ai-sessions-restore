#!/usr/bin/env bash
# Shared helpers for tmux-ai-sessions-restore.
# Sourced by rewrite_save.sh and the install/uninstall scripts.

# Substring marker embedded in every command we install into a tool's hook config,
# so install/uninstall stay idempotent and reversible.
AIR_MARKER="tmux-ai-sessions-restore"

# air_tmux_get <option> <default> -> prints the global tmux option, or the default.
air_tmux_get() {
	local val
	val="$(tmux show-option -gqv "$1" 2>/dev/null)"
	if [ -z "$val" ]; then printf '%s' "$2"; else printf '%s' "$val"; fi
}

# air_resurrect_dir -> the directory tmux-resurrect saves into (honours @resurrect-dir).
air_resurrect_dir() {
	local d
	d="$(tmux show-option -gqv '@resurrect-dir' 2>/dev/null)"
	if [ -n "$d" ]; then
		d="${d/#\~/$HOME}"
		d="${d/#\$HOME/$HOME}"
		printf '%s' "$d"
		return
	fi
	# Recent tmux-resurrect defaults to the XDG data dir; older installs used
	# ~/.tmux/resurrect. Prefer the XDG path when it exists, else fall back.
	local xdg="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
	if [ -d "$xdg" ]; then
		printf '%s' "$xdg"
	else
		printf '%s' "$HOME/.tmux/resurrect"
	fi
}

# air_tool_enabled <tool> -> 0 if the tool is in @ai-restore-enabled-tools.
air_tool_enabled() {
	local tool="$1" enabled
	enabled="$(air_tmux_get '@ai-restore-enabled-tools' 'claude kiro')"
	case " $enabled " in
		*" $tool "*) return 0 ;;
		*) return 1 ;;
	esac
}

# air_pane_runs_tool <tool> <pane_pid> -> 0 if the tool is running anywhere in the pane's
# process subtree. We check the subtree (not #{pane_current_command}) so it sees through
# shell-integration pty wrappers — e.g. kiro-cli's "kiro-cli-term" / Amazon Q's figterm —
# which sit in front of your shell and otherwise mask the real program from tmux. This also
# guards against stale markers: a pane reused for an editor has no assistant in its subtree.
air_pane_runs_tool() {
	local tool="$1" root="$2" re
	case "$tool" in
		claude) re='^claude$' ;;
		# match the chat binary, not the "kiro-cli-term" shell wrapper
		kiro)   re='^kiro-cli$|^kiro-cli-chat$' ;;
		*) return 1 ;;
	esac
	[ -n "$root" ] || return 1
	ps -Ao pid=,ppid=,comm= 2>/dev/null | awk -v root="$root" -v re="$re" '
		{ pid=$1; ppid=$2; comm=$3; sub(/.*\//, "", comm)
		  P[pid]=ppid; C[pid]=comm; ID[NR]=pid; n=NR }
		END {
			d[root]=1; ch=1
			while (ch) { ch=0
				for (i=1;i<=n;i++) { x=ID[i]; if (!(x in d) && (P[x] in d)) { d[x]=1; ch=1 } }
			}
			for (i=1;i<=n;i++) { x=ID[i]; if ((x in d) && C[x] ~ re) found=1 }
			exit (found ? 0 : 1)
		}'
}

# air_build_resume <tool> <session_id> <original_command> -> prints the command to put
# back into the pane on restore. It preserves the user's original launch command (so flags
# like --dangerously-skip-permissions survive) and just appends the resume flag, then a
# cold-launch fallback (unless @ai-restore-cold-fallback is off) so an expired/invalid id
# degrades to a normal start. If <original_command> is empty (resurrect saved nothing),
# the configured launcher is used as the base.
air_build_resume() {
	local tool="$1" id="$2" orig="$3" fallback flag base needle cmd
	fallback="$(air_tmux_get '@ai-restore-cold-fallback' 'on')"
	case "$tool" in
		claude)
			flag='--resume'
			base="$(air_tmux_get '@ai-restore-claude-command' 'claude')"
			;;
		kiro)
			flag='--resume-id'
			base="$(air_tmux_get '@ai-restore-kiro-command' 'kiro-cli chat')"
			;;
		*)
			return 1
			;;
	esac
	# Build on the saved launch command only if it actually looks like this tool (so the
	# user's flags survive). Otherwise — empty, or a shell that resurrect happened to
	# record for the pane — fall back to the configured launcher.
	needle="${base%% *}"
	case "$orig" in
		*"$needle"*) : ;;
		*) orig="$base" ;;
	esac
	# Already a resume command (user launched with --resume / --resume-id)? Leave it.
	case "$orig" in
		*--resume*) printf '%s' "$orig"; return 0 ;;
	esac
	cmd="$orig $flag $id"
	[ "$fallback" = "on" ] && cmd="$cmd || $orig"
	printf '%s' "$cmd"
}
