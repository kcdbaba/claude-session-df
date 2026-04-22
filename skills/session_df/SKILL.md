---
name: session_df
description: Manage Claude Code sessions — list, inspect, and clean up session files and worktree dirs. Wraps ~/.claude/clean-sessions.sh with short subcommands.
user_invocable: true
---

# /session_df

Manage Claude Code sessions. Wraps `~/.claude/clean-sessions.sh`.

## Subcommands

```
/session_df                             → show this help
/session_df help                        → show this help
/session_df ls                          → list all sessions (annotates [current] [running] [agents:])
/session_df ls --running [--agents]     → list only running sessions (--agents shows agent IDs)
/session_df cur                         → print running session ID for current directory
/session_df rm <id>                     → delete session <id> (skips if session is live)
/session_df rm --force <id>             → delete session <id> even if live
/session_df rm --keep-running --all     → delete all sessions except live ones
/session_df rm --force --all            → delete ALL session data including live sessions
/session_df rm --all                    → AMBIGUOUS: ask user to clarify
```

## Execution

Parse `$ARGUMENTS` and dispatch to the correct `clean-sessions.sh` command via Bash.

### Dispatch logic

| Arguments | Script call |
|---|---|
| *(empty)* or `help` | Print the subcommand reference table above — do not run any script |
| `ls` | `~/.claude/clean-sessions.sh list` |
| `ls --running` | `~/.claude/clean-sessions.sh running` |
| `ls --running --agents` | `~/.claude/clean-sessions.sh running --with-agents` |
| `cur` | `~/.claude/clean-sessions.sh current` |
| `rm <id>` | `~/.claude/clean-sessions.sh delete <id>` |
| `rm --force <id>` | `~/.claude/clean-sessions.sh delete --force <id>` |
| `rm --keep-running --all` | `~/.claude/clean-sessions.sh delete --all --keep-running` |
| `rm --force --all` | `~/.claude/clean-sessions.sh delete --all` |
| `rm --all` | **Do not run anything.** Ask the user: "Did you mean `--keep-running --all` (safe, keeps live sessions) or `--force --all` (deletes everything including live sessions)?" |

### Steps

1. Parse `$ARGUMENTS` against the dispatch table above.
2. For `rm --all` with no other flags: ask the user to clarify before doing anything.
3. For all other commands: run the mapped script call via Bash, then **print the full output as plain text in your response** (do not rely on the tool result being visible — always echo it explicitly). Follow with a one-line natural language summary (e.g. "9 sessions total, 1 running." or "1 session running, no agents.").
4. For destructive operations (`rm --force --all`): state what will be deleted before running, then run, then print output.
