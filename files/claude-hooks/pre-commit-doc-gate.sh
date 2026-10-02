#!/usr/bin/env bash
# PreToolUse(Bash) doc-gate. Blocks a `git commit` that stages source code but no
# docs, telling Claude to update docs (via subagents, same commit) or re-commit
# with [skip-docs] to record a conscious skip. Advisory work is the model's;
# this script only detects + injects the prompt. Always exits 0 (deny is exit 0 + JSON).

# Read the event payload.
input="$(cat 2>/dev/null || true)"

# Need jq to parse; if missing, allow (never break the commit flow).
command -v jq >/dev/null 2>&1 || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"

# Only act on git commits (substring catches plain and rtk-wrapped forms).
case "$cmd" in
  *"git commit"*) : ;;
  *) exit 0 ;;
esac

# Override: explicit conscious skip recorded in the commit message.
case "$cmd" in
  *"[skip-docs]"*) exit 0 ;;
esac

[ -n "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# What is staged for this commit.
staged="$(git diff --cached --name-only 2>/dev/null || true)"
[ -n "$staged" ] || exit 0   # nothing staged: let git handle it

docs_changed=0
code_changed=0
code_list=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    *.md) docs_changed=1 ;;
    *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.sql|*.py|*.rb|*.go|*.css|*.scss|*.vue|*.svelte)
      code_changed=1
      code_list="${code_list}  - ${f}"$'\n' ;;
  esac
done <<< "$staged"

# Allow unless code changed with zero doc changes.
if [ "$code_changed" -ne 1 ] || [ "$docs_changed" -ne 0 ]; then
  exit 0
fi

reason="Doc-gate: this commit stages source code but no docs (no .md / docs / CLAUDE.md). Per the rule that anything worth committing is worth documenting:
Staged code:
${code_list}
If this changed behavior, architecture, schema, an API/route, or a documented convention: dispatch one or more subagents (one per affected doc area, in parallel) to update the relevant docs (docs/api.md, docs/services.md, docs/database.md, docs/frontend.md, CLAUDE.md, and any plans/ doc), stage them, then re-commit so the docs ride in this same commit.
If this is a pure refactor, test, typo, or dependency bump with no behavior or convention impact: re-commit with [skip-docs] in the commit message to record the conscious decision."

jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
