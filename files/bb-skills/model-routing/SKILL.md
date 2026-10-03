---
name: model-routing
description: How this machine's model routing works (bb pickers, Claude Code, the opencodex proxy, provider keys, Codex catalog, scheduled catalog refresh). Use when a model is missing or mislabeled in a bb or Codex model picker, a provider returns 401/400, a catalog is stale, `ocx sync` or `ocx sync-cache` fails, a new model release is not showing up, or before changing any provider key or proxy setting.
---

# Model routing: diagnose before you assert

## Two failures that are not key or version problems

**"This Go model requires Global regions. Select Global in your workspace's
Privacy settings."** DeepSeek models on OpenCode Go (`deepseek-v4.1-flash`,
`deepseek-v4-flash`) fail this way. The key is fine. It is an account-side
setting on OpenCode, so no local command fixes it; the region has to be changed
in the OpenCode workspace settings.

**A model listed in the proxy but absent from the provider's live roster.** Seen
on opencode-go: `glm-5`, `grok-4.5`, `kimi-k2.5`, `ox-alpha-free`,
`qwen3.5-plus`, `union-alpha` were advertised by the proxy and errored when
picked. Compare the proxy's `/v1/models` with the provider's own endpoint
(`https://opencode.ai/zen/go/v1/models`) before treating a listed model as
available. `catalog-maintenance` refreshes catalogs but does not prune models the
provider has withdrawn.

**A provider with no key still lists every model it knows about.** Claude Code
showed roughly 740 models, about 640 of them unusable. Set `"disabled": true` on
that provider in `~/.opencodex/config.json`; the settings stay but the provider
drops out of routing and listings. Clear it when a key arrives.

**Editing `~/.opencodex/config.json` is not enough on its own.** `ocx sync`
refreshes the Codex catalog, but the running proxy's `/v1/models`, which is what
Claude Code reads, only changes after `ocx service restart`. Restart bb too: it
inherits `ANTHROPIC_BASE_URL` at launch, so a bb started before the proxy was
configured keeps a stale environment and its Claude picker looks wrong.

## Common operations (verified Sep 2026, ocx 2.63.0)

| Task | Command |
| --- | --- |
| Is the proxy up? | `ocx status` (PID, health, config path); `curl -s http://127.0.0.1:10100/healthz` |
| Restart the proxy (reload config/keys) | `ocx restart` |
| Is a newer ocx out? | `ocx system update check --channel latest --json`, or `npm view @bitkyc08/opencodex dist-tags` |
| Update ocx | `ocx update` (installs npm `latest`, stops and restarts the proxy by itself) |
| Refresh model catalogs | `ocx sync` |
| Refresh catalogs AND make Codex show them | `ocx sync --restart-codex` (restarts Codex app-server and the desktop app; `--restart-app-server-only` leaves the app open). Interrupts active Codex turns: confirm none are running. |
| Health report | `ocx doctor` |
| Refresh the bb Codex picker | `bb provider models codex --json` twice, a few seconds apart (bb serves its cached list for 10 min, then refreshes in the background; reference.md) |
| Claude Code's own model list | Restart Claude Code; it fetches Claude models from Anthropic, not from ocx |

Restarting the proxy or updating ocx drops any in-flight request through it, including Claude sessions routed via `ANTHROPIC_BASE_URL`. Check for running agents first.

Every layer here has changed under us before. Read `reference.md` in this folder for the layer map and the traps. Then find the failing layer by measurement, in this order, and report which check proved it.

1. **Which picker, which provider.** A bb picker row for a Claude model can come from bb's own shipped list OR from Claude Code; Codex and opencode (ACP) threads have their own lists. Identify the source of the row before theorizing (reference.md § Where picker rows come from).
2. **Ask the model source directly.** Claude Code: run the `initialize` request (reference.md § Checks). Proxy: `GET /v1/models` on the proxy port.
3. **Test the provider directly with curl**, bypassing the proxy. A different error for a bogus key than for the real key means the key is accepted and the failure is later.
4. **Test through the proxy** and read the last line of `~/.opencodex/usage.jsonl`. Direct works but proxy fails usually means the proxy has stale in-memory config: `ocx restart`.
5. **Check the scheduled refresh** in `~/.opencodex/catalog-maintenance.log`.

Rules:
- Never state a CLI flag without checking its real usage first. `ocx <cmd> --help` often prints only the top-level help. A bogus flag prints usage on most subcommands, but NOT on ones that act: `ocx update --bogus` ignored the flag and ran the update. For a command that changes anything, read `src/cli/` in the installed package instead.
- Never edit `~/.opencodex/config.json` without a timestamped backup beside it.
- Never ask for a secret to be pasted in chat. Give a `read -rs` terminal snippet that tests before it saves.
- A missing picker row is fixed at its source, never with a local `customModels` or settings bandaid.
- If what you learn contradicts reference.md, edit reference.md in the same session.
