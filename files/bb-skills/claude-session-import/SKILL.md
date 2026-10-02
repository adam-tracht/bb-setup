---
name: claude-session-import
description: Import, synchronize, deduplicate, prune, and rename Claude Code transcript sessions in bb. Use whenever the user asks to bring Claude Code sessions from ~/.claude/projects into bb, re-import newer transcript versions, remove duplicate imports, exclude or include subagent transcripts, delete old imported sessions, or clean imported thread titles.
---

# Claude Code session import

Use the bundled `scripts/import_claude_sessions.py` helper for transcript
discovery and synchronization. It handles the provider JSONL format and bb's
local event store consistently; do not recreate the importer ad hoc.

## Defaults

- Import the last 30 days, using the machine's local timezone.
- Import top-level Claude sessions only. Claude's `subagents/agent-*.jsonl`
  files are separate provider transcripts, but they are not standalone user
  conversations; include them only when the user explicitly asks for them.
  Any transcript under a `subagents/` directory is treated as a subagent,
  regardless of filename.
- Use a dry run first. The helper writes only with `--apply`.
- Imported titles contain the actual custom title or first user prompt. Do not
  add a provider prefix unless the user requests one.
- Automated sessions that should never become threads can be excluded with
  title prefixes listed in `scripts/skip-titles.txt` (one prefix per line,
  `#` comments allowed; a thread is skipped when its title starts with a
  prefix). Skipped sources are reported as `title_skipped`. Pass
  `--skip-titles-file <path>` to use a different file.
- Claude's fork/resume flow writes new session files that copy the original
  conversation's start, so one conversation can appear as several session
  files. The helper deduplicates these: entries fully contained in a longer
  sibling with the same title and start time are skipped as snapshots
  (reported as `snapshot_duplicates_skipped`), while genuinely diverged forks
  are imported. Tiny entries (freshly started or failed runs) are always kept.
- Imported threads are attached to a ready workspace so they can be messaged
  immediately: personal-project threads use the most recently used ready
  personal workspace, and repository threads use an unmanaged environment at
  the project checkout (created when missing, mirroring bb's spawn-time
  provisioning). Threads receive the claude-code provider default
  (`claude-opus-5[1m]`) as a sticky model. Re-runs also heal older imports that
  predate workspace resolution: missing environments, models, and event scoping
  are backfilled.

## Deduplication and synchronization

The canonical source identity is the Claude `sessionId` for a top-level
transcript. For an explicitly included subagent it is
`sessionId:agent-filename`; this matters because subagents reuse their parent's
`sessionId`.

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
prevents duplicate threads even when Claude has duplicate files or a prior run
used a different source path.

## Workflow

1. Resolve the requested date range. Interpret “since DATE” inclusively at
   local midnight. For destructive requests such as pruning, state the exact
   cutoff and counts before acting.
2. Run a dry run:

   ```bash
   python3 ~/.bb/skills/claude-session-import/scripts/import_claude_sessions.py \
     --days 30
   ```

   Use `--since YYYY-MM-DD` for a calendar cutoff and add
   `--include-subagents` only when requested.
3. Before `--apply`, make a recoverable SQLite backup with `.backup` in
   `/private/tmp/bb-before-claude-<operation>-<YYYYMMDD>.db`.
4. Apply the synchronization:

   ```bash
   python3 ~/.bb/skills/claude-session-import/scripts/import_claude_sessions.py \
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
   delete by a broad title or project match, and never delete subagents unless
   they were explicitly included in the requested scope.
7. Verify imported counts, zero unintended duplicates, the cutoff boundary,
   and at least one representative thread with `bb thread log --json`.

## Reporting

Report the cutoff, candidate files, duplicate files skipped, new threads,
replacements with newer versions, unchanged existing threads, subagent count,
snapshot duplicates skipped, environments created, threads healed
(environment/model), events backfilled, and any deletions. Include the backup
path after mutations. If the UI has not refreshed, tell the user to refresh bb;
the CLI is the source of truth for verification.
