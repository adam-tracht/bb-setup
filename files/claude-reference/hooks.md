# Hooks

Registered in `~/.claude/settings.json` under `hooks`. Scripts live in `~/.claude/hooks/`.

## Hark phone notifications (long turns only)

Adam's phone is signed into his personal Claude account while this machine runs the work account, so Claude Code's native phone push can't reach him. Hark (`hark.ryan.ceo`) is an HTTP-to-iPhone-notification webhook and is account-agnostic, which is why it's used instead.

Two cooperating hooks, because the `Stop` payload carries no timestamp:

| Script | Event | Role |
|---|---|---|
| `turn-start.sh` | `UserPromptSubmit` | Writes an epoch stamp to `$TMPDIR/claude-turn-timers/<session_id>.start` |
| `hark-notify.sh` | `Stop` | Reads the stamp, computes elapsed, POSTs if over threshold |

**Gating.** `Stop` fires on every completed response, so an ungated hook notifies on every turn. Only turns at or over `CLAUDE_HARK_THRESHOLD` seconds (default 60) send. Short exchanges stay silent.

**Privacy.** The `Stop` payload includes `last_assistant_message`. It is deliberately never transmitted. The body is only the directory name and elapsed time, e.g. `Finished in my-app after 3m 5s`. Hark publishes no privacy policy or retention statement, so nothing derived from response content should ever be added to this payload.

**Token.** `~/.claude/.hark-token`, mode 600, containing a bare `whk_...` webhook token. Both hooks silently no-op when the file is absent, so the config is safe to commit or sync without the secret.

**Safety properties.** Both scripts always `exit 0` and never write to stdout, so they cannot block a turn or inject context. `hark-notify.sh` checks `stop_hook_active` and bails if a prior hook forced a continuation. The `curl` is detached and capped at 5s, so a slow or down endpoint never delays the turn ending.

**Testing.** `CLAUDE_HARK_DRY_RUN=1` prints the payload to stderr instead of sending:

```bash
printf '%s' '{"session_id":"t","cwd":"/tmp/demo","hook_event_name":"Stop","stop_hook_active":false}' | CLAUDE_HARK_DRY_RUN=1 ~/.claude/hooks/hark-notify.sh
```

That prints nothing unless a stamp file exists and is old enough, which is the gate working correctly.

## Other registered hooks

- `PreToolUse` on `Bash`: `rtk hook claude` (token-optimizing command rewrite) and `pre-commit-doc-gate.sh`.
- `SessionStart`: `scripts/sync-desktop-skills.sh`.
