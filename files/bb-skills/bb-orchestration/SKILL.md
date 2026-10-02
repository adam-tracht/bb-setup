---
name: bb-orchestration
description: "Coordinate authorized BB child-thread work across all projects, or diagnose and recover an existing delegated worker. Personal instructions determine when the main agent handles work directly and when delegation is required; this skill governs delegated coordination in BB."
---

# BB orchestration

Use this skill when coordinating delegated BB work authorized by the current
request or standing user instructions, or diagnosing or recovering a delegated
worker, across all projects, including factory runs.
The user's personal [CLAUDE.md](__HOME__/.claude/CLAUDE.md) determines
when the main agent handles work directly and when delegation is required.
This skill governs delegated coordination in BB; it does not narrow standing
delegation rules. Direct execution remains governed by personal instructions.
Loading it does not authorize delegation, external actions, or publication.
Use BB child threads, not native agents. Use workflows only when explicitly asked.

## Resource routing

- Use the maintained `bb-cli` skill for context, current syntax, thread creation,
  inspection, operation, and recovery. Check live help rather than copying flags.
- Read [references/models.md](references/models.md) when selecting delegated
  models. Current model IDs belong only there, never in this procedure.
- Read [references/progress-and-recovery.md](references/progress-and-recovery.md)
  only when diagnosing or recovering a worker.
- Use maintained `model-routing` for catalog, provider, setup, or excessive
  context/compaction problems and authorized fixes. Do not patch generated skills.

## Establish the contract

1. Verify essential facts before issuing diagnoses, recommendations, or messages.
   Inspect the relevant artifact, runtime evidence, checks, and current ownership.
   Obtain missing evidence before acting on a diagnosis or recommendation; uncertainty labels do not substitute for verification.
2. Carry forward the user's scoped approvals and frozen acceptance criteria.
   Ask only for a missing decision or an expansion of scope, not approved execution.
   This skill creates no new approval gate. Unattended external or customer
   actions require existing authorization covering that action.
3. Keep the current orchestrator and substantive reviewers. Give each task one direct
   owner and concrete output. Do not insert relay-only managers or replace a
   productive lead merely to reorganize the tree.
4. Freeze shared interfaces before parallel writes. Assign disjoint file ownership
   or isolated worktrees with an explicit integration owner. Each handoff includes
   the verbatim contract, scope, relevant paths, acceptance, approved actions,
   dependencies, and expected evidence. Assume workers inherit no context.
   Include this boundary verbatim in every child brief: "Only the root orchestrator
   may delegate. Child agents must not spawn agents or child threads. Return
   requests for additional help to the root."

## Select and launch

5. Honor explicit user model, provider, and reasoning choices first; otherwise use
   the documented role choices in the models reference. Preserve those preferences.
   Do not silently choose the newest model or inherit stale remembered choices.
6. Resolve exact catalog metadata on the worker's execution host: model ID,
   provider, supported reasoning, and relevant context settings. If selection is
   unavailable or conflicting, diagnose through `model-routing`; do not substitute
   silently. Update model choices deliberately in the owned models reference.
7. Defer unused tools and retain the 200k compaction threshold. Diagnose excessive
   fixed tool context or summaries through `model-routing` before changing setup.
8. Launch only authorized tasks through BB, using maintained `bb-cli` mechanics.
   Existing substantive leads own their work directly; parallel workers do not
   write the same files without an explicit serialization contract.

## Supervise and finish

9. Judge progress by artifacts, completed checks, blockers, and active descendants.
   Parent idleness, activity counts, or elapsed time alone do not prove a stall.
   Use the progress reference when diagnosis or recovery is needed.
10. Leave BB automatic completion notices enabled. Send discretionary messages
    only for an action, decision, or critical steering correction after verifying
    the facts. Do not cascade acknowledgments or duplicate completion notices.
11. Run focused checks while fixing. Assign one executor per final validation
    command and scope, recording the inputs/revision and result for reuse.
    Independent reviewers assess acceptance and substance without routinely
    rerunning those checks. Changed relevant inputs or a concrete new concern
    can justify a new check with a named executor.
12. Integrate owned work, review contract compliance and code quality, and report
    changed artifacts, acceptance evidence, and remaining blockers. Preserve the
    orchestrator/reviewer roles and scoped approvals through the final handoff.
