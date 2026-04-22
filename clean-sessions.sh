#!/usr/bin/env bash
# Clean up Claude Code session files from ~/.claude/
# Usage:
#   clean-sessions.sh list                         # list session IDs found (marks running/current)
#   clean-sessions.sh current                      # print current session ID
#   clean-sessions.sh running [--with-agents]      # list running session IDs
#   clean-sessions.sh delete <id> [<id>…]          # delete specific sessions
#   clean-sessions.sh delete --all                 # delete ALL session data
#   clean-sessions.sh delete --all --keep <id>     # delete all except <id>
#   clean-sessions.sh delete --all --keep-running  # delete all except live sessions
#
# "Live" = any PID in registry for that session (main or agent/worktree) is alive.
# Worktree dirs recorded in registry are cleaned alongside their session.
#
# Requires: bash 3.2+, jq, ps

set -euo pipefail
shopt -s nullglob

CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
CACHE_DIRS=(todos debug paste-cache file-history)
if [[ "$(uname)" == "Darwin" ]]; then
    TMP_BASE="/private/tmp/claude-$(id -u)"
else
    TMP_BASE="/tmp/claude-$(id -u)"
fi
REGISTRY="$CLAUDE_DIR/.session_pids"

# ── helpers ────────────────────────────────────────────────────────────────

