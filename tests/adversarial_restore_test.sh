#!/usr/bin/env bash
# Adversarial end-to-end test: save -> kill-server -> restore, twice, on a big layout.
#
# Spins up PRIVATE tmux servers (tmux -L <socket>, env -i, scratch HOME, scratch
# @resurrect-dir) that load the REAL tmux-resurrect plus the plugin under test, and fills
# them with the kind of workspace that runs for weeks: 3 sessions, 10 windows, 40 panes,
# most of them running a fake `claude` / `kiro-cli` (tests/fixtures/fake_ai_cli.c, compiled
# to binaries with exactly those names, so ps / tmux / resurrect see what they'd see for the
# real CLIs). Panes then go through what long-lived panes go through: prompts, /clear,
# /resume, exits and relaunches, a positional first prompt, a nested `claude -p` run by the
# session itself, an emptied pane title, a dir with spaces, a pty wrapper (like
# kiro-cli-term) with a `cd` inside it, plain shells, less.
#
# Each cycle saves with resurrect's own save.sh (which fires the plugin's hook), kills the
# server, starts a fresh one, restores with resurrect's restore.sh, and checks what every
# pane relaunched: which session id, in which directory, with which flags — and that no
# pane replayed a prompt or launched an AI it wasn't running. Cycle 2 runs on the restored
# server, because panes that were *restored* behave differently from freshly launched ones.
#
# Safety: TMUX is unset and every tmux call names the private socket, so your live server,
# your real resurrect saves and your real AI sessions are never touched; preflight() aborts
# unless the test panes resolve `claude` / `kiro-cli` to the fakes. Don't (re)start your
# real tmux server while this runs: continuum would see the test server and leave its
# auto-save off for the life of yours.
#
#   AIR_PLUGIN_ROOT=<dir>   test another checkout of the plugin (e.g. a baseline)
#   AIR_RESURRECT_DIR=<dir> tmux-resurrect checkout (default: the usual TPM locations)
#   AIR_KEEP=1              keep the scratch dir (save files, fake-CLI log) for inspection

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$(cd "${AIR_PLUGIN_ROOT:-$ROOT}" && pwd)"
unset TMUX TMUX_PANE

TMUX_BIN="$(command -v tmux || true)"
JQ_BIN="$(command -v jq || true)"
CC_BIN="$(command -v cc || command -v clang || command -v gcc || true)"
SHELL_BIN="$(command -v zsh || command -v bash)"
if [ -z "$TMUX_BIN" ] || [ -z "$JQ_BIN" ] || [ -z "$CC_BIN" ]; then
    echo "SKIP: needs tmux, jq and a C compiler"; exit 0
fi
RESURRECT=""
for d in "${AIR_RESURRECT_DIR:-}" "$HOME/.config/tmux/plugins/tmux-resurrect" "$HOME/.tmux/plugins/tmux-resurrect"; do
    if [ -n "$d" ] && [ -f "$d/scripts/save.sh" ] && [ -f "$d/scripts/restore.sh" ]; then RESURRECT="$d"; break; fi
done
[ -n "$RESURRECT" ] || { echo "SKIP: tmux-resurrect not found (set AIR_RESURRECT_DIR)"; exit 0; }

SOCK="air_adv_$$"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/air_adv.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"   # physical path: tmux and getcwd() report /private/var, not /var
BIN="$WORK/bin"; HOME_T="$WORK/home"; STORE="$WORK/store"; LOG="$WORK/ai.log"
RDIR="$WORK/resurrect"; PROJ="$WORK/proj"; EXP="$WORK/expect"
mkdir -p "$BIN" "$HOME_T" "$STORE" "$RDIR" "$PROJ/alpha" "$PROJ/beta" "$PROJ/gamma" \
    "$PROJ/my project" "$PROJ/deep/nested/svc"
# Login shells run /etc/zprofile (macOS path_helper), which moves system dirs back in front
# of the fake bin dir — and a real `claude` there would pick up your Keychain login. So the
# scratch rc files re-prepend the fakes last, and preflight() refuses to run unless every
# pane resolves `claude` / `kiro-cli` to them.
for rc in .zshrc .bashrc .bash_profile; do printf 'export PATH="%s:$PATH"\n' "$BIN" > "$HOME_T/$rc"; done
: > "$LOG"
"$CC_BIN" -O -o "$BIN/claude" "$ROOT/tests/fixtures/fake_ai_cli.c" || { echo "FAIL: compile fake CLI"; exit 1; }
"$CC_BIN" -O -o "$BIN/kiro-cli" "$ROOT/tests/fixtures/fake_ai_cli.c" || exit 1

