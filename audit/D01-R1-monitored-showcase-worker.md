---
id: D01-R1
title: Monitor the showcase turn worker
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P1
impact: medium
confidence: high
effort: low
blast_radius: low
dependencies: [L34-R1]
---

# Monitor the showcase turn worker

## Objective

Prevent the showcase LiveView from staying in a running state when its turn worker exits before it sends a result.

## Evidence

- `showcase/lib/jidoka_showcase_web/agent_live.ex:149-184` starts a live turn with `Task.start`.
- `showcase/lib/jidoka_showcase_web/agent_live.ex:268-295` starts a resume turn with `Task.start`.
- An unmonitored task can exit before it sends the expected message.

## Current problem

The LiveView has no exit signal for a failed task. Its `running` state can remain true forever.

## Proposed representation and invariant

Store one active-worker value with the request ID and monitor reference. Use a monitored task or a supervised async task.

Invariant: every active request has one worker and one terminal outcome: result, error, or worker exit.

## Smallest credible scope

- `showcase/lib/jidoka_showcase_web/agent_live.ex`
- Its LiveView test module

No library or persisted-state change is required.

## Risks and migration

`DOWN` and result messages can race. Ignore stale messages by request ID and monitor reference. Clear the monitor after a successful result.

## Validation

Run existing showcase LiveView tests.

Add these cases:

- Worker crash before a result -> visible failure and cleared running state.
- Stale `DOWN` for an old request -> no state change.
- Successful worker result -> monitor is cleared and view is not running.

## Acceptance criteria

- The UI never stays running after its worker exits.
- One request gets at most one terminal view update.
- Existing success and resume flows remain valid.

## Out of scope

- General library task supervision.
- Changes to agent execution semantics.
