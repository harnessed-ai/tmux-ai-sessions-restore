# tools.awk — loads tools.tsv for plan.awk and rewrite.awk, which include it first:
#   awk -v tools=scripts/tools.tsv [-v bases=...] -f tools.awk -f plan.awk ...
#
# Vars:
#   tools  path to tools.tsv (required)
#   bases  optional per-tool launch-command overrides: "tool=command" entries separated by
#          "\034" (from @ai-restore-<tool>-command); an empty or unknown entry is ignored
#
# Sets, per tool t: RE[t] BASE[t] RESUME[t] IDFLAGS[t] PINFLAGS[t] IDFMT[t] MATCH[t]
# ONESHOT[t] (see tools.tsv for the columns; "-" cells become ""), and ALL[1..NT], the
# tools in table order.

function air_none(s) { return s == "-" ? "" : s }
function basename(s) { sub(/.*\//, "", s); return s }
function firstword(s) { sub(/[ \t].*/, "", s); return s }
function argv0(a) { a = basename(firstword(a)); sub(/^-/, "", a); return a }

# air_is_cli(t, comm, args): is this process tool t's CLI? Matched against the basename of
# comm and of argv[0], and for a node/bun process its script (first non-option argument), so
# a JS CLI is seen whatever its process title. capture_session.sh applies the same rule.
function air_is_cli(t, c, a,    p, n, A, i) {
    if (!(t in RE)) return 0
    c = basename(c); sub(/^-/, "", c)
    if (c ~ RE[t]) return 1
    p = argv0(a)
    if (p ~ RE[t]) return 1
    if (p ~ /^(node|nodejs|bun)$/) {
        n = split(a, A, " ")
        for (i = 2; i <= n; i++) if (A[i] !~ /^-/) return basename(A[i]) ~ RE[t]
    }
    return 0
}

# air_is_oneshot(t, args): is this command line a non-interactive run of tool t (its oneshot
# column)? A flag counts anywhere; a bare word only as the subcommand, the word right after
# the program (after the script, for node/bun). Same rule as air_is_oneshot in helpers.sh.
function air_is_oneshot(t, a,    n, A, i, F, k, j, sc) {
    if (ONESHOT[t] == "") return 0
    n = split(a, A, " "); i = 2
    if (basename(A[1]) ~ /^(node|nodejs|bun)$/) { while (i <= n && A[i] ~ /^-/) i++; i++ }
    sc = (i <= n) ? A[i] : ""
    k = split(ONESHOT[t], F, ",")
    for (j = 1; j <= k; j++) {
        if (F[j] ~ /^-/) { for (i = 2; i <= n; i++) if (A[i] == F[j]) return 1 }
        else if (F[j] == sc) return 1
    }
    return 0
}

BEGIN {
    if (tools == "") { print "tools.awk: -v tools=<path to tools.tsv> is required" > "/dev/stderr"; exit 2 }
    NT = 0
    while ((getline _l < tools) > 0) {
        if (_l ~ /^[ \t]*(#|$)/) continue
        if (split(_l, _f, "\t") < 9) continue
        _t = _f[1]; ALL[++NT] = _t
        RE[_t] = _f[2]; BASE[_t] = _f[3]; RESUME[_t] = _f[4]
        IDFLAGS[_t] = air_none(_f[5]); PINFLAGS[_t] = air_none(_f[6]); IDFMT[_t] = _f[7]
        MATCH[_t] = _f[8]; ONESHOT[_t] = air_none(_f[9])
    }
    close(tools)
    if (NT == 0) { print "tools.awk: no tools in " tools > "/dev/stderr"; exit 2 }
    _n = split(bases, _b, "\034")
    for (_i = 1; _i <= _n; _i++) {
        _k = index(_b[_i], "=")
        if (_k > 1) {
            _t = substr(_b[_i], 1, _k - 1)
            if ((_t in BASE) && substr(_b[_i], _k + 1) != "") BASE[_t] = substr(_b[_i], _k + 1)
        }
    }
}
