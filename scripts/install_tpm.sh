#!/usr/bin/env bash
# install_tpm.sh — insert tmux-ai-sessions-restore into your tmux config at the
# right slot: after tmux-resurrect, before tmux-continuum.
#
# Handles both TPM (@plugin) and direct (run-shell) config styles automatically.
# Auto-detects ~/.tmux.conf or ~/.config/tmux/tmux.conf (XDG). Override with TMUX_CONF.
# Idempotent — safe to re-run; exits cleanly if the plugin is already present.

set -euo pipefail

PLUGIN='bmohan01/tmux-ai-sessions-restore'
PLUGIN_DIR="${TMUX_PLUGIN_DIR:-$HOME/.tmux/plugins}/tmux-ai-sessions-restore"

die()  { echo "✗ $*" >&2; exit 1; }
warn() { echo "⚠  $*" >&2; }
ok()   { echo "✓ $*"; }
info() { echo "• $*"; }

# ── resolve config path ───────────────────────────────────────────────────────

if [ -n "${TMUX_CONF:-}" ]; then
    CONF="$TMUX_CONF"
elif [ -f "$HOME/.tmux.conf" ]; then
    CONF="$HOME/.tmux.conf"
elif [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf" ]; then
    CONF="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"
else
    CONF="$HOME/.tmux.conf"
fi

[ -f "$CONF" ] || die "$CONF not found. Create it first (touch $CONF)."

# ── idempotency check ─────────────────────────────────────────────────────────

if grep -qF "tmux-ai-sessions-restore" "$CONF"; then
    ok "tmux-ai-sessions-restore already in $CONF — nothing to do."
    exit 0
fi

# ── detect config style: TPM (@plugin) or direct (run-shell) ─────────────────

if grep -qE "run[[:space:]]+'?~/.tmux/plugins/tpm/tpm'?" "$CONF" || \
   grep -q "@plugin" "$CONF"; then
    # TPM style — insert @plugin line; user runs prefix+I to activate
    PLUGIN_LINE="set -g @plugin '$PLUGIN'"
    FINISH_MSG="Run 'prefix + I' in tmux to install."
else
    # Direct style — insert a run-shell line pointing at the cloned plugin
    PLUGIN_LINE="run-shell '$PLUGIN_DIR/ai_sessions_restore.tmux'"
    FINISH_MSG="Source your config or restart tmux to activate: tmux source '$CONF'"
fi

# ── locate anchor lines ───────────────────────────────────────────────────────

# Match both @plugin and run-shell references to resurrect/continuum.
# || true: grep exits 1 on no match; with pipefail that would abort the script.
resurrect_line=$(grep -n "tmux-resurrect" "$CONF" | head -1 | cut -d: -f1 || true)
continuum_line=$(grep -n "tmux-continuum" "$CONF"  | head -1 | cut -d: -f1 || true)

# ── decide where to insert ────────────────────────────────────────────────────

insert_after=""
insert_before=""

if [ -n "$resurrect_line" ] && [ -n "$continuum_line" ]; then
    if [ "$resurrect_line" -lt "$continuum_line" ]; then
        insert_after="$resurrect_line"
    else
        warn "tmux-continuum (line $continuum_line) appears before tmux-resurrect (line $resurrect_line)."
        warn "Inserting before tmux-continuum. Consider reordering resurrect first."
        insert_before="$continuum_line"
    fi
elif [ -n "$resurrect_line" ]; then
    info "tmux-continuum not found — inserting after tmux-resurrect."
    info "Add tmux-continuum after this plugin for the full auto-restore experience."
    insert_after="$resurrect_line"
elif [ -n "$continuum_line" ]; then
    info "tmux-resurrect not found — inserting before tmux-continuum."
    info "Add tmux-resurrect before this plugin; it is required for this plugin to work."
    insert_before="$continuum_line"
else
    tpm_run_line=$(grep -n "run.*tpm/tpm" "$CONF" | head -1 | cut -d: -f1 || true)
    if [ -n "$tpm_run_line" ]; then
        info "Neither tmux-resurrect nor tmux-continuum found — inserting before the TPM run line."
        info "This plugin requires tmux-resurrect (and optionally tmux-continuum) to work."
        insert_before="$tpm_run_line"
    else
        info "Neither tmux-resurrect nor tmux-continuum found — appending."
        info "This plugin requires tmux-resurrect (and optionally tmux-continuum) to work."
        printf '\n%s\n' "$PLUGIN_LINE" >> "$CONF"
        ok "Appended to $CONF:"
        echo "  $PLUGIN_LINE"
        echo
        echo "$FINISH_MSG"
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
echo "$FINISH_MSG"
