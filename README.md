# claude-session-df

Session management for [Claude Code](https://claude.ai/download) — list, inspect, and clean up session files, with live process tracking.

Like `df` for your Claude sessions.

## What it does

- Tracks every Claude Code session (and background agents) via a PID registry
- Shows which session is **current** (running in your project directory)
- Cleans stale session files safely, preserving live sessions
- Exposes a `/session_df` slash command inside Claude Code

## Requirements

- bash 3.2+
- [`jq`](https://jqlang.github.io/jq/)
- [Claude Code](https://claude.ai/download) CLI

## Install

```bash
git clone https://github.com/kcdbaba/claude-session-df.git
cd claude-session-df
bash install.sh
```

Then **restart Claude Code** for the `SessionStart` hook to take effect.

## Usage

### Slash command (inside Claude Code)

```
/session_df                          → show help
/session_df ls                       → list all sessions
/session_df ls --running             → running sessions only (annotates [current])
/session_df ls --running --agents    → include background agent IDs
/session_df cur                      → current session ID for this directory
/session_df rm <id>                  → delete a session (skips if live)
/session_df rm --force <id>          → delete even if live
/session_df rm --keep-running --all  → delete all stale sessions
/session_df rm --force --all         → delete everything
```

### Shell script directly

```bash
~/.claude/clean-sessions.sh list
~/.claude/clean-sessions.sh running [--with-agents]
~/.claude/clean-sessions.sh current
~/.claude/clean-sessions.sh delete <id> [--force]
~/.claude/clean-sessions.sh delete --all [--keep-running] [--keep <id>]
```

## How it works

A `SessionStart` hook (`hooks/session-tracker.sh`) fires when Claude Code starts any session. It appends `PID:session_id:agent_id:project_dir` to `~/.claude/.session_pids` and prunes dead entries.

`clean-sessions.sh` reads this registry to determine liveness before listing or deleting session files across `~/.claude/todos/`, `~/.claude/debug/`, `~/.claude/file-history/`, and project JSONL files.

## Files installed

| Source | Destination |
|---|---|
| `clean-sessions.sh` | `~/.claude/clean-sessions.sh` |
| `hooks/session-tracker.sh` | `~/.claude/hooks/session-tracker.sh` |
| `skills/session_df/SKILL.md` | `~/.claude/skills/session_df/SKILL.md` |
| *(settings patch)* | `~/.claude/settings.json` |

## Uninstall

```bash
rm ~/.claude/clean-sessions.sh
rm ~/.claude/hooks/session-tracker.sh
rm -rf ~/.claude/skills/session_df
```

Then remove the `SessionStart` hook entry from `~/.claude/settings.json`.
