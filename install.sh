#!/usr/bin/env bash
# install.sh — bootstrap tmux-ai-sessions-restore in one command:
#
#   curl -fsSL https://raw.githubusercontent.com/bmohan01/tmux-ai-sessions-restore/main/install.sh | bash
#
# What it does:
#   1. Clones the repo into ~/.tmux/plugins/ (skips if already present)
#   2. Splices the @plugin line into ~/.tmux.conf at the right slot
#      (after tmux-resurrect, before tmux-continuum)
#
# After this, run  prefix + I  inside tmux to let TPM finish the install.

set -euo pipefail

REPO='https://github.com/bmohan01/tmux-ai-sessions-restore.git'
PLUGIN_DIR="${TMUX_PLUGIN_DIR:-$HOME/.tmux/plugins}/tmux-ai-sessions-restore"
CONF="${TMUX_CONF:-$HOME/.tmux.conf}"

ok()   { echo "✓ $*"; }
info() { echo "• $*"; }
die()  { echo "✗ $*" >&2; exit 1; }

# ── preflight ─────────────────────────────────────────────────────────────────

command -v git >/dev/null 2>&1 || die "git is required but not found on PATH."

# ── clone or update ───────────────────────────────────────────────────────────

if [ -d "$PLUGIN_DIR/.git" ]; then
    ok "Repo already at $PLUGIN_DIR — pulling latest."
    git -C "$PLUGIN_DIR" pull --ff-only --quiet
else
    info "Cloning into $PLUGIN_DIR …"
    mkdir -p "$(dirname "$PLUGIN_DIR")"
    git clone --depth 1 --quiet "$REPO" "$PLUGIN_DIR"
    ok "Cloned."
fi

# ── splice the @plugin line into ~/.tmux.conf ─────────────────────────────────

bash "$PLUGIN_DIR/scripts/install_tpm.sh"

# ── done ──────────────────────────────────────────────────────────────────────

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  One step left: open tmux and press  prefix + I"
echo "  TPM will install the plugin and register the hooks."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
