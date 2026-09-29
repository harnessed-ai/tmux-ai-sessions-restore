#!/usr/bin/env bash
# Unit test for scripts/rewrite.awk: applying a plan to a tmux-resurrect save file, including
# the repairs for resurrect's own save bugs (fields shifted by an empty pane title, stray
# lines from its ppid-prefix grep). Synthetic inputs, no tmux needed.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
t=$'\t'
line() { local IFS="$t"; printf '%s\n' "$*"; }

# plan.awk output: session window pane pane_pid cur_cmd cur_path tool tool_pid source id command first_child
{
  line s 1 1 101 claude /p      claude 111 marker NEW1 "claude --resume NEW1 || claude" "claude --resume OLD1"
  line s 1 2 202 claude /p      claude 222 marker NEW2 "claude --resume NEW2 || claude" "claude"
  line s 1 3 303 zsh    /q      ""     ""  ""     ""   ""                               ""
  line s 1 4 404 zsh    /r      ""     ""  ""     ""   ""                               ""
  line s 2 1 505 claude /new    claude 555 argv   ID5  "claude --resume ID5 || claude"  "claude --resume ID5"
  line s 2 2 606 vim    /v      ""     ""  ""     ""   ""                               "vim notes.md"
  line s 2 3 707 claude "/my project" claude 777 marker ID7 "claude --resume ID7 || claude" "claude"
  line s 2 4 808 zsh    /k      ""     ""  ""     ""   ""                               "less /etc/hosts"
} > "$W/plan"
printf '111\t/real/cwd\n222\t/p2\n' > "$W/cwds"   # 777 unknown: keep resurrect's dir

{
  line pane s 1 1 ':*' 1 '✳ Claude Code' ':/p' 1 claude ':claude --resume OLD1'
  # empty title collapsed by resurrect: cwd in the title slot, pid in field 10, junk in 11,
  # and the rest of its multi-line ppid-prefix grep on the following lines
  line pane s 1 2 ':*' 2 ':/p' 0 claude 202 ':gitstatusd -s -1'
  echo "claude --dangerously-skip-permissions --resume LEAKED"
  echo "/bin/zsh"
  line pane s 1 3 ':*' 3 ':/q' 1 zsh 303 ':claude --dangerously-skip-permissions'
  line pane s 1 4 ':*' 4 host ':/r' 0 zsh ':claude --resume LEAK4'
  line pane s 2 1 ':' 1 '✳ Claude Code' ':/old' 0 zsh ':claude --resume ID5'
  line pane s 2 2 ':' 2 host ':/v' 0 vim ':vim notes.md'
  line pane s 2 3 ':' 3 '✳ Claude Code' ':/my\ project' 1 claude ':claude'
  line pane s 2 4 ':' 4 host ':/k' 0 less ':less /etc/hosts'
  line window s 1 ':main' 1 ':*' 'b940,153x43,0,0,3' ':'
  line window s 2 ':side' 0 ':' 'b940,153x43,0,0,4' ':'
  line state s s
} > "$W/save"

awk -v plan="$W/plan" -v cwds="$W/cwds" -f "$ROOT/scripts/rewrite.awk" "$W/plan" "$W/cwds" "$W/save" > "$W/out"

fail=0
pane() { awk -F'\t' -v w="$1" -v p="$2" '$1=="pane" && $3==w && $6==p' "$W/out"; }
check() {
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s\n       got:  [%s]\n       want: [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

check "AI pane: resume command + the CLI's own cwd" "$(pane 1 1)" \
    "$(line pane s 1 1 ':*' 1 '✳ Claude Code' ':/real/cwd' 1 claude ':claude --resume NEW1 || claude')"
check "shifted AI line repaired, then rewritten" "$(pane 1 2)" \
    "$(line pane s 1 2 ':*' 2 ' ' ':/p2' 0 claude ':claude --resume NEW2 || claude')"
check "stray lines from resurrect's multi-line grep dropped" \
    "$(grep -c -e LEAKED -e '^/bin/zsh$' "$W/out")" "0"
check "shifted non-AI line repaired, junk AI command gone" "$(pane 1 3)" \
    "$(line pane s 1 3 ':*' 3 ' ' ':/q' 1 zsh ':')"
check "AI command misattributed to a non-AI pane cleared" "$(pane 1 4)" \
    "$(line pane s 1 4 ':*' 4 host ':/r' 0 zsh ':')"
check "pane changed during the save: left as recorded" "$(pane 2 1)" \
    "$(line pane s 2 1 ':' 1 '✳ Claude Code' ':/old' 0 zsh ':claude --resume ID5')"
check "non-AI pane untouched" "$(pane 2 2)" "$(line pane s 2 2 ':' 2 host ':/v' 0 vim ':vim notes.md')"
check "resurrect's escaped-space dir still matches; unknown cwd kept" "$(pane 2 3)" \
    "$(line pane s 2 3 ':' 3 '✳ Claude Code' ':/my\ project' 1 claude ':claude --resume ID7 || claude')"
check "window/state lines untouched" "$(grep -v '^pane' "$W/out")" "$(grep -v '^pane' "$W/save" | grep -v -e LEAKED -e '^/bin/zsh$')"
check "every pane line still has 11 fields" \
    "$(awk -F'\t' '$1=="pane" && NF!=11' "$W/out" | wc -l | tr -d ' ')" "0"

summary="$(awk -v plan="$W/plan" -v cwds="$W/cwds" -v explain=1 -f "$ROOT/scripts/rewrite.awk" \
    "$W/plan" "$W/cwds" "$W/save" | tail -1)"
check "--explain summary" "$summary" \
    "3 AI pane(s) rewritten, 1 skipped (pane changed), 2 shifted line(s) repaired, 2 stray line(s) dropped, 1 misattributed AI command(s) cleared"

if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAILURES"; exit 1; fi