T() { "$TMUX_BIN" -L "$SOCK" "$@"; }

fake_pids_since() { awk -F'\t' -v from="$1" 'NR>from && $2!="" {print $2}' "$LOG" | sort -u; }
wait_fakes_dead() {
    local pid n=0
    for pid in $(fake_pids_since 0); do
        while kill -0 "$pid" 2>/dev/null && [ $n -lt 100 ]; do sleep 0.1; n=$((n+1)); done
    done
}
cleanup() {
    T kill-server 2>/dev/null
    rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK"
    wait_fakes_dead
    if [ "${AIR_KEEP:-0}" = 1 ]; then echo "kept scratch dir: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

CONF="$WORK/tmux.conf"
cat > "$CONF" <<EOF
set -g base-index 1
set -g pane-base-index 1
set -g renumber-windows on
set -g default-shell '$SHELL_BIN'
set -g history-limit 2000
set -g @resurrect-dir '$RDIR'
set -g @ai-restore-auto-install 'off'
run-shell '$RESURRECT/resurrect.tmux'
run-shell '$PLUGIN/ai_sessions_restore.tmux'
EOF

start_server() { # <session> <dir>  — a clean env, like a terminal starting tmux at login
    env -i HOME="$HOME_T" SHELL="$SHELL_BIN" TERM=xterm-256color LANG=en_US.UTF-8 \
        PATH="$BIN:$(dirname "$TMUX_BIN"):$(dirname "$JQ_BIN"):/usr/bin:/bin:/usr/sbin:/sbin" \
        FAKE_AI_HOME="$STORE" FAKE_AI_LOG="$LOG" \
        FAKE_AI_HOOK="bash '$PLUGIN/scripts/capture_session.sh'" \
        FAKE_AI_TITLE='✳ Claude Code' FAKE_AI_CLEAR_TITLE_ON_EXIT=1 \
        "$TMUX_BIN" -L "$SOCK" -f "$CONF" new-session -d -s "$1" -x 250 -y 120 -c "$2"
}

preflight() { # a real CLI must never run here: check what a pane's shell resolves first
    local p out="$WORK/which.$$.$RANDOM"
    p="$(T list-panes -a -F '#{pane_id}' | head -1)"
    T send-keys -t "$p" -l "{ command -v claude; command -v kiro-cli; } > '$out.tmp' 2>&1; mv '$out.tmp' '$out'"
    T send-keys -t "$p" Enter
    wait_until 100 test -f "$out"
    if [ "$(cat "$out" 2>/dev/null)" != "$(printf '%s\n%s' "$BIN/claude" "$BIN/kiro-cli")" ]; then
        echo "ABORT: test panes resolve the AI CLIs to: $(tr '\n' ' ' < "$out" 2>/dev/null)"
        echo "       (expected the fakes in $BIN) — refusing to run anything that could start a real CLI"
        exit 1
    fi
    T send-keys -t "$p" -l "clear"; T send-keys -t "$p" Enter
}

now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
FROM=0   # log line offset of the current phase (pane ids restart on every server)
mark() { FROM="$(wc -l < "$LOG" | tr -d ' ')"; }
ev_count() { awk -F'\t' -v p="$1" -v e="$2" -v from="$FROM" 'NR>from && $3==p && $1==e {n++} END{print n+0}' "$LOG"; }
has_ev() { [ "$(ev_count "$1" "$2")" -ge "$3" ]; }
last_sid() { awk -F'\t' -v p="$1" -v from="$FROM" 'NR>from && $3==p {s=$5} END{print s}' "$LOG"; }
last_cwd() { awk -F'\t' -v p="$1" -v from="$FROM" 'NR>from && $3==p {s=$4} END{print s}' "$LOG"; }
marker_is() { [ "$(T show -pqv -t "$1" @ai_session_id 2>/dev/null)" = "$2" ]; }
wait_until() { # <tenths> <cmd...>
    local t="$1"; shift
    while [ "$t" -gt 0 ]; do "$@" && return 0; sleep 0.1; t=$((t-1)); done
    return 1
}
SETUP_ERRORS=0
setup_fail() { echo "  setup: pane $1: $2"; SETUP_ERRORS=$((SETUP_ERRORS+1)); }
sk() { T send-keys -t "$1" -l "$2"; T send-keys -t "$1" Enter; }
cdp() { sk "$1" "cd '$2'"; }
key_of() { T display -p -t "$1" '#{session_name}:#{window_index}.#{pane_index}'; }
new_uuid() { uuidgen 2>/dev/null | tr 'A-Z' 'a-z' || cat /proc/sys/kernel/random/uuid; }
seed() { # <tool> <dir> -> id of a pre-existing conversation in that dir (an earlier restore)
    local id slug
    id="$(new_uuid)"; slug="$(printf '%s' "$2" | sed 's/[^A-Za-z0-9]/-/g')"
    mkdir -p "$STORE/$1/$slug"; echo seeded > "$STORE/$1/$slug/$id"
    printf '%s' "$id"
}
start_ai() { # <pane> <command line> <start event>
    local n; n="$(ev_count "$1" "$3")"
    sk "$1" "$2"
    wait_until 100 has_ev "$1" "$3" $((n+1)) || setup_fail "$1" "no '$3' after: $2"
}
send_ai() { # <pane> <line> <event>  — a slash command that logs <event>
    local n; n="$(ev_count "$1" "$3")"
    sk "$1" "$2"
    wait_until 100 has_ev "$1" "$3" $((n+1)) || setup_fail "$1" "no '$3' after: $2"
}
prompt_ai() { # <pane> <text>  — a prompt; waits until the capture hook stamped the pane
    local n; n="$(ev_count "$1" prompt)"
    sk "$1" "$2"
    wait_until 100 has_ev "$1" prompt $((n+1)) || { setup_fail "$1" "prompt not seen"; return; }
    wait_until 100 marker_is "$1" "$(last_sid "$1")" || setup_fail "$1" "marker not stamped"
}
expect() { # <pane> <scenario> <tool> <mode> <id> <dir> <flags>   ('|'-separated: no IFS collapse)
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$(key_of "$1")" "$2" "$3" "$4" "$5" "$6" "$7" >> "$EXP.$CYCLE"
}

# ---------------------------------------------------------------- scenarios (cycle 1)
FLAGS='--dangerously-skip-permissions --model opus'
scn_fresh_prompted()  { cdp "$1" "$2"; start_ai "$1" claude launch; prompt_ai "$1" hello
                        expect "$1" fresh_prompted claude resume "$(last_sid "$1")" "$2" ""; }
scn_fresh_idle()      { cdp "$1" "$2"; start_ai "$1" claude launch
                        expect "$1" fresh_idle claude cold "" "$2" ""; }
scn_restored_idle()   { local o; o="$(seed claude "$2")"; cdp "$1" "$2"; start_ai "$1" "claude --resume $o" resume
                        expect "$1" restored_idle claude resume "$o" "$2" ""; }
scn_restored_prompted() { local o; o="$(seed claude "$2")"; cdp "$1" "$2"; start_ai "$1" "claude --resume $o" resume
                        prompt_ai "$1" "more work"
                        expect "$1" restored_prompted claude resume "$o" "$2" ""; }
scn_restored_clear()  { local o; o="$(seed claude "$2")"; cdp "$1" "$2"; start_ai "$1" "claude --resume $o" resume
                        send_ai "$1" /clear clear; prompt_ai "$1" "new task"
                        expect "$1" restored_clear claude resume "$(last_sid "$1")" "$2" ""; }
scn_restored_switch() { local o x; o="$(seed claude "$2")"; x="$(seed claude "$2")"; cdp "$1" "$2"
                        start_ai "$1" "claude --resume $o" resume; send_ai "$1" "/resume $x" switch; prompt_ai "$1" continue
                        expect "$1" restored_switch claude resume "$x" "$2" ""; }
scn_flags_restored_clear() { local o; o="$(seed claude "$2")"; cdp "$1" "$2"; start_ai "$1" "claude $FLAGS --resume $o" resume
                        send_ai "$1" /clear clear; prompt_ai "$1" "new task"
                        expect "$1" flags_restored_clear claude resume "$(last_sid "$1")" "$2" "$FLAGS"; }
scn_exit_relaunch_resume() { local z; cdp "$1" "$2"; start_ai "$1" claude launch; prompt_ai "$1" first
                        send_ai "$1" /exit exit; z="$(seed claude "$2")"; start_ai "$1" "claude --resume $z" resume
                        expect "$1" exit_relaunch_resume claude resume "$z" "$2" ""; }
scn_exit_to_shell()   { cdp "$1" "$2"; start_ai "$1" claude launch; prompt_ai "$1" first; send_ai "$1" /exit exit
                        expect "$1" exit_to_shell - none "" "" ""; }
scn_exit_relaunch_fresh() { cdp "$1" "$2"; start_ai "$1" claude launch; prompt_ai "$1" first; send_ai "$1" /exit exit
                        start_ai "$1" claude launch
                        expect "$1" exit_relaunch_fresh claude cold "" "$2" ""; }
scn_positional()      { local n; cdp "$1" "$2"; n="$(ev_count "$1" prompt)"; start_ai "$1" "claude hello-there" launch
                        wait_until 100 has_ev "$1" prompt $((n+1)) || setup_fail "$1" "positional prompt not seen"
                        wait_until 100 marker_is "$1" "$(last_sid "$1")" || setup_fail "$1" "marker not stamped"
                        expect "$1" positional claude resume "$(last_sid "$1")" "$2" ""; }
scn_empty_title()     { cdp "$1" "$2"; start_ai "$1" claude launch; prompt_ai "$1" hello; T select-pane -t "$1" -T ""
                        expect "$1" empty_title claude resume "$(last_sid "$1")" "$2" ""; }
scn_space_dir()       { cdp "$1" "$PROJ/my project"; start_ai "$1" claude launch; prompt_ai "$1" hello
                        expect "$1" space_dir claude resume "$(last_sid "$1")" "$PROJ/my project" ""; }
if script --version >/dev/null 2>&1; then WRAP="script -qfc $SHELL_BIN /dev/null"   # util-linux
else WRAP="script -q /dev/null $SHELL_BIN"; fi                                          # BSD / macOS
scn_wrapper_cd()      { cdp "$1" "$2"; sk "$1" "$WRAP"; sleep 0.5; cdp "$1" "$PROJ/gamma"
                        start_ai "$1" "claude --dangerously-skip-permissions" launch; prompt_ai "$1" hello
                        expect "$1" wrapper_cd claude resume "$(last_sid "$1")" "$PROJ/gamma" "--dangerously-skip-permissions"; }
scn_less_pane()       { cdp "$1" "$2"; sk "$1" "less /etc/hosts"; expect "$1" less_pane - less "" "" ""; }
scn_shell_pane()      { cdp "$1" "$2"; expect "$1" shell_pane - none "" "" ""; }
scn_kiro_fresh()      { cdp "$1" "$2"; start_ai "$1" "kiro-cli chat" launch; prompt_ai "$1" hi
                        expect "$1" kiro_fresh kiro resume "$(last_sid "$1")" "$2" ""; }
scn_kiro_restored()   { local o; o="$(seed kiro "$2")"; cdp "$1" "$2"; start_ai "$1" "kiro-cli chat --resume-id $o" resume
                        prompt_ai "$1" more; expect "$1" kiro_restored kiro resume "$o" "$2" ""; }
scn_nested_print()    { local outer n; cdp "$1" "$2"; start_ai "$1" claude launch; prompt_ai "$1" hello
                        outer="$(last_sid "$1")"; n="$(ev_count "$1" exit)"
                        sk "$1" "!claude -p nested-question"   # the session's Bash tool runs a one-shot claude
                        wait_until 100 has_ev "$1" exit $((n+1)) || setup_fail "$1" "nested claude -p did not finish"
                        expect "$1" nested_print claude resume "$outer" "$2" ""; }
scn_fallback_then_prompt() { cdp "$1" "$2"; start_ai "$1" "claude --resume 00000000-0000-4000-8000-000000000000 || claude" launch
                        prompt_ai "$1" hello
                        expect "$1" fallback_then_prompt claude resume "$(last_sid "$1")" "$2" ""; }

SCENARIOS="fresh_prompted fresh_prompted fresh_prompted nested_print fresh_idle fresh_idle
restored_idle restored_idle restored_prompted restored_prompted
restored_clear restored_clear restored_clear restored_clear restored_switch restored_switch
flags_restored_clear flags_restored_clear exit_relaunch_resume exit_relaunch_resume
exit_to_shell exit_to_shell exit_relaunch_fresh exit_relaunch_fresh positional positional
empty_title empty_title space_dir space_dir wrapper_cd wrapper_cd less_pane less_pane
shell_pane shell_pane kiro_fresh kiro_restored fallback_then_prompt fallback_then_prompt"
DIRS="alpha alpha alpha beta gamma deep/nested/svc"   # several AI panes share a dir on purpose

build_layout() { # 3 sessions x (4,4,2) windows x 4 panes = 40 panes
    local spec s nw w i
    start_server main "$PROJ/alpha"
    preflight
    for spec in main:4 work:4 misc:2; do
        s="${spec%%:*}"; nw="${spec##*:}"
        [ "$s" = main ] || T new-session -d -s "$s" -x 250 -y 120 -c "$PROJ/alpha"
        w=1
        while [ $w -le $nw ]; do
            [ $w -eq 1 ] || T new-window -t "$s:$w" -c "$PROJ/alpha"
            for i in 2 3 4; do T split-window -t "$s:$w" -c "$PROJ/alpha"; T select-layout -t "$s:$w" tiled >/dev/null; done
            w=$((w+1))
        done
    done
}

# ---------------------------------------------------------------- save / restore / verify
save_now() { # resurrect's own save, exactly as continuum / prefix+C-s run it
    local t0 t1; t0="$(now)"
    T run-shell "$RESURRECT/scripts/save.sh quiet"
    t1="$(now)"
    SAVE_SECS="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')"
    cp "$RDIR/last" "$WORK/save.cycle$CYCLE.txt"
}

save_health() { # tmux-resurrect's own save-file defects, as they reach the restore
    awk -F'\t' '
        $1=="pane" && NF==11 && $8 !~ /^:/ { shifted++ }
        $0 !~ /\t/ && NF>0 { stray++ }
        END { printf "  saved file: %d pane line(s) with shifted fields (empty pane title), %d stray non-record line(s)\n", shifted, stray }
    ' "$RDIR/last"
}

restart_and_restore() {
    local pid last=-1 n stable=0 t=0
    T kill-server
    wait_fakes_dead
    mark
    start_server main "$PROJ/alpha"          # the terminal re-creates its session at login ...
    preflight
    T run-shell "$RESURRECT/scripts/restore.sh" >> "$WORK/restore.out" 2>&1   # ... and continuum restores into it
    while [ $t -lt 400 ] && [ $stable -lt 20 ]; do   # wait for relaunched CLIs to settle
        n="$(awk -F'\t' -v from="$FROM" 'NR>from {n++} END{print n+0}' "$LOG")"
        if [ "$n" = "$last" ]; then stable=$((stable+1)); else stable=0; last="$n"; fi
        sleep 0.1; t=$((t+1))
    done
}

TOTAL_FAIL=0
verify() { # compare every pane's relaunch against $EXP.$CYCLE
    local panes="$WORK/panes.$CYCLE"
    T list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}|#{pane_id}|#{pane_current_command}' > "$panes"
    awk -F'|' -v from="$FROM" -v logf="$LOG" -v panes="$panes" -v proj="$PROJ/" '
        function short(id) { return id=="" ? "-" : substr(id,1,8) }
        function rel(d) { sub(proj, "", d); return d }
        BEGIN {
            while ((getline l < panes) > 0) { split(l, a, "|"); pid[a[1]]=a[2]; pcmd[a[1]]=a[3] }
            FS="|"
        }
        {
            key=$1; scn=$2; tool=$3; mode=$4; id=$5; dir=$6; flags=$7
            p=pid[key]; ev=""; nres=0; nlaunch=0; nprompt=0; nfail=0; okres=0; seen=""
            cmdline=""
            while ((getline l < logf) > 0) {
                if (++ln <= from) continue
                split(l, e, "\t")
                if (e[3] != p) continue
                if (e[1]=="resume") { nres++; if (e[5]==id && e[4]==dir) okres=1; cmdline=e[7]; seen=seen " resume:" short(e[5]) "@" rel(e[4]) }
                else if (e[1]=="launch") { nlaunch++; cmdline=e[7]; seen=seen " launch@" rel(e[4]) }
                else if (e[1]=="prompt") { nprompt++; seen=seen " PROMPT-REPLAY(" e[6] ")" }
                else if (e[1] ~ /fail|error/) { nfail++; seen=seen " " e[1] ":" short(e[5]) "@" rel(e[4]) }
            }
            close(logf); ln=0
            ok=0
            if (mode=="resume") {
                ok = okres && nlaunch==0 && nprompt==0 && nfail==0
                n=split(flags, f, " "); for (i=1;i<=n;i++) if (index(" " cmdline " ", " " f[i] " ")==0) { ok=0; seen=seen " MISSING-FLAG(" f[i] ")" }
                want="resume " short(id) "@" rel(dir) (flags!="" ? " +" flags : "")
            } else if (mode=="cold") {
                ok = nlaunch==1 && nres==0 && nfail==0 && nprompt==0
                want="cold launch@" rel(dir)
            } else if (mode=="less") {
                ok = pcmd[key]=="less" && seen==""
                want="less (no AI)"; if (pcmd[key]!="less") seen=seen " cmd=" pcmd[key]
            } else {
                ok = seen==""
                want="nothing (no AI)"
            }
            if (seen=="") seen=" (nothing)"
            printf "  %-4s %-8s %-22s want: %-40s got:%s\n", ok?"ok":"FAIL", key, scn, want, seen
            if (!ok) bad++
        }
        END { exit bad>0 }
    ' "$EXP.$CYCLE"
}

