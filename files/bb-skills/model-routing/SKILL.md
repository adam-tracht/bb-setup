---
name: model-routing
description: How Adam's model routing works on his Mac (bb pickers, Claude Code, the opencodex proxy, provider keys, Codex catalog, scheduled catalog refresh). Use when a model is missing or mislabeled in a bb or Codex model picker, a provider returns 401/400, a catalog is stale, `ocx sync` or `ocx sync-cache` fails, a new model release is not showing up, or before changing any provider key or proxy setting.
---

# Model routing: diagnose before you assert

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
- Never ask Adam to paste a secret in chat. Give a `read -rs` terminal snippet that tests before it saves.
- A missing picker row is fixed at its source, never with a local `customModels` or settings bandaid.
- If what you learn contradicts reference.md, edit reference.md in the same session.
