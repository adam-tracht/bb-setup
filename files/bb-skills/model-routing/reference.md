# Model routing reference

How models reach Adam's pickers and agents on his Mac. Describes mechanisms and how to check them; version facts go stale, so re-measure them.

## Layers

| Layer | What it is | Where |
| --- | --- | --- |
| bb | Hosts Claude Code, Codex, and ACP agents (opencode among them). Renders the model pickers. | `/Applications/bb.app` |
| bb Claude Code plugin | Ships a FIXED list of Claude models with display names, merged into the picker. | `.../app.asar.unpacked/node_modules/bb-app/server/dist/builtin-plugins/provider-claude-code/dist/server.js`, `CLAUDE_CODE_ACTIVE_CATALOG_DATA` and `DEFAULT_CLAUDE_CODE_MODEL` |
| Claude Code | Reports its own models (aliases like `default`, `opus[1m]`, `sonnet`) plus gateway models. | `~/.local/share/claude/versions/<ver>` |
| opencodex proxy (`ocx`) | Local gateway on `127.0.0.1:10100`. Claude Code reaches it via `ANTHROPIC_BASE_URL` and lists its models because `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1`. Routes non-Anthropic models under synthetic ids (`claude-opus-4-8-xxx`, `claude-ocx-*`). Also lists first-party Anthropic models Claude Code does not know yet (Sep 2026: `claude-sonnet-5-5` as "(anthropic)", routed to provider `anthropic`); older, known Anthropic models are not listed. | config `~/.opencodex/config.json`, launchd `com.opencodex.proxy` |
| Providers | opencode-go, openrouter, native OpenAI, etc. Key in `providers.<name>.apiKey` AND `providers.<name>.apiKeyPool[].key`. | `~/.opencodex/config.json` |
| Codex catalog | Written by `ocx sync`. | `~/.codex/opencodex-catalog.json` |
| Scheduled refresh | launchd `ai.opencodex.catalog-maintenance`, every 6 h. Runs `ocx sync` then `ocx sync-cache`, then an ocx self-update check. | `~/.opencodex/catalog-maintenance.sh`, `.log`, `.error.log` |

opencode running in bb over ACP is a separate path from the proxy's `opencode-go` provider. Do not assume one explains the other; trace the ACP path on its own if it is the one failing.

## Where picker rows come from

- bb's Claude picker = bb plugin's fixed list + Claude Code's reported list. Numbered rows ("Opus 5", "Opus 4.8") come from bb's list; alias rows ("Opus 1M context") come from Claude Code.
- So a newly released Claude model shows only as an unnumbered alias row until a bb release adds it to its list. That is a bb upstream gap, not local breakage. Confirm by searching `server.js` for the model id.
- A row described "From gateway" came from the proxy.
- **New Claude model checklist** (Sonnet 5.5, Sep 2026): the API serves it before tools know it. `claude -p --model <id>` answers with an `unrecognized_model` warning; the proxy lists it as a "From gateway" row right away. Claude Code auto-updates are off (`~/.claude.json` `autoUpdates: false`), so run `claude install latest` to move the `sonnet`/`opus` alias rows to the new model. A numbered bb row still needs a bb release.
- bb's Codex picker shows native OpenAI rows without "GPT-" ("6-Sol", "5.5"). The Codex provider plugin sets `brandPrefix: "GPT-"` (`builtin-plugins/provider-codex/dist/server.js`), and the tab icon already says OpenAI. Routed rows like `anthropic/...` don't start with the prefix, so they keep their full names. This is intended; nothing is broken.
- In that picker, models added by a newer ocx release can sort to the very end, after the ~500 routed rows (Sep 2026: gpt-6-sol/luna were rows 507-508 of 508). Search finds them.

## Checks

Claude Code's model list (the `initialize` control request):

```python
import subprocess, json, select, time
p = subprocess.Popen([CLAUDE_BIN, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
p.stdin.write(json.dumps({"type": "control_request", "request_id": "r1", "request": {"subtype": "initialize"}}) + "\n"); p.stdin.flush()
# read stdout lines until one has response.response.models; print value | displayName | description; filter out "From gateway"
```

(macOS has no `timeout`; use `select` with a deadline.)

Proxy model list and a request through it (admin token in `~/.opencodex/admin-api-token`):

```zsh
T=$(cat ~/.opencodex/admin-api-token)
curl -s "http://127.0.0.1:10100/v1/models?limit=1000" -H "x-api-key: $T" -H "anthropic-version: 2023-06-01"
curl -s http://127.0.0.1:10100/v1/messages -H "x-api-key: $T" -H "anthropic-version: 2023-06-01" -H 'content-type: application/json' \
  -d '{"model":"<routed id>","max_tokens":20,"messages":[{"role":"user","content":"say ok"}]}'
tail -1 ~/.opencodex/usage.jsonl   # provider, model, status of that request
```

Direct provider test (opencode Go example):

```zsh
curl -s https://opencode.ai/zen/go/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H "x-opencode-session: test-$(uuidgen)" -H 'content-type: application/json' \
  -d '{"model":"kimi-k2.7-code","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}'
```

