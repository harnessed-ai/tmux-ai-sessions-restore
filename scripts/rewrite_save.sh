#!/usr/bin/env bash
# rewrite_save.sh [--explain] [save_file]
#
# Wired into tmux-resurrect as @resurrect-hook-post-save-layout, which hands us the save file
# resurrect has just written *before* it points `last` at it — so a server killed mid-save
# can never leave `last` on a file whose AI panes haven't been rewritten yet. (Run with no
# file — as a legacy post-save-all hook, or by hand — it rewrites the file `last` points to.)
#
# It snapshots every live pane and the process table once, decides per pane which command
# brings its AI CLI back (plan.awk), then rewrites the save file (rewrite.awk): the resume
# command for each AI pane, the CLI's real working directory, and repairs for resurrect's
# own save bugs. The file is replaced atomically and only if the rewrite succeeded.
#
# --explain prints what it would change, pane by pane, and leaves the file alone.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
. "$HERE/helpers.sh"

explain=0
if [ "${1:-}" = "--explain" ]; then explain=1; shift; fi

command -v tmux >/dev/null 2>&1 || exit 0
command -v awk  >/dev/null 2>&1 || exit 0

f="${1:-}"
if [ -z "$f" ]; then
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
fi
[ -f "$f" ] || exit 0

work="$(mktemp -d "${TMPDIR:-/tmp}/air_save.XXXXXX")" || exit 0
tmp=""
trap 'rm -rf "$work"; [ -z "$tmp" ] || rm -f "$tmp"' EXIT

# One consistent snapshot of the panes and of the process table, instead of a ps per pane.
tmux list-panes -a -F "$AIR_PANE_FORMAT" > "$work/panes" 2>/dev/null || exit 0
ps -Ao pid=,ppid=,comm= > "$work/psc" 2>/dev/null
ps -Ao pid=,command=    > "$work/psa" 2>/dev/null

claude_base="$(air_tmux_get '@ai-restore-claude-command' 'claude')"
kiro_base="$(air_tmux_get '@ai-restore-kiro-command' 'kiro-cli chat')"
awk -v psc="$work/psc" -v psa="$work/psa" -v panes="$work/panes" \
	-v enabled="$(air_tmux_get '@ai-restore-enabled-tools' 'claude kiro')" \
	-v claude_base="$claude_base" -v kiro_base="$kiro_base" \
	-v fallback="$(air_tmux_get '@ai-restore-cold-fallback' 'off')" \
	-f "$HERE/plan.awk" "$work/psc" "$work/psa" "$work/panes" > "$work/plan" || exit 0
air_tool_cwds "$work/plan" > "$work/cwds"

if [ "$explain" = 1 ]; then
	echo "save file: $f"
	awk -v plan="$work/plan" -v cwds="$work/cwds" -v explain=1 \
		-v claude_base="$claude_base" -v kiro_base="$kiro_base" \
		-f "$HERE/rewrite.awk" "$work/plan" "$work/cwds" "$f"
	exit 0
fi

# tmp lives next to the save file so the final mv is an atomic same-filesystem rename.
tmp="$(mktemp "$(dirname "$f")/.air_save.XXXXXX")" || exit 0
if awk -v plan="$work/plan" -v cwds="$work/cwds" \
		-v claude_base="$claude_base" -v kiro_base="$kiro_base" \
		-f "$HERE/rewrite.awk" "$work/plan" "$work/cwds" "$f" > "$tmp" && [ -s "$tmp" ]; then
	chmod "$(air_file_mode "$f")" "$tmp" 2>/dev/null
	mv "$tmp" "$f" && tmp=""
fi
exit 0
