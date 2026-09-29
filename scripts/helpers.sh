#!/usr/bin/env bash
# Shared helpers for tmux-ai-sessions-restore.
# Sourced by rewrite_save.sh, capture_session.sh and the install/uninstall scripts.

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

# air_tool_regex <tool> -> the process-name pattern (matched against comm and argv[0]
# basenames) that identifies the tool's CLI process. kiro deliberately does not match its
# "kiro-cli-term" shell-integration pty wrapper.
air_tool_regex() {
	case "$1" in
		claude) printf '%s' '^claude$' ;;
		kiro)   printf '%s' '^kiro-cli(-chat)?$' ;;
		*) return 1 ;;
	esac
}

# The per-pane snapshot rewrite_save.sh plans from (tab-separated, read by plan.awk).
# awk splits on a literal tab without collapsing empty fields, so the order is free.
AIR_PANE_FORMAT="$(printf '%s\t' '#{pane_id}' '#{pane_pid}' '#{session_name}' '#{window_index}' \
	'#{pane_index}' '#{pane_current_command}' '#{pane_current_path}' '#{@ai_tool}' \
	'#{@ai_session_id}')#{@ai_pid}"

# air_tool_cwds <plan-file> -> "pid<TAB>cwd" for every AI process the plan names (column 8).
# The CLI's own cwd is where its conversation belongs; tmux's #{pane_current_path} can be
# elsewhere (a pty wrapper such as kiro-cli-term keeps reporting where the pane started).
air_tool_cwds() {
	local pids pid d
	pids="$(awk -F'\t' '$8 != "" { print $8 }' "$1" | sort -u | paste -sd, -)"
	[ -n "$pids" ] || return 0
	if [ -e "/proc/$$/cwd" ]; then
		for pid in ${pids//,/ }; do
			d="$(readlink "/proc/$pid/cwd" 2>/dev/null)" && printf '%s\t%s\n' "$pid" "$d"
		done
	elif command -v lsof >/dev/null 2>&1; then
		lsof -a -d cwd -p "$pids" -Fpn 2>/dev/null |
			awk '/^p/ { pid = substr($0, 2) } /^n/ { printf "%s\t%s\n", pid, substr($0, 2) }'
	fi
}

# air_file_mode <file> -> octal permission bits (so a rewritten save file keeps its mode).
air_file_mode() {
	stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}
