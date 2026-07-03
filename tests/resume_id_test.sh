#!/usr/bin/env bash
# Unit test for air_pane_resume_id (helpers.sh).
#
# This is the fallback that keeps a *restored* pane resumable with zero interaction since
# restore: before the capture hook re-fires, the pane has no @ai_session_id marker, but the
# AI CLI it relaunched still holds `--resume <id>` in its own argv. The helper walks the
# pane's process subtree and recovers that id.
#
# Real binaries reject unknown flags (so a renamed `sleep --resume X` would just exit),
# which makes a live-process integration awkward. Instead we drive the helper with a stubbed
# `ps` that emits a controlled process table — the same interface the helper reads.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/helpers.sh
. "$ROOT/scripts/helpers.sh"

fail=0
check() {
	if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
	else printf '  FAIL %s\n       got:  [%s]\n       want: [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

# Controlled process table: "pid ppid command...". Subtree roots are the pane pids.
#   1000 -> 1001  claude --resume ABC-123          (resumed claude, simple flag)
#   2000 -> 2001(kiro-cli-term) -> 2002 kiro-cli chat --resume-id KIRO-777  (through wrapper)
#   3000 -> 3001  claude                            (cold claude, no resume flag)
#   4000 -> 4001  claude --resume=EQ-999            (equals form)
ps() { cat <<'EOF'
1000 1 -zsh
1001 1000 /opt/homebrew/bin/claude --resume ABC-123
2000 1 -zsh
2001 2000 kiro-cli-term
2002 2001 kiro-cli chat --resume-id KIRO-777
3000 1 -zsh
3001 3000 claude
4000 1 -zsh
4001 4000 claude --resume=EQ-999
EOF
}

check "claude resumed pane"            "$(air_pane_resume_id claude 1000)" "ABC-123"
check "kiro resumed pane (thru wrapper)" "$(air_pane_resume_id kiro 2000)" "KIRO-777"
check "claude cold pane -> no id"      "$(air_pane_resume_id claude 3000)" ""
check "claude --resume=<id> form"      "$(air_pane_resume_id claude 4000)" "EQ-999"
check "wrong tool on pane -> no id"    "$(air_pane_resume_id claude 2000)" ""
check "unknown pane pid -> no id"      "$(air_pane_resume_id claude 9999)" ""

# Regression: rewrite_save.sh parses `tmux list-panes` output with IFS=tab. @ai_tool and
# @ai_session_id are the only fields that can be empty (un-restamped pane after restore),
# and tab is IFS-whitespace so consecutive empty fields COLLAPSE. They must be LAST in the
# format string, or pane_pid gets shifted into the wrong variable and the fallback breaks.
# This mirrors the exact format order used in rewrite_save.sh.
line="$(printf '%s\t%s\t%s\t%s\t%s\t%s' 16522 ghostty 1 2 '' '')"
IFS=$'\t' read -r ppid s w p tool id <<<"$line"
check "empty markers don't shift pane_pid" "$ppid" "16522"
check "  ... session parsed"                "$s"    "ghostty"
check "  ... pane_index parsed"             "$p"    "2"
check "  ... empty tool stays empty"        "$tool" ""

if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAILURES"; exit 1; fi
