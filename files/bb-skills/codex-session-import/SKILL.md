---
name: codex-session-import
description: Import, synchronize, deduplicate, prune, and rename Codex CLI transcript sessions in bb. Use whenever the user asks to bring Codex sessions from ~/.codex into bb, re-import newer transcript versions, remove duplicate imports, delete old imported sessions, or clean imported thread titles.
---

# Codex CLI session import

Use the bundled `scripts/import_codex_sessions.py` helper for transcript
discovery and synchronization. It handles the Codex JSONL format and bb's
local event store consistently; do not recreate the importer ad hoc.

## Defaults

- Import the last 30 days, using the machine's local timezone.
- Scan both active sessions under `~/.codex/sessions/YYYY/MM/DD/` and archived
  sessions under `~/.codex/archived_sessions/`. Use `--skip-archived` to omit
  the archive directory.
- Read titles from `~/.codex/session_index.jsonl` when available. Fall back to
  the first user message text.
- Skip sessions that originated as Claude Code imports (recorded in
  `~/.codex/external_agent_session_imports.json`). Those conversations are
  already covered by the `claude-session-import` skill. Use
  `--include-claude-imports` to import them as Codex threads anyway.
- Use a dry run first. The helper writes only with `--apply`.
- Imported titles contain the actual Codex title or first user prompt. Do not
  add a provider prefix unless the user requests one.

## Deduplication and synchronization

The canonical source identity is the Codex `session_id` found in the
`session_meta` payload of each transcript.

Claude-imported sessions are filtered out before deduplication unless
`--include-claude-imports` is passed. Their Codex `session_id` appears in
`~/.codex/external_agent_session_imports.json` under `imported_thread_id`.

Deduplicate in two places:

1. If multiple JSONL files have the same canonical identity, select the file
   with the newest filesystem modification time. Use size and path only as
   deterministic tie-breakers, and report how many files were skipped.
2. Compare each selected source with existing imported bb threads by their
   `thread/identity` provider thread id. If the source is newer than the
   existing imported content, replace the existing thread's events, search
   segments, title, and metadata with the newer transcript. Do not merely skip
   it. If it is not newer, leave the existing thread untouched.

The helper preserves an existing imported thread id when replacing it, and
uses a deterministic id for new imports. This makes repeated runs safe and
prevents duplicate threads even when Codex has duplicate files or a prior run
used a different source path.

## Workflow

1. Resolve the requested date range. Interpret “since DATE” inclusively at
   local midnight. For destructive requests such as pruning, state the exact
   cutoff and counts before acting.
2. Run a dry run:

   ```bash
   python3 ~/.bb/skills/codex-session-import/scripts/import_codex_sessions.py \
     --days 30
   ```

   Use `--since YYYY-MM-DD` for a calendar cutoff and add
   `--skip-archived` to ignore the archived session directory.
3. Before `--apply`, make a recoverable SQLite backup with `.backup` in
   `/private/tmp/bb-before-codex-<operation>-<YYYYMMDD>.db`.
4. Apply the synchronization:

   ```bash
   python3 ~/.bb/skills/codex-session-import/scripts/import_codex_sessions.py \
     --days 30 --apply
   ```

   The helper uses SQLite only because bb currently has no native transcript
   import command. Use bb's CLI for thread lifecycle operations and verify
   through bb after the write.
5. For title cleanup, enumerate only imported threads and use the bb CLI:

   ```bash
   bb thread update --title "NEW TITLE" THREAD_ID
   ```

   Remove only a requested leading prefix; preserve the actual title and never
   leave it blank. Verify with `bb thread list --json`.
6. For pruning, query the exact imported target set, show the delete/keep
   counts, then call `bb thread delete --yes THREAD_ID` for each target. Never
   delete by a broad title or project match.
7. Verify imported counts, zero unintended duplicates, the cutoff boundary,
   and at least one representative thread with `bb thread log --json`.

## Reporting

Report the cutoff, candidate files, duplicate files skipped,
Claude-imported sessions skipped, new threads, replacements with newer
versions, unchanged existing threads, archived-session file count, and any
deletions. Include the backup path after mutations. If the
UI has not refreshed, tell the user to refresh bb; the CLI is the source of
truth for verification.
