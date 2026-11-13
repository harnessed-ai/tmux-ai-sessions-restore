#!/usr/bin/env bash
# agent-hook-version: 4
# agent-hook.sh <tool> [event]
# agent-hook.sh --seen <pane>
#
# The shared writer of the harnessed-ai @agent_* contract: tmux pane options that say
# what an agent pane is doing, so any tmux plugin can read them without each installing
# its own hooks.
#
#   @agent_tool        claude | kiro | …
#   @agent_state       working | blocked | idle | done | error
#   @agent_state_since epoch seconds of the last state change
#   @agent_name        session name the agent reports (Claude: /rename)
#   @agent_activity    short "what it's doing" (e.g. "Bash: npm test")
#   @agent_session_id  the agent's conversation id, set once it has something to resume
#                      (your first prompt, or a resumed session), so session-restore
#                      plugins can relaunch it
#   @agent_pid         pid of the agent CLI (lets readers drop state left by a crash)
#
# Register it for every lifecycle event of the agent. The event comes from the hook
# payload's hook_event_name (Claude and Kiro both send it) or from the second argument.
#
# Runs inside the agent's pane, so $TMUX_PANE names the pane. Must never fail or print:
# hook stdout can be injected into the conversation, and a failing hook can block it.
#
# Shared between plugins. Each plugin ships an identical copy; the installer keeps one
# registration per event and prefers the highest agent-hook-version (line 2).
#
# Listeners: any global option named @agent-on-change-<plugin> holds a command; when a
# pane's @agent_state changes, "<command> <pane_id>" runs in the background, so a plugin
# can redraw without installing hooks of its own.
#
# Seen: "done" means finished and not looked at yet. `agent-hook.sh --seen <pane>` turns
# done into idle (and notifies listeners); any plugin that notices you looking calls it.
# A finished shell command (@agent_tool shell) is cleared instead.
# @agent-seen-on (focus | prompt) is the shared policy for when that happens.

notify() { # notify <pane>: run every registered listener for the pane
	local name cmd
	tmux show-options -g 2>/dev/null | sed -n 's/^\(@agent-on-change[^ ]*\) .*/\1/p' |
		while read -r name; do
			cmd="$(tmux show-options -gqv "$name" 2>/dev/null)"
			[ -n "$cmd" ] && tmux run-shell -b "$cmd $1" 2>/dev/null
		done
}

if [ "${1:-}" = --seen ]; then
	[ -n "${2:-}" ] && command -v tmux >/dev/null 2>&1 || exit 0
	exec >/dev/null 2>&1
	IFS=$'\x1f' read -r st tl < <(tmux display-message -p -t "$2" "#{@agent_state}"$'\x1f'"#{@agent_tool}" 2>/dev/null)
	[ "$st" = done ] || exit 0
	if [ "$tl" = shell ]; then # a finished shell command, now seen: nothing left to show
		tmux set-option -p -u -t "$2" @agent_tool \; set-option -p -u -t "$2" @agent_state \; \
			set-option -p -u -t "$2" @agent_state_since \; set-option -p -u -t "$2" @agent_name 2>/dev/null
	else
		tmux set-option -p -t "$2" @agent_state idle \; \
			set-option -p -t "$2" @agent_state_since "$(date +%s)" 2>/dev/null
	fi
	notify "$2"
	exit 0
fi

tool="${1:-}"
event="${2:-}"
[ -n "$tool" ] || exit 0
[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0
command -v jq   >/dev/null 2>&1 || exit 0
exec >/dev/null 2>&1

json="$(cat)"
[ -n "$json" ] || json='{}'

# One jq pass pulls everything we might need, \x1f-separated.
IFS=$'\x1f' read -r ev session_id transcript ntype source activity < <(
	printf '%s' "$json" | jq -rj '
		def short: tostring | split("\n")[0] | if length > 60 then .[0:59] + "…" else . end;
		(.tool_input // {}) as $i
		| ( if ($i | type) != "object" then ""
		    elif $i.command then $i.command
		    elif $i.file_path then ($i.file_path | tostring | split("/") | last)
		    elif $i.path then ($i.path | tostring | split("/") | last)
		    elif $i.pattern then $i.pattern
		    elif $i.url then $i.url
		    elif $i.query then $i.query
		    elif $i.description then $i.description
		    else "" end | short ) as $arg
		| [ (.hook_event_name // ""),
		    (.session_id // ""),
		    (.transcript_path // ""),
		    (.notification_type // ""),
		    (.source // ""),
		    ( if (.tool_name // "") == "" then ""
		      elif $arg == "" then .tool_name
		      else "\(.tool_name): \($arg)" end ) ]
		| map(tostring | gsub("\u001f"; " ")) | join("\u001f")' 2>/dev/null
	printf '\n'
)
[ -n "$event" ] || event="$ev"
event="$(printf '%s' "$event" | tr '[:upper:]' '[:lower:]' | tr -d '_-')"

pane="$TMUX_PANE"
IFS=$'\x1f' read -r cur_state cur_pid seen_on focus_events < <(
	tmux display-message -p -t "$pane" "#{@agent_state}"$'\x1f'"#{@agent_pid}"$'\x1f'"#{@agent-seen-on}"$'\x1f'"#{focus-events}" 2>/dev/null
)
new_state="$cur_state"

# A turn that finishes in the pane you are looking at is already seen. Only knowable with
# focus-events on (otherwise every attached client reports "focused").
watched() {
	[ "$seen_on" = focus ] && [ "$focus_events" = 1 ] || return 1
	tmux list-clients -F "#{client_flags} #{pane_id}" 2>/dev/null | grep -q "focused.* $pane\$"
}

# The agent CLI process this hook belongs to: the nearest ancestor named like the tool.
find_cli_pid() {
	local re pid info ppid comm name args a words
	case "$tool" in
		claude) re='^claude$' ;;
		kiro)   re='^kiro-cli(-chat)?$' ;;
		codex)  re='^codex$' ;;
		*)      re="^${tool}\$" ;;
	esac
	pid="$PPID"
	for _ in 1 2 3 4 5 6; do
		case "$pid" in ''|0|1) return ;; esac
		info="$(ps -o ppid=,comm= -p "$pid" 2>/dev/null)" || return
		read -r ppid comm <<< "$info"
		name="${comm##*/}"
		if ! [[ "${name#-}" =~ $re ]]; then
			args="$(ps -o args= -p "$pid" 2>/dev/null)"
			name="${args%% *}"; name="${name##*/}"
			case "$name" in
				node|bun|deno) # the CLI is a script: match the first non-option argument
					read -ra words <<< "$args"
					for a in "${words[@]:1}"; do case "$a" in -*) ;; *) name="${a##*/}"; break ;; esac; done ;;
			esac
		fi
		if [[ "${name#-}" =~ $re ]]; then printf '%s' "$pid"; return; fi
		pid="$ppid"
	done
}

