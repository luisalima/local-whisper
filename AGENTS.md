# local-whisper — Agent Guidelines

## Project overview

local-whisper is a fully-local macOS dictation tool. Hold Right Option to record, release to transcribe and insert text at cursor. Powered by whisper.cpp (C/C++, no Python), Karabiner-Elements, and Hammerspoon.

## Architecture

```
Karabiner (Right Option hold/release)
  → start_record.sh / stop_transcribe.sh (bash)
    → ffmpeg (chunked WAV recording)
    → whisper-cli (transcription)
    → hs -c "..." (signals Hammerspoon)
      → Hammerspoon (overlay, text insertion, hotkeys)
```

## Key paths

- `~/whisper-dictate/` — bash scripts (start, stop, config)
- `~/.hammerspoon/init.lua` — overlay + insertion + hotkeys
- `~/whisper.cpp/build/bin/whisper-cli` — transcription binary
- `~/whisper.cpp/models/ggml-medium.bin` — model
- `$TMPDIR/whisper-dictate/` — all temp state (per-user private dir on macOS)
- `$TMPDIR/whisper-dictate/chunks/` — recording segments (ephemeral)
- `$TMPDIR/whisper-dictate/partial.txt` — live partial transcript
- `$TMPDIR/whisper-dictate/final.txt` — final transcript
- `$TMPDIR/whisper-dictate/recording.pid` — ffmpeg PID lock
- `~/.whisper_dictation_lang` — language state (en|pt|auto)
- `~/.whisper_dictation_output` — output mode (paste|type)

## Conventions

- Bash scripts: use `set -euo pipefail`, source `config.sh` for shared vars
- All paths in scripts should be absolute (Karabiner runs in minimal env)
- Log to `$TMPDIR/whisper-dictate/whisper-dictate.log` for debugging
- Hammerspoon API: use `hs.canvas` for overlay, `hs.eventtap` for typing, `hs.pasteboard` for paste mode
- Signal between bash and Hammerspoon via `hs -c "FunctionName()"`
- whisper.cpp binary is `whisper-cli`, NOT `main`
- No Python anywhere — this is a pure C/shell/Lua stack

## Security

- Scripts must never execute untrusted input — transcribed text is data, not code
- PID files and temp files in `/tmp/` must use safe creation patterns (no symlink attacks)
- No network calls — everything stays local
- Clipboard contents are overwritten during paste mode — warn users in docs

## Workflow

- **Create a bd issue before starting any work**
- **Always verify work before closing an issue** — run the code, check the output, confirm it does what the issue asks
- Check `bd ready` for unblocked work
- `bd create "Title" -t task -p 2` to file new work
- `bd close <id>` when done

<!-- BEGIN BEADS INTEGRATION -->
## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why bd?

- Dependency-aware: Track blockers and relationships between issues
- Git-friendly: Auto-syncs to JSONL for version control
- Agent-optimized: JSON output, ready work detection, discovered-from links
- Prevents duplicate tracking systems and confusion

### Quick Start

**Check for ready work:**

```bash
bd ready --json
```

**Create new issues:**

```bash
bd create "Issue title" --description="Detailed context" -t bug|feature|task -p 0-4 --json
bd create "Issue title" --description="What this issue is about" -p 1 --deps discovered-from:bd-123 --json
```

**Claim and update:**

```bash
bd update bd-42 --status in_progress --json
bd update bd-42 --priority 1 --json
```

**Complete work:**

```bash
bd close bd-42 --reason "Completed" --json
```

### Issue Types

- `bug` - Something broken
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature with subtasks
- `chore` - Maintenance (dependencies, tooling)

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (default, nice-to-have)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Workflow for AI Agents

1. **Check ready work**: `bd ready` shows unblocked issues
2. **Claim your task**: `bd update <id> --status in_progress`
3. **Work on it**: Implement, test, document
4. **Discover new work?** Create linked issue:
   - `bd create "Found bug" --description="Details about what was found" -p 1 --deps discovered-from:<parent-id>`
5. **Complete**: `bd close <id> --reason "Done"`

### Auto-Sync

bd automatically syncs with git:

- Exports to `.beads/issues.jsonl` after changes (5s debounce)
- Imports from JSONL when newer (e.g., after `git pull`)
- No manual export/import needed!

### Important Rules

- Use bd for ALL task tracking
- Always use `--json` flag for programmatic use
- Link discovered work with `discovered-from` dependencies
- Check `bd ready` before asking "what should I work on?"
- Do NOT create markdown TODO lists
- Do NOT use external issue trackers
- Do NOT duplicate tracking systems

For more details, see README.md and docs/QUICKSTART.md.

<!-- END BEADS INTEGRATION -->

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