Other: `ocx provider test <name>`, `ocx provider show <name>` (masked key), per-provider history via `usage.jsonl` status counts, proxy start time via `ps -o lstart= -p $(cat ~/.opencodex/ocx.pid)`.

## Traps

- **The proxy holds provider keys in memory.** Editing `config.json` does nothing until `ocx restart`. Compare proxy start time with the config file's mtime.
- **Changing a key:** `ocx provider edit` has no key flag; only `ocx provider add` takes `--api-key`, and `add --force` may reset per-model tuning (unverified). The safe method: back up `config.json`, write `apiKey` and every `apiKeyPool[].key` with a script fed by `read -rs`, then `ocx restart`, then `ocx sync`.
- **`ocx provider test` can report a false 401**: it checks the provider's model list, and opencode Go rejects keyed requests to `/models` while serving it unauthenticated. Trust a real completion request over it.
- **opencode Go requires `x-opencode-session`** on completions (400 `MissingSessionID` without it). Error layering: bogus key gives `AuthError: Invalid API key`; an accepted key that is refused later gives `Upstream request failed: Invalid credential`. opencode's dashboard files older keys under a "Legacy" service account; in Sep 2026 a Legacy key started failing that way while a fresh service-account key worked.
- **One dead provider stalls the whole catalog**: sync logs `provider discovery degraded; preserving N existing routed entries` and stops updating instead of partially updating.
- **The scheduled refresh fails if EITHER `ocx sync` or `ocx sync-cache` exits non-zero**, so a Codex-side cache failure keeps the job red even when every provider is healthy.
- **`ocx sync-cache` exits 1 when there is nothing to write** (ocx 2.60.0): "Cache refresh did not complete (completed)" also means the cache already matched the catalog, because the writer returns the same `false` for no-op and failure (`src/codex/catalog/retained-sync.ts`, `invalidateCodexModelsCacheWithPermit`). Not a real failure on its own. Before Sep 28 2026 it made the scheduled job exit before its self-update step (ocx sat at 2.63.0 while 2.70.0 was out); `catalog-maintenance.sh` now treats that exact message as success.
- **Native OpenAI (ChatGPT subscription) picker rows come from a list hardcoded in the ocx release** (`src/codex/catalog/native-models.ts`), not from OpenAI. ocx fetches the account's live roster (`chatgpt.com/backend-api/codex/models`) only to gate models it already knows. A new OpenAI model therefore works through the proxy by its bare id right away, but gets no picker row until an ocx release adds it; the scheduled job's self-update picks that up. Check the live roster with Codex's `~/.codex/auth.json` token (`tokens.access_token`, `chatgpt-account-id` header, `client_version` param). In Sep 2026 `gpt-6-luna` and `gpt-6-sol` were in the roster and answered through the proxy while ocx 2.61.0 and 2.62 preview did not list them; upstream added them on the `dev` branch the same day and shipped them in 2.63.0 a few hours later (lidge-jun/opencodex PR #5580, `native-models.ts` + `roster-pinned-models.json`). To check whether a fix is coming, read that file on `dev` with `gh api repos/lidge-jun/opencodex/contents/src/codex/catalog/native-models.ts?ref=dev`. OpenRouter's copies (`openai/gpt-6-*`) do appear, because that provider's list is live.
- **Releases often land within hours of a dev merge**, so check `npm view @bitkyc08/opencodex dist-tags` before concluding a fix is unreleased. Update steps: SKILL.md § Common operations.
- **Codex app-server processes keep the old model list** until restarted: `ocx sync --restart-codex` (interrupts active Codex turns).
- **bb caches every provider's picker list** in `~/.bb/bb.db` table `provider_model_catalogs` (`fetched_at` in ms). A cached list is served as-is for 10 minutes (`FRESH_MS` in `server/dist/start-server.js`); after that, the next read serves the old list AND starts a background refresh. So after `ocx sync`, the bb Codex picker catches up on the second open more than 10 minutes after the last refresh. Force it: run `bb provider models codex --json` once, wait a few seconds, run it again. Check the age: `sqlite3 -readonly ~/.bb/bb.db "select datetime(fetched_at/1000,'unixepoch','localtime') from provider_model_catalogs where provider_id='codex'"`. Refresh outcomes log to `~/.bb/logs/server.*.log` as "Provider model catalog refresh settled". In Sep 2026 bb had cached the list 4 minutes before ocx 2.63.0 wrote gpt-6-sol/luna, which looked like an ocx failure but was only this cache.
- **The ChatGPT desktop app runs its own bundled Codex app-server**, separate from bb's and from `~/.local/bin/codex`; it needs an app restart to see a new catalog.
- **A new or edited skill in `~/.bb/skills/` reaches agents through a bb snapshot** (`~/.bb/runtime/global-skills/<hash>/`), not the live folder. Right after a write, threads can still get the old snapshot; in Sep 2026 Codex picked up the new one on a later turn with no restart. Re-check before concluding a skill is invisible.
- **`grep` in Bash may be rewritten by rtk** and misreport matches; use Python for searches inside app bundles and large files.