# Name the agent reports for this session. Claude: the last /rename in the transcript.
session_name() {
	[ -n "$transcript" ] && [ -f "$transcript" ] || return
	grep -a '"type":"custom-title"' "$transcript" 2>/dev/null | tail -n 1 \
		| jq -r '.customTitle // empty' 2>/dev/null
}

cmds=()
set_opt()   { cmds+=(set-option -p -t "$pane" "$1" "$2" \;); }
unset_opt() { cmds+=(set-option -p -u -t "$pane" "$1" \;); }
set_state() {
	if [ "$1" != "$cur_state" ]; then
		set_opt @agent_state "$1"
		set_opt @agent_state_since "$(date +%s)"
		new_state="$1"
	fi
}
identify() { # identify [with-session]
	# Who's in this pane — done on session start / prompt, not on every tool call. The
	# session id is only recorded once there is a conversation to resume ("with-session"),
	# so a restore never tries to resume an empty session.
	local pid name
	set_opt @agent_tool "$tool"
	[ "${1:-}" = with-session ] && [ -n "$session_id" ] && set_opt @agent_session_id "$session_id"
	pid="$(find_cli_pid)"
	if [ -n "$pid" ]; then
		# A one-shot run inside the pane (claude -p from the Bash tool, --bg) fires the same
		# hooks; it must not take over the interactive agent's pane.
		case " $(ps -o args= -p "$pid" 2>/dev/null) " in
			*' -p '*|*' --print '*|*' --bg '*|*' --background '*|*' --no-interactive '*) exit 0 ;;
		esac
		set_opt @agent_pid "$pid"
	fi
	name="$(session_name)"
	if [ -n "$name" ]; then set_opt @agent_name "$name"; fi
}
# Hooks for tool calls fire from one-shot runs too; ignore those once we know the pane's
# interactive agent pid and the firing process isn't it.
foreign() {
	[ -n "$cur_pid" ] || return 1
	local pid; pid="$(find_cli_pid)"
	[ -n "$pid" ] && [ "$pid" != "$cur_pid" ]
}

case "$event" in
	sessionstart|agentspawn)
		if [ "$source" = resume ]; then identify with-session; else identify; fi
		set_state idle
		unset_opt @agent_activity
		;;
	userpromptsubmit)
		identify with-session
		set_state working
		unset_opt @agent_activity
		;;
	pretooluse)
		foreign && exit 0
		[ -n "$cur_state" ] || set_opt @agent_tool "$tool"
		set_state working
		[ -n "$activity" ] && set_opt @agent_activity "$activity"
		;;
	posttooluse|posttoolusefailure)
		foreign && exit 0
		set_state working
		;;
	permissionrequest)
		# Fires as the permission dialog opens (Notification follows seconds later).
		# Prints nothing, so Claude shows its normal dialog.
		foreign && exit 0
		set_state blocked
		;;
	notification)
		case "$ntype" in
			permission_prompt|elicitation_dialog) set_state blocked ;;
			*) exit 0 ;;
		esac
		;;
	stop)
		foreign && exit 0
		if watched; then set_state idle; else set_state done; fi
		unset_opt @agent_activity
		name="$(session_name)"
		if [ -n "$name" ]; then set_opt @agent_name "$name"; fi
		;;
	stopfailure)
		set_state error
		;;
	sessionend)
		foreign && exit 0
		for o in @agent_tool @agent_state @agent_state_since @agent_name @agent_activity \
		         @agent_session_id @agent_pid; do
			unset_opt "$o"
		done
		new_state=""
		;;
	*)
		exit 0
		;;
esac

[ "${#cmds[@]}" -gt 0 ] && tmux "${cmds[@]}" 2>/dev/null
[ "$new_state" != "$cur_state" ] && notify "$pane"
exit 0
