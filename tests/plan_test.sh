#!/usr/bin/env bash
# Unit test for scripts/plan.awk: which session id each pane restores, and with what command.
# Drives it with a hand-written process table and pane list (the same inputs rewrite_save.sh
# feeds it from ps and tmux), so every branch is deterministic and needs no tmux.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

U1=11111111-1111-4111-8111-111111111111; U2=22222222-2222-4222-8222-222222222222
U3=33333333-3333-4333-8333-333333333333; U4=44444444-4444-4444-8444-444444444444
U5=55555555-5555-4555-8555-555555555555; U6=66666666-6666-4666-8666-666666666666
U8=88888888-8888-4888-8888-888888888888; U9=99999999-9999-4999-8999-999999999999
UA=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa; UB=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
UC=cccccccc-cccc-4ccc-8ccc-cccccccccccc; UD=dddddddd-dddd-4ddd-8ddd-dddddddddddd

# `ps -Ao pid=,ppid=,comm=` and `ps -Ao pid=,command=` for the panes below.
cat > "$W/psc" <<'EOF'
 1000     1 -zsh
 1001  1000 /Users/me/.local/bin/claude
 2000     1 -zsh
 2001  2000 claude
 3000     1 -zsh
 3001  3000 claude
 4000     1 zsh (kiro-cli-term)
 4001  4000 /bin/zsh
 4002  4001 claude
 5000     1 -zsh
 5001  5000 claude
 6000     1 -zsh
 7000     1 -zsh
 7001  7000 kiro-cli
 7002  7001 kiro-cli-chat
 8000     1 -zsh
 8001  8000 claude
 9000     1 -zsh
 9001  9000 claude
10000     1 -zsh
10001 10000 claude
11000     1 -zsh
11001 11000 claude
11002 11001 /bin/zsh
11003 11002 claude
12000     1 -zsh
12001 12000 node
13000     1 -zsh
13001 13000 claude
14000     1 -zsh
14001 14000 claude
15000     1 -zsh
15001 15000 claude
16000     1 -zsh
16001 16000 gitstatusd
16002 16000 vim
EOF
cat > "$W/psa" <<EOF
 1000 -zsh
 1001 /Users/me/.local/bin/claude --dangerously-skip-permissions --resume $U1
 2000 -zsh
 2001 claude --resume $U3
 3000 -zsh
 3001 claude hello there
 4000 zsh (kiro-cli-term)
 4001 /bin/zsh --login
 4002 claude --model opus-5-5[1m] --dangerously-skip-permissions
 5000 -zsh
 5001 claude -c --verbose
 6000 -zsh
 7000 -zsh
 7001 kiro-cli chat --resume-id kiro-abc --trust-all-tools
 7002 kiro-cli-chat chat --resume-id kiro-abc
 8000 -zsh
 8001 claude --resume $U9
 9000 -zsh
 9001 claude
10000 -zsh
10001 claude -r myterm
11000 -zsh
11001 claude
11002 /bin/zsh -c claude -p summarize
11003 claude -p summarize
12000 -zsh
12001 claude
13000 -zsh
13001 claude --resume=$UC
14000 -zsh
14001 claude --session-id $UD
15000 -zsh
15001 claude --allowedTools Bash(git *) Edit --append-system-prompt it's-fine
16000 -zsh
16001 gitstatusd-darwin-arm64 -s -1
16002 vim notes.md
EOF
# `tmux list-panes -a -F "$AIR_PANE_FORMAT"`:
# pane_id pane_pid session window pane cur_cmd cur_path @ai_tool @ai_session_id @ai_pid
t=$'\t'
{
  echo "%1${t}1000${t}s${t}1${t}1${t}claude${t}/p${t}claude${t}$U2${t}1001"   # /clear after a restore
  echo "%2${t}2000${t}s${t}1${t}2${t}claude${t}/p${t}claude${t}$U4${t}1999"   # marker from an exited CLI
  echo "%3${t}3000${t}s${t}1${t}3${t}claude${t}/p${t}claude${t}$U5${t}3001"   # positional first prompt
  echo "%4${t}4000${t}s${t}1${t}4${t}zsh${t}/p${t}claude${t}$U6${t}4002"      # behind a pty wrapper
  echo "%5${t}5000${t}s${t}2${t}1${t}claude${t}/p${t}${t}${t}"               # claude -c, never prompted
  echo "%6${t}6000${t}s${t}2${t}2${t}zsh${t}/p${t}claude${t}$U8${t}6001"      # CLI gone, marker left
  echo "%7${t}7000${t}s${t}2${t}3${t}kiro-cli${t}/p${t}${t}${t}"             # kiro, restored, untouched
  echo "%8${t}8000${t}s${t}2${t}4${t}claude${t}/p${t}claude${t}$U8${t}"       # legacy marker (no @ai_pid)
  echo "%9${t}9000${t}s${t}3${t}1${t}claude${t}/p${t}claude${t}x;rm -rf ~${t}9001" # hostile id
  echo "%10${t}10000${t}s${t}3${t}2${t}claude${t}/p${t}${t}${t}"             # -r <search term>
  echo "%11${t}11000${t}s${t}3${t}3${t}claude${t}/p${t}claude${t}$UA${t}11001" # nested claude -p
  echo "%12${t}12000${t}s${t}3${t}4${t}node${t}/p${t}claude${t}$UB${t}12001"  # comm=node, title=claude
  echo "%13${t}13000${t}s${t}4${t}1${t}claude${t}/p${t}${t}${t}"             # --resume=<id>
  echo "%14${t}14000${t}s${t}4${t}2${t}claude${t}/p${t}${t}${t}"             # --session-id <id>
  echo "%15${t}15000${t}s${t}4${t}3${t}claude${t}/p${t}claude${t}$UC${t}15001" # shell-hostile args
  echo "%16${t}16000${t}s${t}4${t}4${t}vim${t}/p${t}${t}${t}"                # no AI
} > "$W/panes"

