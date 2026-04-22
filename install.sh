#!/usr/bin/env bash
# install.sh — claude-session-df installer
#
# Installs:
#   ~/.claude/clean-sessions.sh
#   ~/.claude/hooks/session-tracker.sh
#   ~/.claude/skills/session_df/SKILL.md
#   Patches ~/.claude/settings.json with the SessionStart hook
#
# Requirements: bash 3.2+, jq, claude CLI

set -euo pipefail

CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── colours ────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; RESET=''
fi

info()  { echo -e "${GREEN}✓${RESET} $*"; }
warn()  { echo -e "${YELLOW}!${RESET} $*"; }
error() { echo -e "${RED}✗${RESET} $*" >&2; }
die()   { error "$*"; exit 1; }

# ── preflight ──────────────────────────────────────────────────────────────

preflight() {
    local ok=1

    echo "Checking requirements..."

    if ! command -v jq &>/dev/null; then
        error "jq not found. Install via: brew install jq  (macOS) or  apt install jq  (Linux)"
        ok=0
    else
        info "jq $(jq --version)"
    fi

    if ! command -v claude &>/dev/null; then
        error "claude CLI not found. Install from: https://claude.ai/download"
        ok=0
    else
        info "claude $(claude --version 2>/dev/null | head -1 || echo '(version unknown)')"
    fi

    [[ $ok -eq 1 ]] || die "Fix the above issues then re-run install.sh"
}

# ── copy files ─────────────────────────────────────────────────────────────

install_files() {
    echo ""
    echo "Installing files to $CLAUDE_DIR..."

    # clean-sessions.sh
    cp "$REPO_DIR/clean-sessions.sh" "$CLAUDE_DIR/clean-sessions.sh"
    chmod +x "$CLAUDE_DIR/clean-sessions.sh"
    info "clean-sessions.sh → $CLAUDE_DIR/clean-sessions.sh"

    # session-tracker hook
    mkdir -p "$CLAUDE_DIR/hooks"
    cp "$REPO_DIR/hooks/session-tracker.sh" "$CLAUDE_DIR/hooks/session-tracker.sh"
    chmod +x "$CLAUDE_DIR/hooks/session-tracker.sh"
    info "session-tracker.sh → $CLAUDE_DIR/hooks/session-tracker.sh"

    # skill
    mkdir -p "$CLAUDE_DIR/skills/session_df"
    cp "$REPO_DIR/skills/session_df/SKILL.md" "$CLAUDE_DIR/skills/session_df/SKILL.md"
    info "SKILL.md → $CLAUDE_DIR/skills/session_df/SKILL.md"
}

# ── patch settings.json ────────────────────────────────────────────────────

patch_settings() {
    local settings="$CLAUDE_DIR/settings.json"
    echo ""
    echo "Patching $settings..."

    # Create settings.json if absent
    if [[ ! -f "$settings" ]]; then
        echo '{}' > "$settings"
        warn "Created new settings.json"
    fi

    # Check if hook already present
    if jq -e '
        .hooks.SessionStart[]?.hooks[]?
        | select(.command and (.command | contains("session-tracker.sh")))
    ' "$settings" &>/dev/null; then
        info "SessionStart hook already present — skipping patch"
        return
    fi

    # Backup
    cp "$settings" "${settings}.bak"
    info "Backed up settings.json → settings.json.bak"

    # Merge hook entry
    local hook_json
    hook_json=$(jq -n \
        --arg cmd "bash ${CLAUDE_DIR}/hooks/session-tracker.sh" \
        '{hooks:{SessionStart:[{hooks:[{type:"command",command:$cmd,timeout:5}]}]}}'
    )

    # Deep-merge: if hooks.SessionStart exists, append; otherwise create
    local tmp; tmp=$(mktemp)
    jq --argjson new "$hook_json" '
        if (.hooks.SessionStart | type) == "array" then
            .hooks.SessionStart += $new.hooks.SessionStart
        else
            .hooks.SessionStart = $new.hooks.SessionStart
        end
    ' "$settings" > "$tmp"
    mv "$tmp" "$settings"

    info "SessionStart hook added to settings.json"
}

# ── main ───────────────────────────────────────────────────────────────────

echo "=== claude-session-df installer ==="
echo ""
preflight
install_files
patch_settings

echo ""
echo "=== Done ==="
echo ""
echo "Restart Claude Code for the SessionStart hook to take effect."
echo "Then use /session_df in any Claude Code session."
