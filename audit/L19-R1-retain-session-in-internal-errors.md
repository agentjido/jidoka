---
id: L19-R1
title: Retain updated session state in internal errors
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P1
impact: high
confidence: high
effort: medium
blast_radius: medium
dependencies: []
---

# Retain updated session state in internal errors

## Objective

Keep the current session data in internal error results until the public result boundary.

## Evidence

- `lib/jidoka/session/execution.ex:287-309` updates session data during execution errors.
- `lib/jidoka/session/execution.ex:623-646` returns an error without that updated data.
- `lib/jidoka/session/environment_runtime.ex:120-147` can return updated environment state with a failure.

## Current problem

The store can contain a failure transition, but the internal caller can receive only an error. The caller then cannot inspect or continue from the same session state.

## Proposed representation and invariant

Use an internal result form that always contains the updated session value. Remove the session only at the public compatibility boundary.

Invariant: after an execution attempt, the returned internal session and the persisted session describe the same transition.

## Smallest credible scope

- `lib/jidoka/session/execution.ex`
- `lib/jidoka/session/environment_runtime.ex`
- Internal session execution result helpers and their tests
- Public error projection only, if current public tuples must stay unchanged

No new persisted field or wire field is required.

## Risks and migration

Internal tuple shapes will change. Public callers can depend on current error tuples. Preserve their output at the outer public function. Keep persistence order unchanged.

## Validation

Run existing session execution, environment runtime, commit-order, and durable-session tests.

Add these cases:

- Failure after a persisted transition -> internal error result contains the session that is in the store.
- Environment open failure with changed state -> internal result retains that state.
- Public error API -> keeps its current output shape.

## Acceptance criteria

- No internal execution error drops updated session data.
- Persisted and returned internal session states agree after success and failure.
- Public compatibility tests remain valid.

## Out of scope

- New public session-result APIs.
- Changes to lease or recovery ownership.
