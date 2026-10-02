# BB delegation model choices

Verified 2026-10-01 on MacBook Pro (`host_mpvbhvugjr`). This reference owns BB delegation's current role choices and exact IDs; provider defaults remain separately configured.

## Selection precedence

1. Explicit user model/provider/reasoning overrides win within their stated task, role, or run scope. Later overrides supersede earlier ones in that scope; do not spread worker overrides to other roles.
2. Keep the active orchestrator and existing substantive reviewers on their recorded selections unless the user requests a change.
3. For new workers without an override, use the table and the authorized provider. Do not inherit stale remembered choices, pick the newest release, or silently switch providers.

## Current choices

| Role | BB `claude-code` ID | BB `codex` ID | Reasoning; choice source |
| --- | --- | --- | --- |
| Very simple read-and-report | `claude-haiku-4-5-20251001` | `anthropic/claude-haiku-4-5` | `low`; personal Haiku role, installed family entry |
| Implementation and most new workers | `claude-sonnet-5-5` | `anthropic/claude-sonnet-5-5` | `medium`; personal version and reasoning preference |
| Complex work clearly requiring Opus | `claude-opus-5-5[1m]` | `anthropic/claude-opus-5-5` | Provider default: Claude `high`, Codex `medium`; personal role, configured Claude family default |
| Sol when assigned | Unassigned | `gpt-6.1-sol` | User override, otherwise installed default `low`; explicit user choice |
| Active orchestrator and existing substantive reviewers | Recorded selection | Recorded selection | Preserve scoped selection |

Claude Sonnet's installed route advertises OpenCodex to Anthropic. The three Codex Claude entries have upstream provider `anthropic` and IDs `claude-haiku-4-5`, `claude-sonnet-5-5`, and `claude-opus-5-5`. Sol is the native OpenAI entry. Opus's version follows the measured configured family choice, not release order. Its Claude `[1m]` suffix is part of the selection ID, not permission to raise compaction limits.

## Resolution, tools, and context

- Resolve once per run/execution host/provider/role against installed metadata: exact ID, provider route, supported reasoning, and relevant capabilities. Re-resolve after a scoped selection change or metadata invalidation. Use `bb provider models <provider> --machine <host> --json` and relevant catalog provenance, not aliases or a copied catalog.
- Pass the resolved model explicitly at spawn and resume, with scoped provider/reasoning choices. Preserve an existing worker's tuple on resume. Use maintained `bb-cli` for mechanics.
- Do not silently substitute an unlisted fallback, lower requested reasoning, switch providers, or disable tool search. Diagnose selection conflicts through [model-routing](__HOME__/.bb/skills/model-routing/SKILL.md).
- All four listed Codex entries advertise `supports_search_tool: true` and `tool_mode: code_mode_only`. Defer unused tools and load only needed schemas. Catalog metadata does not establish actual runtime tool exposure. When diagnosing excessive compaction, inspect actual runtime tool exposure through model-routing, including Claude workers.
- Keep the **200,000-token compaction threshold**, measured locally as `model_auto_compact_token_limit = 200000`. Larger model windows or catalog suggestions do not raise it; respect earlier provider/context limits. Diagnose context/configuration problems through model-routing within the user's authorization.

## Sources and deliberate updates

- [Personal Claude instructions](__HOME__/.claude/CLAUDE.md:57) own the Sonnet version/medium preference and Haiku/Opus role split. [Personal Codex instructions](__HOME__/.codex/AGENTS.md:57) preserve those family roles. Fable requires an explicit request. The user's scoped contract owns the Sol choice and orchestrator/reviewer preservation.
- Verified host lists: `bb provider models claude-code --machine host_mpvbhvugjr --json` and `bb provider models codex --machine host_mpvbhvugjr --json`. The Claude list marks the table's Opus selection `isDefault: true`.
- [Installed Codex catalog](__HOME__/.codex/opencodex-catalog.json) owns exact catalog IDs, provider provenance, supported reasoning, and search capability metadata. [Local configuration](__HOME__/.codex/config.toml:8) supplies the measured compaction setting. Read only relevant fields, without secrets.
- [Model-routing reference](__HOME__/.bb/skills/model-routing/reference.md) owns catalog/proxy/picker/cache diagnostics. Both model-routing links were checked at their real user-owned source paths.

Update this table deliberately when an explicit choice or verified role fit changes. Verify IDs, provider/reasoning metadata, and relevant tool capabilities on the execution host; update the source pointers and verification date here. New releases and catalog refreshes do not automatically change choices. Keep model versions only in this procedure reference. Updates affect future workers or explicit reselections, without restarting live workers, replacing reviewers, or changing their provider unasked.
