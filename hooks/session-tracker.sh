#!/usr/bin/env bash
# SessionStart hook: record claude PID → session mapping
# Registry: ~/.claude/.session_pids
# Format per line: <pid>:<session_id>:<agent_id>:<project_dir>
#   agent_id is empty for main sessions, set for worktree/background subagents
#
# Requires: bash 3.2+, jq
set -euo pipefail

REGISTRY="${CLAUDE_HOME:-$HOME/.claude}/.session_pids"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
AGENT_ID=$(echo "$INPUT"   | jq -r '.agent_id // empty' 2>/dev/null)

[[ -z "$SESSION_ID" ]] && exit 0

# $PPID is the claude process that spawned this hook shell
CLAUDE_PID="$PPID"

touch "$REGISTRY"

echo "${CLAUDE_PID}:${SESSION_ID}:${AGENT_ID}:${PROJECT_DIR}" >> "$REGISTRY"

# Prune stale entries: PID dead or no longer a claude process
TMPFILE=$(mktemp)
while IFS= read -r line; do
    pid="${line%%:*}"
    comm=$(ps -p "$pid" -o comm= 2>/dev/null) || continue
    [[ "$comm" == *claude* ]] && echo "$line"
done < "$REGISTRY" > "$TMPFILE"
mv "$TMPFILE" "$REGISTRY"

exit 0
