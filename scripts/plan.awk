# plan.awk — decide, for every live tmux pane, whether it is running an AI CLI and which
# command should bring that pane back on restore. Used by rewrite_save.sh.
#
# Inputs (file names passed as -v vars, so an empty file can't shift the others):
#   psc   = `ps -Ao pid=,ppid=,comm=`
#   psa   = `ps -Ao pid=,command=`
#   panes = `tmux list-panes -a -F "$AIR_PANE_FORMAT"`:
#           pane_id pane_pid session window pane cur_cmd cur_path @ai_tool @ai_session_id @ai_pid
# Vars: enabled ("claude kiro"), claude_base, kiro_base, fallback ("on"/"off")
#
# Output, one tab-separated line per pane:
#   session window pane pane_pid cur_cmd cur_path tool tool_pid source id command first_child
# tool/tool_pid are empty when no enabled AI CLI runs in the pane's process subtree; source
# is "marker" or "argv" when a session id was found; command is what restore should run
# (a resume command, or a cold relaunch when there is no id); first_child is the argv of the
# pane process's first child — what resurrect's own ps strategy meant to record.
#
# How the session id is chosen:
#   1. The pane's @ai_session_id marker — stamped by the tool's prompt hook — but only if it
#      is live: @ai_pid (the CLI that stamped it) must still be running in this pane. A
#      marker left behind by a CLI that has since exited belongs to an older conversation.
#      (Markers from before @ai_pid existed are trusted while the tool is running.)
#   2. Otherwise the id on the running CLI's own command line (`claude --resume <id>`,
#      `kiro-cli chat --resume-id <id>`), i.e. a restored pane nobody has typed in since.
#   3. Otherwise no id: the pane is relaunched the way it is running now, without an id.
# The command is always rebuilt from the running CLI's own argv — not from what resurrect
# recorded, which is the pane's *direct child* (a shell under a pty wrapper) and, for a
# restored pane, carries the conversation id it was restored with — so stale --resume ids
# and first-prompt arguments are dropped and the user's flags are kept.

