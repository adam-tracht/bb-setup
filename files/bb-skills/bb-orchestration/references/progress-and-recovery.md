# Progress and recovery

Read only when diagnosing or recovering a delegated worker. Use maintained
`bb-cli` inspection and recovery guidance for current commands and output shapes.
Use `model-routing` for provider, catalog, setup, and excessive context problems.

## Establish actual progress

Before a diagnosis, recommendation, or steering message, inspect the worker's
task contract, relevant artifacts and diffs, recent check results, explicit
blockers, pending approvals, and descendants. Verify which thread owns the work
and whether a child or an active command is still advancing it.

- Compare task artifacts and check outcomes across observations. A coherent patch,
  a resolved acceptance item, or a completed check is useful progress.
- Read the relevant recent output and runtime logs to explain missing progress.
  Distinguish waiting on a dependency, user decision, running check, provider
  failure, and an idle worker that has no active descendant or command.
- Attribute changes to owned paths or isolated worktrees. Parse structured status
  and exact paths; never diagnose from substrings in mixed git status output.
- Parent idleness does not establish a stall. Raw message, tool, token, commit,
  or file counts do not establish useful work. A quiet long check can be healthy.
- If evidence is insufficient, state that uncertainty and obtain the missing
  observation. Do not stop or replace a worker on an unproven diagnosis.

Keep three claims separate:

| Claim | Evidence required |
| --- | --- |
| Compaction occurred or took time | Context/runtime records locating the event and duration |
| Useful work advanced or stopped | Task artifact, acceptance, check, blocker, and descendant evidence |
| Compaction caused lost progress | Evidence connecting the event to a specific failure; timing alone is insufficient |

When compaction appears excessive, inspect fixed tool payloads separately from
conversation summaries, using `model-routing`. Defer unused tools and retain the
200k threshold. Do not lower it reflexively or blame summaries without evidence.
Route setup changes through the maintained skill within existing authorization;
do not copy its catalogs or edit bundled/generated skills.

## Recover only a confirmed stalled worker

If the user manually stopped a worker, do not resume, replace, or continue its
work unless the user asks to continue that work. Earlier task approval does not
override the manual stop. This restriction does not prohibit authorized recovery
of a confirmed runtime stall.

1. Inspect before stopping: current artifact state, active commands, descendants,
   blockers, and runtime errors. Prefer resolving a concrete dependency or setup
   problem while retaining the current productive owner.
2. Before an interruption, preserve the patch and uncommitted task work, including
   relevant untracked files. Record their location and ownership without resetting
   or overwriting unrelated changes. Capture tests already run, their input state
   and results, acceptance criteria, scoped approvals, and open decisions.
3. Replace only the confirmed stalled worker. Preserve the existing orchestrator and
   substantive reviewers. Do not stop healthy siblings or descendants merely
   because their parent is idle. Transfer write ownership explicitly so the old
   and replacement workers cannot write concurrently.
4. Give the replacement a compact handoff: verbatim frozen contract, exact task
   and owned paths, preserved patch/work location, verified completed work,
   remaining acceptance, check evidence, approvals, blocker and diagnosis,
   dependencies, and the next concrete action. Avoid replaying the full transcript.
5. If the failure repeats, diagnose the runtime/provider/context failure through
   maintained `bb-cli` and `model-routing` guidance. Stop endless replacement;
   report the evidenced blocker or seek the missing decision when required.

## Communication and validation continuity

Leave automatic BB completion notices enabled. Discretionary messages carry an
action, decision, or critical steer grounded in checked facts, not acknowledgment
chains. Preserve previous user authorization without inventing a new approval
gate or expanding it to unattended external/customer actions.

Reuse completed validation when relevant inputs are unchanged. Retain one final
validation executor per command/scope across recovery. Focused tests may continue
while fixing; independent review may require new checks when relevant inputs
changed or a concrete concern needs evidence. Record the reason and new input
state, then assign an executor instead of having every reviewer rerun everything.
