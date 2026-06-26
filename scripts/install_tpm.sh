#!/usr/bin/env bash
# install_tpm.sh — insert the @plugin line for tmux-ai-sessions-restore into
# ~/.tmux.conf at the right slot: after tmux-resurrect, before tmux-continuum.
#
# Idempotent — safe to re-run; exits cleanly if the plugin is already present.
# Supports a TMUX_CONF env-var override for testing.

set -euo pipefail

PLUGIN='bmohan01/tmux-ai-sessions-restore'
PLUGIN_LINE="set -g @plugin '$PLUGIN'"
CONF="${TMUX_CONF:-$HOME/.tmux.conf}"

die()  { echo "✗ $*" >&2; exit 1; }
warn() { echo "⚠  $*" >&2; }
ok()   { echo "✓ $*"; }
info() { echo "• $*"; }

# ── preflight ────────────────────────────────────────────────────────────────

[ -f "$CONF" ] || die "$CONF not found. Create it first (touch $CONF)."

if grep -qF "$PLUGIN" "$CONF"; then
    ok "$PLUGIN already in $CONF — nothing to do."
    exit 0
fi

# ── locate anchor lines ───────────────────────────────────────────────────────

# Match the @plugin lines loosely — allow single or double quotes, any spacing.
# || true: grep exits 1 on no match; with pipefail that would abort the script.
resurrect_line=$(grep -n "tmux-plugins/tmux-resurrect" "$CONF" | head -1 | cut -d: -f1 || true)
continuum_line=$(grep -n "tmux-plugins/tmux-continuum" "$CONF"  | head -1 | cut -d: -f1 || true)

# ── decide where to insert ────────────────────────────────────────────────────

insert_after=""    # line number after which we insert (empty = prepend)
insert_before=""   # line number before which we insert (fallback strategy)

if [ -n "$resurrect_line" ] && [ -n "$continuum_line" ]; then
    if [ "$resurrect_line" -lt "$continuum_line" ]; then
        # Normal: resurrect ... continuum — slot in between
        insert_after="$resurrect_line"
    else
        # Unusual: continuum appears before resurrect — insert before continuum and warn
        warn "tmux-continuum (line $continuum_line) appears before tmux-resurrect (line $resurrect_line)."
        warn "Inserting $PLUGIN before tmux-continuum. Consider reordering resurrect first."
        insert_before="$continuum_line"
    fi
elif [ -n "$resurrect_line" ]; then
    info "tmux-continuum not found — inserting after tmux-resurrect."
    info "Add tmux-continuum after $PLUGIN for the full auto-restore experience."
    insert_after="$resurrect_line"
elif [ -n "$continuum_line" ]; then
    info "tmux-resurrect not found — inserting before tmux-continuum."
    info "Add tmux-resurrect before $PLUGIN; it is required for this plugin to work."
    insert_before="$continuum_line"
else
    # Last resort: insert before the TPM run line; if that's absent too, append.
    tpm_run_line=$(grep -n "run.*tpm/tpm" "$CONF" | head -1 | cut -d: -f1 || true)
    if [ -n "$tpm_run_line" ]; then
        info "Neither tmux-resurrect nor tmux-continuum found — inserting before the TPM run line."
        info "$PLUGIN requires tmux-resurrect (and optionally tmux-continuum) to work."
        insert_before="$tpm_run_line"
    else
        info "Neither tmux-resurrect, tmux-continuum, nor a TPM run line found — appending."
        info "$PLUGIN requires tmux-resurrect (and optionally tmux-continuum) to work."
        printf '\n%s\n' "$PLUGIN_LINE" >> "$CONF"
        ok "Appended to $CONF:"
        echo "  $PLUGIN_LINE"
        echo
        echo "Run 'prefix + I' in tmux to install."
        exit 0
    fi
fi

# ── splice the line in ────────────────────────────────────────────────────────

tmp=$(mktemp)
if [ -n "$insert_after" ]; then
    awk -v n="$insert_after" -v new="$PLUGIN_LINE" '
        NR == n { print; print new; next }
        { print }
    ' "$CONF" > "$tmp"
else
    awk -v n="$insert_before" -v new="$PLUGIN_LINE" '
        NR == n { print new; print; next }
        { print }
    ' "$CONF" > "$tmp"
fi
mv "$tmp" "$CONF"

ok "Updated $CONF:"
echo "  $PLUGIN_LINE"
echo
echo "Run 'prefix + I' in tmux to install, or restart tmux."
