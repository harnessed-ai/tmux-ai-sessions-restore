#!/usr/bin/env bash
# rewrite_save.sh
#
# Wired into tmux-resurrect via @resurrect-hook-post-save-all, so it runs right after
# resurrect finishes writing its save file. For every live pane that carries an
# @ai_session_id (stamped by capture_session.sh), it rewrites field 11 (the restored
# command) of that pane's line so resurrect relaunches the AI CLI *resumed* on restore.
#
# resurrect pane-line format (tab-separated, 11 fields):
#   pane | session_name(2) | window_index(3) | window_active(4) | :window_flags(5) |
#   pane_index(6) | pane_title(7) | :pane_current_path(8) | pane_active(9) |
#   pane_command(10) | :full_command(11)
# An empty full_command is stored as a bare ":"; restore replays any pane whose field 11
# is not ":" (with no @resurrect-processes re-check), so filling it is sufficient.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
. "$HERE/helpers.sh"

command -v tmux >/dev/null 2>&1 || exit 0
command -v awk  >/dev/null 2>&1 || exit 0

dir="$(air_resurrect_dir)"
last="$dir/last"
[ -e "$last" ] || exit 0

# Operate on the real timestamped file that `last` points to, so the symlink stays valid.
if [ -L "$last" ]; then
	tgt="$(readlink "$last")"
	case "$tgt" in
		/*) f="$tgt" ;;
		*)  f="$dir/$tgt" ;;
	esac
else
	f="$last"
fi
[ -f "$f" ] || exit 0

# Build a map: session<TAB>window<TAB>pane<TAB>resume_command for live AI panes.
map="$(mktemp "${TMPDIR:-/tmp}/air_map.XXXXXX")" || exit 0
trap 'rm -f "$map"' EXIT

tmux list-panes -a -F '#{session_name}	#{window_index}	#{pane_index}	#{@ai_tool}	#{@ai_session_id}	#{pane_pid}' 2>/dev/null \
| while IFS=$'\t' read -r s w p tool id ppid; do
	[ -n "$id" ] || continue
	air_tool_enabled "$tool" || continue
	# Skip stale markers: only rewrite if the tool is actually running in this pane's
	# process subtree (sees through shell-integration wrappers like kiro-cli-term).
	air_pane_runs_tool "$tool" "$ppid" || continue
	# The command resurrect already saved for this pane (field 11, minus the leading ':'),
	# so we can preserve the user's flags and just append the resume flag.
	orig="$(awk -F'\t' -v s="$s" -v w="$w" -v p="$p" \
		'$1=="pane" && $2==s && $3==w && $6==p { v=$11; sub(/^:/, "", v); print v; exit }' "$f")"
	cmd="$(air_build_resume "$tool" "$id" "$orig")" || continue
	[ -n "$cmd" ] || continue
	printf '%s\t%s\t%s\t%s\n' "$s" "$w" "$p" "$cmd" >> "$map"
done

# No AI panes -> leave the save file untouched.
[ -s "$map" ] || exit 0

# Rewrite field 11 for matching pane lines. tmp lives in the resurrect dir so the final
# mv is an atomic same-filesystem rename.
tmp="$(mktemp "$dir/.air_last.XXXXXX")" || exit 0
if awk -F'\t' -v OFS='\t' '
	NR==FNR { cmd[$1 SUBSEP $2 SUBSEP $3] = $4; next }
	/^pane/ {
		k = $2 SUBSEP $3 SUBSEP $6
		if (k in cmd) { $11 = ":" cmd[k] }
	}
	{ print }
' "$map" "$f" > "$tmp"; then
	mv "$tmp" "$f"
else
	rm -f "$tmp"
fi

exit 0
