#!/bin/bash
# Sync Claude Desktop (Cowork) skills into the Claude Code CLI skill dir.
# Desktop materializes skills into rotating per-session UUID dirs; this picks the
# newest one and mirrors each skill into ~/.claude/skills so the CLI stays in parity.
# Excludes skills that collide with CLI built-ins.
set -euo pipefail

BASE="$HOME/Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin"
DST="$HOME/.claude/skills"
EXCLUDE=("schedule" "setup-cowork")   # schedule: CLI built-in collision. setup-cowork: Desktop-only onboarding, useless in CLI.

[ -d "$BASE" ] || exit 0

# newest 'skills' dir by mtime across all sessions
SRC="$(find "$BASE" -maxdepth 3 -type d -name skills -print0 2>/dev/null \
  | xargs -0 stat -f '%m %N' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
[ -n "${SRC:-}" ] && [ -d "$SRC" ] || exit 0

mkdir -p "$DST"
for skdir in "$SRC"/*/; do
  sk="$(basename "$skdir")"
  [ -f "$skdir/SKILL.md" ] || continue
  skip=0; for e in "${EXCLUDE[@]}"; do [ "$sk" = "$e" ] && skip=1; done
  [ "$skip" = 1 ] && continue
  rsync -a --delete "$skdir" "$DST/$sk/" 2>/dev/null || { rm -rf "$DST/$sk"; cp -R "$skdir" "$DST/$sk"; }
done