BEGIN {
    FS = "\t"; OFS = "\t"
    ntools = split(enabled, TOOLS, " ")
    RE["claude"] = "^claude$"
    RE["kiro"] = "^kiro-cli(-chat)?$"
    BASE["claude"] = claude_base == "" ? "claude" : claude_base
    BASE["kiro"] = kiro_base == "" ? "kiro-cli chat" : kiro_base
    # Claude options that never take a value, and those that take several.
    split("--allow-dangerously-skip-permissions --ax-screen-reader --bg --background --bare " \
          "--brief --chrome --dangerously-skip-permissions --disable-slash-commands " \
          "--exclude-dynamic-system-prompt-sections --forward-subagent-text -h --help --ide " \
          "--include-hook-events --include-partial-messages --no-chrome " \
          "--no-session-persistence --replay-user-messages --restricted --safe-mode " \
          "--strict-mcp-config --tmux --verbose -v --version", L, " ")
    for (i in L) BOOL["claude", L[i]] = 1
    split("--add-dir --allowedTools --allowed-tools --disallowedTools --disallowed-tools " \
          "--betas --file --mcp-config --tools", L, " ")
    for (i in L) VARIADIC["claude", L[i]] = 1
    split("-a --trust-all-tools --require-mcp-startup -h --help -V --version", L, " ")
    for (i in L) BOOL["kiro", L[i]] = 1
}

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function firstword(s) { sub(/[ \t].*/, "", s); return s }
function basename(s) { sub(/.*\//, "", s); return s }
function argv0(a) { a = basename(firstword(a)); sub(/^-/, "", a); return a }

FILENAME == psc {
    l = trim($0); pid = firstword(l); l = trim(substr(l, length(pid) + 1))
    pp = firstword(l); c = basename(trim(substr(l, length(pp) + 1)))
    comm[pid] = c
    kids[pp] = kids[pp] " " pid
    if (!(pp in firstkid)) firstkid[pp] = pid
    next
}
FILENAME == psa {
    l = trim($0); pid = firstword(l); args[pid] = trim(substr(l, length(pid) + 1))
    next
}
FILENAME == panes { plan_pane(); next }

function is_tool(pid, t) { return (pid in comm) && (comm[pid] ~ RE[t] || argv0(args[pid]) ~ RE[t]) }
function tool_enabled(t,    i) { for (i = 1; i <= ntools; i++) if (TOOLS[i] == t) return 1; return 0 }
# ids end up inside a shell command that restore types into the pane: allow nothing else
function safe_id(id) { return id ~ /^[A-Za-z0-9][A-Za-z0-9._:-]*$/ }
# (no {n} regex intervals: older mawk, the default awk on some distros, lacks them)
function is_uuid(id) {
    return length(id) == 36 && id ~ /^[0-9A-Fa-f-]+$/ && substr(id, 9, 1) == "-" &&
        substr(id, 14, 1) == "-" && substr(id, 19, 1) == "-" && substr(id, 24, 1) == "-" &&
        gsub(/-/, "-", id) == 4
}

# scan(root): breadth-first walk of root's process subtree. Sets INSUB[pid] for every
# member and TOP[tool] to the shallowest process of each enabled tool, so an interactive CLI
# wins over any copy of the tool it spawned, and wrappers above it are seen through.
function scan(root,    Q, h, t, x, n, K, i, j) {
    split("", INSUB); split("", TOP)
    h = 1; t = 1; Q[1] = root; INSUB[root] = 1
    while (h <= t) {
        x = Q[h++]
        for (i = 1; i <= ntools; i++) if (!(TOOLS[i] in TOP) && is_tool(x, TOOLS[i])) TOP[TOOLS[i]] = x
        n = split(kids[x], K, " ")
        for (j = 1; j <= n; j++) if (!(K[j] in INSUB)) { INSUB[K[j]] = 1; Q[++t] = K[j] }
    }
}

# argv_id(tool, argv): the session id a running CLI was started with, or "".
function argv_id(tool, a,    n, A, i, v, pinned) {
    n = split(a, A, " "); pinned = ""
    for (i = 2; i <= n; i++) {
        v = ""
        if (tool == "claude") {
            # -r/--resume also opens a picker with a search term, so only a UUID counts
            if ((A[i] == "--resume" || A[i] == "-r") && i < n) v = A[i + 1]
            else if (A[i] ~ /^--resume=/) v = substr(A[i], 10)
            else if (A[i] == "--session-id" && i < n && is_uuid(A[i + 1])) pinned = A[i + 1]
            else if (A[i] ~ /^--session-id=/ && is_uuid(substr(A[i], 14))) pinned = substr(A[i], 14)
            if (v != "" && is_uuid(v)) return v
        } else {
            if (A[i] == "--resume-id" && i < n) v = A[i + 1]
            else if (A[i] ~ /^--resume-id=/) v = substr(A[i], 13)
            if (v != "" && safe_id(v)) return v
        }
    }
    return pinned
}

# q(token): shell-quote a token unless it is plainly safe. (ps flattens argv, so an argument
# that contained spaces can't be recovered exactly — resurrect has the same limit — but a
# quoted token can never turn into shell syntax when restore types it into the pane.)
function q(t) {
    if (t ~ /^[A-Za-z0-9_@%+=:,.\/-]+$/) return t
    gsub(/'/, "'\\''", t)
    return "'" t "'"
}

# relaunch(tool, argv, keep_continue): the running CLI's command line minus everything that
# picks or forks a conversation (--resume/-r/--session-id/--fork-session, kiro --resume-id/
# --resume-picker; --continue/-c and kiro -r only when keep_continue is 0) and minus
# positional arguments — the first prompt, which already sits in the conversation and must
# not be sent again. Options and their values are kept.
function relaunch(tool, a, keep_continue,    n, A, i, t, out, start) {
    n = split(a, A, " ")
    if (n == 0) return BASE[tool]
    if (tool == "kiro") {
        if (A[2] != "chat") return BASE[tool]
        out = (basename(A[1]) == "kiro-cli-chat" ? "kiro-cli" : q(A[1])) " chat"; start = 3
    } else {
        out = q(A[1]); start = 2
    }
    for (i = start; i <= n; i++) {
        t = A[i]
        if (t == "--") break
        if (tool == "claude") {
            if (t == "--resume" || t == "-r" || t == "--session-id") { if (i < n && A[i + 1] !~ /^-/) i++; continue }
            if (t ~ /^--(resume|session-id)=/ || t == "--fork-session" || t == "-p" || t == "--print") continue
            if (t == "-c" || t == "--continue") { if (keep_continue) out = out " " t; continue }
        } else {
            if (t == "--resume-id" || t == "-d" || t == "--delete-session") { if (i < n && A[i + 1] !~ /^-/) i++; continue }
            if (t ~ /^--(resume-id|delete-session)=/) continue
            if (t == "--resume-picker" || t == "-l" || t == "--list-sessions" || t == "--list-models" || t == "--no-interactive") continue
            if (t == "-r" || t == "--resume") { if (keep_continue) out = out " " t; continue }
        }
        if (t !~ /^-/) continue                       # positional: the first prompt
        out = out " " q(t)
        if (t ~ /=/ || ((tool, t) in BOOL)) continue
        if ((tool, t) in VARIADIC) { while (i < n && A[i + 1] !~ /^-/) out = out " " q(A[++i]); continue }
        if (i < n && A[i + 1] !~ /^-/) out = out " " q(A[++i])   # the option's value
    }
    return out
}

function build(tool, a, id,    base) {
    if (id == "") return relaunch(tool, a, 1)
    base = relaunch(tool, a, 0)
    return base " " (tool == "kiro" ? "--resume-id" : "--resume") " " id (fallback == "off" ? "" : " || " base)
}

function plan_pane(    pane_pid, mtool, mid, mpid, tool, tpid, src, id, live, i, cmd, child) {
    pane_pid = $2; mtool = $8; mid = $9; mpid = $10
    scan(pane_pid)
    tool = ""; tpid = ""; src = ""; id = ""
    if (mid != "" && tool_enabled(mtool) && safe_id(mid)) {
        if (mpid != "") live = (mpid in INSUB) && is_tool(mpid, mtool)
        else live = (mtool in TOP)
        if (live) { tool = mtool; tpid = (mpid != "" ? mpid : TOP[mtool]); src = "marker"; id = mid }
    }
    if (tool == "") {
        for (i = 1; i <= ntools; i++) {
            if (!(TOOLS[i] in TOP)) continue
            tool = TOOLS[i]; tpid = TOP[tool]; id = argv_id(tool, args[tpid])
            if (id != "") src = "argv"
            break
        }
    }
    cmd = (tool == "" ? "" : build(tool, args[tpid], id))
    child = (pane_pid in firstkid) ? args[firstkid[pane_pid]] : ""
    gsub(/\t/, " ", child)
    print $3, $4, $5, pane_pid, $6, $7, tool, tpid, src, id, cmd, child
}
