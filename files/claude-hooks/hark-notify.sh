#!/bin/bash
# Stop hook: push an iPhone notification via Hark when a long turn finishes.
#
# Gated on duration so short back-and-forth stays silent. Stop fires on EVERY
# completed response, so without this gate it would notify on every turn.
#
# Privacy: sends only the directory name and elapsed time. The Stop payload
# includes `last_assistant_message`, which is deliberately NOT transmitted.
#
# Token: read from ~/.claude/.hark-token (a bare whk_... webhook token).
# If the file is missing, the hook silently no-ops.
#
# Always exits 0. Never blocks the turn, never prints to stdout.

set -uo pipefail

THRESHOLD_SECONDS="${CLAUDE_HARK_THRESHOLD:-60}"
TOKEN_FILE="$HOME/.claude/.hark-token"
TIMER_DIR="${TMPDIR:-/tmp}/claude-turn-timers"

INPUT=$(cat)

# If a previous Stop hook forced a continuation, do nothing.
if [ "$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  exit 0
fi

[ -r "$TOKEN_FILE" ] || exit 0
TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")
[ -z "$TOKEN" ] && exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0

STAMP_FILE="$TIMER_DIR/${SESSION_ID}.start"
[ -r "$STAMP_FILE" ] || exit 0

START=$(cat "$STAMP_FILE" 2>/dev/null)
rm -f "$STAMP_FILE" 2>/dev/null
case "$START" in ''|*[!0-9]*) exit 0 ;; esac

ELAPSED=$(( $(date +%s) - START ))
[ "$ELAPSED" -lt "$THRESHOLD_SECONDS" ] && exit 0

if [ "$ELAPSED" -ge 60 ]; then
  DURATION="$((ELAPSED / 60))m $((ELAPSED % 60))s"
else
  DURATION="${ELAPSED}s"
fi

PROJECT=$(basename "${CWD:-$PWD}")
BODY="Finished in ${PROJECT} after ${DURATION}"

PAYLOAD=$(jq -nc --arg title "Claude Code" --arg body "$BODY" '{title: $title, body: $body}')

# CLAUDE_HARK_DRY_RUN=1 prints what would be sent instead of sending it.
if [ "${CLAUDE_HARK_DRY_RUN:-0}" = "1" ]; then
  printf 'WOULD SEND -> %s\n' "$PAYLOAD" >&2
  exit 0
fi

# Detached and time-boxed so a slow or down endpoint never delays the turn ending.
(
  curl -fsS --max-time 5 \
    -X POST "https://hark.ryan.ceo/hooks/${TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "$PAYLOAD" >/dev/null 2>&1
) &

exit 0
