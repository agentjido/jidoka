# Durable Incident Recovery Commander

## Purpose

This is the largest deterministic Jidoka reference agent. It stresses the
durable orchestration boundary without a provider key or network request.

One parent turn starts five operations in parallel:

1. A pure topology lookup completes.
2. A forensic subagent completes a bounded tool loop.
3. A containment subagent stops before one unsafe-once production change.
4. A communications subagent stops before one unsafe-once public message.
5. A reconcile-class recovery workflow retries capacity allocation, fans out
   service analysis, and stops at a serializable loop cursor.

The scenario saves the parent session in DETS, serializes its snapshot, stops
the DETS process, opens the store again, and applies the two child approvals
one at a time. The first approval also lets the workflow finish. The unmatched
child stays paused. The final resume reuses all completed journal results, so
no completed operation runs twice.

## What It Proves

- Parallel actions, subagents, and one workflow use one operation batch.
- Completed siblings survive while three nested operations are suspended.
- Nested reviews are visible and resumable through the parent session.
- One approval resumes only its exact child intent.
- A reconcile-class workflow resumes only through its exact continuation.
- A downstream workflow step runs after a suspended loop completes.
- Two unsafe-once actions run exactly once after approval.
- DETS state survives a store process restart.
- Parent and nested snapshots contain portable data.
- Session memory is recalled before the first model call.
- The primary model can fail and the fallback can win on both parent calls.
- The final result is typed.
- Replay is data-only and trace export removes secrets.
- Streaming and cooperative cancellation still work on the same agent.

This example uses a deterministic process counter to prove that the four
external actions run once. It uses a local DETS file under the system temporary
directory and removes that file after each command run.

## Read It In This Order

1. lib/agent.ex - the parent command surface and safety policies.
2. lib/subagents/ - the three bounded specialist agents.
3. lib/workflows/recovery_workflow.ex - fan-out, retry, and durable loop.
4. lib/actions/ - the external effect boundaries.
5. lib/scripted_llm.ex - deterministic parent, child, fallback, stream, and
   cancel decisions.
6. lib/scenario.ex - DETS restart, approvals, replay, trace, stream, and
   cancellation.
7. test/incident_recovery_commander_test.exs - executable guarantees.
8. incident_recovery_commander.livemd - guided inspection and execution.

## Run It

    mix run examples/incident_recovery_commander/example.exs
    mix test --only example:incident_recovery_commander
    mix test examples/incident_recovery_commander/test/incident_recovery_commander_test.exs --trace
    mix run scripts/check_livebooks.exs -- --project examples/incident_recovery_commander/incident_recovery_commander.livemd

## Expected Durable Sequence

    parent model fallback
      -> 5 parallel operations
         -> topology lookup completes
         -> forensic subagent completes
         -> containment subagent waits for review
         -> communications subagent waits for review
         -> recovery workflow waits at its loop cursor
      -> DETS store process restarts
      -> approve containment
         -> containment completes
         -> recovery workflow completes
         -> communications stays paused
      -> approve communication
         -> communication completes
      -> parent model fallback
      -> typed resolved result

## Safety Boundary

This is a reference architecture, not a production incident system. Real
production actions must use trusted adapters, external idempotency keys,
durable multi-node storage, operator identity, authorization, and audited
credential management. Do not derive agent, workflow, or action modules from
incident input.

## Related Guides

- [Agent Orchestration](../../guides/agent-orchestration.md)
- [Workflows](../../guides/workflows.md)
- [Human In The Loop](../../guides/human-in-the-loop.md)
- [Idempotency And Safety](../../guides/idempotency-and-safety.md)
- [Sessions And Stores](../../guides/sessions-and-stores.md)