get_project_dirs() {
    for d in "$CLAUDE_DIR"/projects/*/; do
        [[ -d "$d" ]] && echo "$d"
    done
}

# Parse registry line into _pid _session_id _agent_id _proj_dir
# Format: <pid>:<session_id>:<agent_id>:<project_dir>  (agent_id may be empty)
parse_registry_line() {
    local line="$1"
    _pid="${line%%:*}";          line="${line#*:}"
    _session_id="${line%%:*}";   line="${line#*:}"
    _agent_id="${line%%:*}";     line="${line#*:}"
    _proj_dir="$line"
}

# True if pid exists AND belongs to a claude process
is_claude_pid() {
    local pid="$1"
    [[ -z "$pid" ]] && return 1
    local comm
    comm=$(ps -p "$pid" -o comm= 2>/dev/null) || return 1
    [[ "$comm" == *claude* ]]
}

# Convert absolute path to ~/.claude/projects slug (e.g. /a/b/c → -a-b-c)
path_to_slug() {
    echo "${1//\//-}"
}

# Reverse lines of a file — portable (no tail -r / tac dependency)
reverse_file() {
    awk '{lines[NR]=$0} END{for(i=NR;i>=1;i--) print lines[i]}' "$1"
}

# ── liveness ───────────────────────────────────────────────────────────────

# True if ANY pid associated with session_id (main or agent) is still alive.
is_session_live() {
    local session_id="$1"
    [[ -f "$REGISTRY" ]] || return 1
    while IFS= read -r line; do
        parse_registry_line "$line"
        [[ "$_session_id" == "$session_id" ]] || continue
        is_claude_pid "$_pid" && return 0
    done < "$REGISTRY"
    return 1
}

# Returns session IDs whose main-session PID is alive.
get_running_sessions() {
    [[ -f "$REGISTRY" ]] || return 0
    local seen=()
    while IFS= read -r line; do
        parse_registry_line "$line"
        [[ -z "$_pid" || -z "$_session_id" || -n "$_agent_id" ]] && continue
        if is_claude_pid "$_pid"; then
            local dup=0
            for s in "${seen[@]:-}"; do [[ "$s" == "$_session_id" ]] && dup=1 && break; done
            [[ $dup -eq 0 ]] && { seen+=("$_session_id"); echo "$_session_id"; }
        fi
    done < "$REGISTRY"
}

# Returns running agent_ids for a given session_id.
get_running_agents_for_session() {
    local target_session="$1"
    [[ -f "$REGISTRY" ]] || return 0
    local seen=()
    while IFS= read -r line; do
        parse_registry_line "$line"
        [[ -z "$_pid" || -z "$_agent_id" || "$_session_id" != "$target_session" ]] && continue
        if is_claude_pid "$_pid"; then
            local dup=0
            for s in "${seen[@]:-}"; do [[ "$s" == "$_agent_id" ]] && dup=1 && break; done
            [[ $dup -eq 0 ]] && { seen+=("$_agent_id"); echo "$_agent_id"; }
        fi
    done < "$REGISTRY"
}

# Returns the running main session for the given project dir (CWD by default).
get_current_session() {
    local target_dir="${1:-$PWD}"
    [[ -f "$REGISTRY" ]] || return 0
    while IFS= read -r line; do
        parse_registry_line "$line"
        [[ -z "$_pid" || -z "$_session_id" || -n "$_agent_id" ]] && continue
        if is_claude_pid "$_pid"; then
            if [[ "$_proj_dir" == "$target_dir" || "$_proj_dir" == "$target_dir"/* ]]; then
                echo "$_session_id"
                return 0
            fi
        fi
    done < <(reverse_file "$REGISTRY")
}

# ── worktree helpers ────────────────────────────────────────────────────────

# Emit "<session_id> <worktree_dir>" for every agent entry in registry
# whose session is NOT live (safe to clean).
get_stale_worktree_dirs() {
    [[ -f "$REGISTRY" ]] || return 0
    local seen=()
    while IFS= read -r line; do
        parse_registry_line "$line"
        [[ -z "$_agent_id" || -z "$_proj_dir" ]] && continue
        [[ -d "$_proj_dir" ]] || continue
        is_session_live "$_session_id" && continue
        local dup=0
        for s in "${seen[@]:-}"; do [[ "$s" == "$_proj_dir" ]] && dup=1 && break; done
        [[ $dup -eq 0 ]] && { seen+=("$_proj_dir"); echo "$_session_id $_proj_dir"; }
    done < "$REGISTRY"
}

# Delete a worktree dir and its ~/.claude/projects slug.
delete_worktree_dir() {
    local session_id="$1"
    local wt_dir="$2"
    local count=0

    if [[ -d "$wt_dir" ]]; then
        local n; n=$(find "$wt_dir" -type f 2>/dev/null | wc -l)
        count=$((count + n))
        rm -rf "$wt_dir"
        local git_file="$wt_dir/.git"
        if [[ -f "$git_file" ]]; then
            local git_common
            git_common=$(sed -n 's/^gitdir: //p' "$git_file" 2>/dev/null || true)
            local main_repo
            main_repo=$(dirname "${git_common%%/worktrees/*}" 2>/dev/null || true)
            if [[ -d "$main_repo" ]]; then
                git -C "$main_repo" worktree prune 2>/dev/null || true
            fi
        fi
    fi

    local slug; slug=$(path_to_slug "$wt_dir")
    local proj_dir="$CLAUDE_DIR/projects/$slug"
    if [[ -d "$proj_dir" ]]; then
        local n; n=$(find "$proj_dir" -type f 2>/dev/null | wc -l)
        count=$((count + n))
        rm -rf "$proj_dir"
    fi

    [[ $count -gt 0 ]] && echo "  worktree $wt_dir: removed $count file(s)"
}

# ── list ───────────────────────────────────────────────────────────────────

list_sessions() {
    local ids=()

    for f in "$CLAUDE_DIR"/todos/*.json; do
        [[ -f "$f" ]] || continue
        local base; base=$(basename "$f" .json)
        ids+=("${base%%-agent-*}")
    done

    for f in "$CLAUDE_DIR"/debug/*.txt; do
        [[ -f "$f" ]] || continue
        ids+=("$(basename "$f" .txt)")
    done

    for f in "$CLAUDE_DIR"/file-history/*/*@*; do
        [[ -f "$f" ]] || continue
        local base; base=$(basename "$f")
        ids+=("${base%%@*}")
    done

    while IFS= read -r proj_dir; do
        for f in "$proj_dir"*.jsonl; do
            [[ -f "$f" ]] || continue
            ids+=("$(basename "$f" .jsonl)")
        done
        for d in "$proj_dir"*/; do
            [[ -d "$d" ]] || continue
            local base; base=$(basename "$d")
            [[ "$base" == "memory" ]] && continue
            ids+=("$base")
        done
    done < <(get_project_dirs)

    if [[ -d "$TMP_BASE" ]]; then
        for d in "$TMP_BASE"/*/*/; do
            [[ -d "$d" ]] && ids+=("$(basename "$d")")
        done
    fi

    [[ ${#ids[@]} -eq 0 ]] && return

    local unique=()
    while IFS= read -r line; do unique+=("$line"); done < <(printf '%s\n' "${ids[@]}" | sort -u)

    local running_ids=() current_id
    while IFS= read -r line; do running_ids+=("$line"); done < <(get_running_sessions)
    current_id=$(get_current_session "$PWD")

    for id in "${unique[@]}"; do
        local label=""
        for r in "${running_ids[@]:-}"; do
            if [[ "$r" == "$id" ]]; then label=" [running]"; break; fi
        done
        [[ -n "$current_id" && "$id" == "$current_id" ]] && label=" [current]"
        local agents=()
        while IFS= read -r line; do agents+=("$line"); done < <(get_running_agents_for_session "$id")
        [[ ${#agents[@]} -gt 0 ]] && label="${label} [agents: ${agents[*]}]"
        echo "${id}${label}"
    done
}

# ── delete helpers ─────────────────────────────────────────────────────────

delete_tmp_session() {
    local id="$1"
    local count=0
    for d in "$TMP_BASE"/*/"$id"/; do
        [[ -d "$d" ]] || continue
        local n; n=$(find "$d" -type f 2>/dev/null | wc -l)
        count=$((count + n))
        rm -rf "$d"
    done
    [[ $count -gt 0 ]] && echo "  tmp $id: removed $count file(s)"
}

delete_session() {
    local id="$1"
    local force="${2:-}"

    if [[ -z "$force" ]] && is_session_live "$id"; then
        echo "  WARNING: session $id has live processes — skipping (use --force to override)" >&2
        return 1
    fi

    local count=0

    for f in "$CLAUDE_DIR"/todos/"$id"-*.json; do
        [[ -f "$f" ]] && rm -f "$f" && { ((count++)) || true; }
    done

    [[ -f "$CLAUDE_DIR/debug/$id.txt" ]] && rm -f "$CLAUDE_DIR/debug/$id.txt" && { ((count++)) || true; }

    for f in "$CLAUDE_DIR"/file-history/*/"$id"@*; do
        [[ -f "$f" ]] && rm -f "$f" && { ((count++)) || true; }
    done
    for d in "$CLAUDE_DIR"/file-history/*/; do
        [[ -d "$d" ]] && rmdir "$d" 2>/dev/null || true
    done

    while IFS= read -r proj_dir; do
        if [[ -f "$proj_dir$id.jsonl" ]]; then
            rm -f "$proj_dir$id.jsonl" && { ((count++)) || true; }
        fi
        if [[ -d "$proj_dir$id" ]]; then
            local n; n=$(find "$proj_dir$id" -type f 2>/dev/null | wc -l)
            count=$((count + n))
            rm -rf "$proj_dir$id"
        fi
    done < <(get_project_dirs)

    echo "  $id: removed $count file(s)"
    delete_tmp_session "$id"
}

delete_all() {
    local keep="${1:-}"
    local keep_running="${2:-}"

    local keep_ids=()
    [[ -n "$keep" ]] && keep_ids+=("$keep")
    if [[ "$keep_running" == "1" ]]; then
        if [[ -f "$REGISTRY" ]]; then
            local all_sids=()
            while IFS= read -r line; do
                parse_registry_line "$line"
                [[ -z "$_session_id" ]] && continue
                local dup=0
                for s in "${all_sids[@]:-}"; do [[ "$s" == "$_session_id" ]] && dup=1 && break; done
                [[ $dup -eq 0 ]] && all_sids+=("$_session_id")
            done < "$REGISTRY"
            for sid in "${all_sids[@]:-}"; do
                is_session_live "$sid" && keep_ids+=("$sid")
            done
        fi
    fi

    is_kept() {
        local id="$1"
        for k in "${keep_ids[@]:-}"; do [[ "$k" == "$id" ]] && return 0; done
        return 1
    }

    local count=0

    for dir in "${CACHE_DIRS[@]}"; do
        local target="$CLAUDE_DIR/$dir"
        [[ -d "$target" ]] || continue
        if [[ ${#keep_ids[@]} -eq 0 ]]; then
            count=$(( count + $(find "$target" -type f 2>/dev/null | wc -l) ))
            rm -rf "$target"/*
        else
            while IFS= read -r f; do
                local skip=0
                for k in "${keep_ids[@]}"; do
                    [[ "$(basename "$f")" == *"$k"* ]] && skip=1 && break
                done
                [[ $skip -eq 0 ]] && rm -f "$f" && { ((count++)) || true; }
            done < <(find "$target" -type f 2>/dev/null)
            find "$target" -type d -empty -delete 2>/dev/null || true
        fi
    done

    while IFS= read -r proj_dir; do
        for f in "$proj_dir"*.jsonl; do
            [[ -f "$f" ]] || continue
            local base; base=$(basename "$f" .jsonl)
            is_kept "$base" && continue
            rm -f "$f" && { ((count++)) || true; }
        done
        for d in "$proj_dir"*/; do
            [[ -d "$d" ]] || continue
            local base; base=$(basename "$d")
            [[ "$base" == "memory" ]] && continue
            is_kept "$base" && continue
            local n; n=$(find "$d" -type f 2>/dev/null | wc -l)
            count=$((count + n))
            rm -rf "$d"
        done
    done < <(get_project_dirs)

    if [[ -d "$TMP_BASE" ]]; then
        for proj in "$TMP_BASE"/*/; do
            for d in "$proj"*/; do
                [[ -d "$d" ]] || continue
                local base; base=$(basename "$d")
                is_kept "$base" && continue
                local n; n=$(find "$d" -type f 2>/dev/null | wc -l)
                count=$((count + n))
                rm -rf "$d"
            done
        done
    fi

    while IFS= read -r entry; do
        local sid wt_dir
        sid="${entry%% *}"
        wt_dir="${entry#* }"
        [[ -n "$keep" && "$keep" == "$sid" ]] && continue
        delete_worktree_dir "$sid" "$wt_dir"
    done < <(get_stale_worktree_dirs)

    echo "Removed $count file(s)"
}

# ── main ───────────────────────────────────────────────────────────────────

case "${1:-}" in
    list)
        echo "Session IDs found in $CLAUDE_DIR:"
        list_sessions
        ;;
    current)
        id=$(get_current_session "$PWD")
        if [[ -n "$id" ]]; then
            echo "$id"
        else
            echo "No running session found for $PWD" >&2; exit 1
        fi
        ;;
    running)
        shift || true
        current_id=$(get_current_session "$PWD")
        if [[ "${1:-}" == "--with-agents" ]]; then
            while IFS= read -r sid; do
                agents=$(get_running_agents_for_session "$sid" | tr '\n' ' ')
                label="${agents:+ [agents: ${agents% }]}"
                [[ -n "$current_id" && "$sid" == "$current_id" ]] && label=" [current]${label}"
                echo "${sid}${label}"
            done < <(get_running_sessions)
        else
            while IFS= read -r sid; do
                label=""
                [[ -n "$current_id" && "$sid" == "$current_id" ]] && label=" [current]"
                echo "${sid}${label}"
            done < <(get_running_sessions)
        fi
        ;;
    delete)
        shift
        if [[ "${1:-}" == "--all" ]]; then
            shift
            keep=""
            keep_running=""
            while [[ $# -gt 0 ]]; do
                case "${1:-}" in
                    --keep)         shift; keep="${1:?--keep requires a session ID}" ;;
                    --keep-running) keep_running="1" ;;
                    *)              echo "Unknown option: $1" >&2; exit 1 ;;
                esac
                shift
            done
            if [[ "$keep_running" == "1" ]]; then
                running_list=$(get_running_sessions | tr '\n' ' ')
                echo "Deleting all session data (keeping live sessions: ${running_list:-none})..."
            else
                echo "Deleting all session data${keep:+ (keeping $keep)}..."
            fi
            delete_all "$keep" "$keep_running"
        elif [[ $# -gt 0 ]]; then
            force=""
            ids=()
            for arg in "$@"; do
                [[ "$arg" == "--force" ]] && force=1 || ids+=("$arg")
            done
            echo "Deleting sessions..."
            for id in "${ids[@]}"; do
                delete_session "$id" "$force"
            done
        else
            echo "Usage: $0 delete <id>... | --all [--keep <id>] [--keep-running]" >&2; exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {list|current|running|delete} [options]"
        echo ""
        echo "  list                               List all sessions ([running]/[current]/[agents:])"
        echo "  current                            Running session ID for current directory"
        echo "  running [--with-agents]            List running session IDs"
        echo "  delete <id> [<id>…] [--force]      Delete specific sessions (--force skips liveness check)"
        echo "  delete --all                       Delete ALL session data + stale worktrees"
        echo "  delete --all --keep <id>           Delete all except <id>"
        echo "  delete --all --keep-running        Delete all except live sessions (any PID alive)"
        echo ""
        echo "  Live = main OR any agent/worktree PID for that session is still running."
        echo "  Worktree dirs are only cleaned when their session is fully dead."
        echo "  Registry: $REGISTRY"
        exit 1
        ;;
esac