report_cycle() {
    local out rc nfail
    out="$(verify)"; rc=$?
    nfail="$(printf '%s\n' "$out" | grep -c '^  FAIL')"
    printf '%s\n' "$out"
    echo "  => cycle $CYCLE: $nfail of $(grep -c . "$EXP.$CYCLE") panes wrong (save took ${SAVE_SECS}s)"
    TOTAL_FAIL=$((TOTAL_FAIL + nfail))
}

# ---------------------------------------------------------------- run
echo "plugin under test: $PLUGIN"
echo "tmux-resurrect:    $RESURRECT"
echo "tmux:              $("$TMUX_BIN" -V)"

CYCLE=1
build_layout
i=0; set -- $DIRS; ndirs=$#
for p in $(T list-panes -a -F '#{pane_id}'); do
    i=$((i+1))
    scn="$(printf '%s\n' $SCENARIOS | sed -n "${i}p")"
    d="$(printf '%s\n' $DIRS | sed -n "$(( (i-1) % ndirs + 1 ))p")"
    "scn_$scn" "$p" "$PROJ/$d"
    [ "$SETUP_ERRORS" -lt 3 ] || { echo "ABORT: the harness itself is failing (setup errors above)"; exit 1; }
done
echo "cycle 1: built 40 panes ($SETUP_ERRORS setup errors); hooks: layout=[$(T show -gqv @resurrect-hook-post-save-layout)] all=[$(T show -gqv @resurrect-hook-post-save-all)]"
save_now
save_health
restart_and_restore
echo "cycle 1 restore:"
report_cycle

