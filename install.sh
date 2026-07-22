#!/usr/bin/env bash
# install.sh — bootstrap tmux-ai-sessions-restore in one command:
#
#   curl -fsSL https://raw.githubusercontent.com/harnessed-ai/tmux-ai-sessions-restore/main/install.sh | bash
#
# What it does:
#   1. Clones the repo into ~/.tmux/plugins/ (skips if already present)
#   2. Splices the plugin line into your tmux config at the right slot
#      (after tmux-resurrect, before tmux-continuum)
#      Works with both TPM (@plugin) and direct (run-shell) config styles.

set -euo pipefail

REPO='https://github.com/harnessed-ai/tmux-ai-sessions-restore.git'
PLUGIN_DIR="${TMUX_PLUGIN_DIR:-$HOME/.tmux/plugins}/tmux-ai-sessions-restore"
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

# ── splice the plugin line into the tmux config ───────────────────────────────

TMUX_PLUGIN_DIR="${TMUX_PLUGIN_DIR:-$HOME/.tmux/plugins}" \
    bash "$PLUGIN_DIR/scripts/install_tpm.sh"