run_plan() { # [extra awk -v assignments...]
    awk -v psc="$W/psc" -v psa="$W/psa" -v panes="$W/panes" -v enabled="claude kiro" \
        -v claude_base=claude -v kiro_base="kiro-cli chat" -v fallback=on "$@" \
        -f "$ROOT/scripts/plan.awk" "$W/psc" "$W/psa" "$W/panes"
}
run_plan > "$W/plan"

fail=0
col() { # col <window.pane> <column>  (tool=7 tool_pid=8 source=9 id=10 command=11 first_child=12)
    awk -F'\t' -v wp="$1" -v c="$2" '$2 "." $3 == wp { print $c }' "${3:-$W/plan}"
}
check() {
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s\n       got:  [%s]\n       want: [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

check "live marker beats the restored --resume id (after /clear)" "$(col 1.1 10)" "$U2"
check "  ... bare base command: flags and old id dropped, cold fallback (on)" "$(col 1.1 11)" \
    "claude --resume $U2 || claude"
check "marker from an exited CLI is ignored -> argv id" "$(col 1.2 9):$(col 1.2 10)" "argv:$U3"
check "positional first prompt is never replayed" "$(col 1.3 11)" "claude --resume $U5 || claude"
check "found through a pty wrapper (kiro-cli-term)" "$(col 1.4 8)" "4002"
check "  ... flags never replayed (opus-5-5[1m] would be a zsh glob)" "$(col 1.4 11)" "claude --resume $U6 || claude"
check "no id: plain cold launch, no flags or -c" "$(col 2.1 9):$(col 2.1 11)" ":claude"
check "CLI gone: pane not treated as AI" "$(col 2.2 7)$(col 2.2 11)" ""
check "kiro: shallowest CLI, id from argv" "$(col 2.3 8):$(col 2.3 10)" "7001:kiro-abc"
check "  ... kiro command" "$(col 2.3 11)" "kiro-cli chat --resume-id kiro-abc || kiro-cli chat"
check "legacy marker (no @ai_pid) still trusted" "$(col 2.4 9):$(col 2.4 10)" "marker:$U8"
check "hostile marker id rejected (never reaches a shell)" "$(col 3.1 10):$(col 3.1 11)" ":claude"
check "-r <search term> is not an id, and is dropped" "$(col 3.2 10):$(col 3.2 11)" ":claude"
check "nested claude -p: the interactive CLI is the one tracked" "$(col 3.3 8):$(col 3.3 10)" "11001:$UA"
check "CLI detected by argv[0] when comm differs (node)" "$(col 3.4 7):$(col 3.4 10)" "claude:$UB"
check "--resume=<id> form" "$(col 4.1 10)" "$UC"
check "--session-id <id>" "$(col 4.2 10)" "$UD"
check "shell-hostile arguments are never replayed" "$(col 4.3 11)" "claude --resume $UC || claude"
check "no AI CLI: nothing planned" "$(col 4.4 7)$(col 4.4 11)" ""
check "first child recorded (resurrect's intended command)" "$(col 4.4 12)" "gitstatusd-darwin-arm64 -s -1"

run_plan -v fallback= > "$W/plan.nofallback"
check "@ai-restore-cold-fallback unset: off by default" "$(col 1.3 11 "$W/plan.nofallback")" "claude --resume $U5"
run_plan -v fallback=off > "$W/plan.nofallback"
check "@ai-restore-cold-fallback off" "$(col 2.3 11 "$W/plan.nofallback")" "kiro-cli chat --resume-id kiro-abc"

run_plan -v claude_base="claude --dangerously-skip-permissions" > "$W/plan.base"
check "@ai-restore-claude-command is the launch prefix" "$(col 1.4 11 "$W/plan.base")" \
    "claude --dangerously-skip-permissions --resume $U6 || claude --dangerously-skip-permissions"

awk -v psc="$W/psc" -v psa="$W/psa" -v panes="$W/panes" -v enabled="claude" \
    -f "$ROOT/scripts/plan.awk" "$W/psc" "$W/psa" "$W/panes" > "$W/plan.claudeonly"
check "disabled tool is left alone" "$(col 2.3 7 "$W/plan.claudeonly")" ""

if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAILURES"; exit 1; fi
