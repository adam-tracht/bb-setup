#!/bin/bash
# UserPromptSubmit hook: stamp the start of a turn so the Stop hook can measure duration.
# The Stop payload carries no timestamp, so we record one ourselves.
# Always exits 0. Never blocks or writes to stdout (stdout on this event is injected as context).

set -uo pipefail

TIMER_DIR="${TMPDIR:-/tmp}/claude-turn-timers"
mkdir -p "$TIMER_DIR" 2>/dev/null || exit 0

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0

date +%s > "$TIMER_DIR/${SESSION_ID}.start" 2>/dev/null

# Opportunistic cleanup: drop stamps older than a day.
find "$TIMER_DIR" -name '*.start' -mtime +1 -delete 2>/dev/null

exit 0
