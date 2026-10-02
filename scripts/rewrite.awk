# rewrite.awk — apply plan.awk's decisions to a tmux-resurrect save file. Used by
# rewrite_save.sh.
#
# Inputs (file names passed as -v vars): plan (plan.awk output), cwds ("pid<TAB>cwd"), and
# the save file itself. Vars: claude_base, kiro_base (as for plan.awk). With -v explain=1 it
# prints a per-pane report instead.
#
# resurrect pane-line format (tab-separated, 11 fields):
#   pane | session(2) | window(3) | window_active(4) | :window_flags(5) | pane_index(6) |
#   pane_title(7) | :pane_current_path(8) | pane_active(9) | pane_current_command(10) |
#   :full_command(11)
# restore creates the pane in field 8's directory and types field 11 into it when that
# command matches @resurrect-processes.
#
# For every pane running an AI CLI, field 11 becomes plan.awk's command and field 8 the
# CLI's own cwd. A pane is only rewritten if its line still describes the same pane as the
# live snapshot (same current command and path), since the layout can change while a save
# runs; otherwise an AI command on it is reduced to a bare cold launch, since resurrect's raw
# argv is unquoted and can fail to start at all (e.g. `--model opus[1m]` is a zsh glob). It also undoes two tmux-resurrect save bugs that make restore start the wrong thing:
#  - An empty pane title (Claude clears it on exit; some shells never set one) collapses in
#    resurrect's IFS=tab `read`, shifting every later field left: the cwd lands in the title
#    slot, the pane restores in the wrong directory, and field 11 holds the command of some
#    unrelated process (the history size was looked up as a pid). Spotted by field 8
#    lacking its ':' prefix; shifted back, with field 11 re-derived from the real pane pid.
#  - resurrect's ps strategy matches the pane pid as a *prefix* of each ppid and keeps every
#    match, so extra lines — other panes' commands, claude included — can follow a pane line.
#    They are dropped, and an AI command recorded for a pane that runs no AI CLI is cleared
#    so restore doesn't start one there.

BEGIN {
    FS = "\t"; OFS = "\t"
    if (claude_base == "") claude_base = "claude"
    if (kiro_base == "") kiro_base = "kiro-cli chat"
}

FILENAME == plan {
    k = $1 SUBSEP $2 SUBSEP $3
    P[k] = 1; CUR_CMD[k] = $5; CUR_PATH[k] = $6; TOOL[k] = $7; TPID[k] = $8
    SRC[k] = $9; ID[k] = $10; CMD[k] = $11
    CHILD[$4] = $12
    next
}
FILENAME == cwds { CWD[$1] = $2; next }

# resurrect escapes the first space of a path and `echo`s it unquoted (squeezing blanks)
function norm(p) { gsub(/\\ /, " ", p); gsub(/  +/, " ", p); return p }
function mentions_ai(c) { return c ~ /(^|[ \/])(claude|kiro-cli)( |$)/ }
function cold_launch(c) { return c ~ /(^|[ \/])kiro-cli( |$)/ ? kiro_base : claude_base }
function add_note(s) { note = note (note == "" ? "" : "; ") s }

$1 == "pane" {
    note = ""
    if (NF == 11 && $7 ~ /^:/ && $8 ~ /^[01]$/ && $10 ~ /^[0-9]+$/) {
        t7 = $7; t8 = $8; t9 = $9; t10 = $10
        $7 = " "; $8 = t7; $9 = t8; $10 = t9; $11 = ":" CHILD[t10]
        add_note("repaired fields shifted by an empty pane title"); repaired++
    }
    k = $2 SUBSEP $3 SUBSEP $6
    was11 = $11; was8 = $8
    if (k in P) {
        if (TOOL[k] != "") {
            if (CUR_CMD[k] == $10 && norm(substr($8, 2)) == norm(CUR_PATH[k])) {
                $11 = ":" CMD[k]
                if ((TPID[k] in CWD) && CWD[TPID[k]] != "") $8 = ":" CWD[TPID[k]]
                ai++
            } else if (mentions_ai(substr($11, 2))) {
                $11 = ":" cold_launch(substr($11, 2))
                add_note("the live pane no longer matches this line (it changed during or since the save); recorded AI command reduced to a cold launch"); skipped++
            } else {
                add_note("the live pane no longer matches this line (it changed during or since the save); left as recorded"); skipped++
            }
        } else if (mentions_ai(substr($11, 2))) {
            $11 = ":"
            add_note("cleared an AI command resurrect attributed to this non-AI pane"); cleared++
        }
    }
    if (explain) report(k, was11, was8)
    else print
    in_pane = 1
    next
}
in_pane && $0 !~ /\t/ && $0 != "" { stray++; next }
{ in_pane = 0; if (!explain) print }

function report(k, was11, was8) {
    if (TOOL[k] == "" && note == "" && !mentions_ai(substr(was11, 2))) return
    printf "%s:%s.%s  %s\n", $2, $3, $6, (TOOL[k] == "" ? "no AI CLI running" : \
        TOOL[k] " (pid " TPID[k] ")  " (ID[k] == "" ? "no session id -> cold relaunch" : \
        "session " ID[k] " from " (SRC[k] == "marker" ? "prompt-hook marker" : "its command line")))
    printf "    saved file now:  %s\n", substr(was11, 2)
    if ($11 != was11) printf "    after rewrite:   %s\n", substr($11, 2)
    if ($8 != was8) printf "    directory:       %s -> %s\n", substr(was8, 2), substr($8, 2)
    if (note != "") printf "    note:            %s\n", note
}

END {
    if (explain)
        printf "\n%d AI pane(s) rewritten, %d skipped (pane changed), %d shifted line(s) repaired, " \
               "%d stray line(s) dropped, %d misattributed AI command(s) cleared\n", \
               ai, skipped, repaired, stray, cleared
}