# Cycle 2 — keep working in the RESTORED panes, then save / kill / restore again.
# Alternate AI panes: /clear + prompt (a new conversation in a restored process) vs a plain
# prompt (same conversation continues); one restored pane is exited back to its shell.
CYCLE=2
: > "$EXP.$CYCLE"
k=0
while IFS='|' read -r key scn tool mode id dir flags; do
    p="$(T display -p -t "$key" '#{pane_id}' 2>/dev/null)"
    running="$(awk -F'\t' -v p="$p" -v from="$FROM" 'NR>from && $3==p { if ($1=="resume"||$1=="launch") r=$5; if ($1=="exit") r="" } END{print r}' "$LOG")"
    if [ "$tool" = - ] || [ -z "$running" ]; then
        # not an AI pane (or nothing came back): carry the cycle-1 expectation over
        if [ "$tool" = - ]; then printf '%s\n' "$key|$scn|$tool|$mode|$id|$dir|$flags" >> "$EXP.$CYCLE"; fi
        continue
    fi
    k=$((k+1))
    cwd="$(last_cwd "$p")"
    if [ "$k" -eq 3 ]; then
        send_ai "$p" /exit exit
        printf '%s\n' "$key|$scn>exit|-|none|||" >> "$EXP.$CYCLE"
    elif [ $((k % 2)) -eq 0 ]; then
        send_ai "$p" /clear clear; prompt_ai "$p" "cycle 2 task"
        printf '%s\n' "$key|$scn>clear|$tool|resume|$(last_sid "$p")|$cwd|$flags" >> "$EXP.$CYCLE"
    else
        prompt_ai "$p" "cycle 2 follow-up"
        printf '%s\n' "$key|$scn>prompt|$tool|resume|$(last_sid "$p")|$cwd|$flags" >> "$EXP.$CYCLE"
    fi
done < "$EXP.1"
save_now
save_health
restart_and_restore
echo "cycle 2 restore (panes that came back in cycle 1, worked on, saved and restored again):"
report_cycle

echo
if [ "$TOTAL_FAIL" -eq 0 ] && [ "$SETUP_ERRORS" -eq 0 ]; then echo "PASS"; else echo "FAILURES: $TOTAL_FAIL wrong pane restores, $SETUP_ERRORS setup errors"; exit 1; fi
