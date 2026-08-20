---
id: L18-R1
title: Make the lease request ID the current-work authority
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P0
impact: high
confidence: high
effort: high
blast_radius: high
dependencies: [L18-R2]
---

# Make the lease request ID the current-work authority

## Objective

Recover or restart only the request currently claimed by the lease.

## Evidence

- `lib/jidoka/session/lease.ex:15-19` records `request_id` on the lease.
- `lib/jidoka/session/data.ex:137-248` derives current work from several histories.
- `lib/jidoka/session/transitions.ex:272-299` selects recovery data.
- `lib/jidoka/session/execution.ex:737-769` uses recovery selection.
- `lib/jidoka/session/replay.ex:95-125` resumes snapshot data.

## Current problem

If a newer claimed request crashes before its first checkpoint, recovery can select an older request snapshot and resume the wrong work.

## Proposed representation and invariant

Add one `recovery_target/1` decision. It starts with `lease.request_id`, selects only a matching snapshot, or restarts that same request. Inconsistent lease, request, and snapshot data is an explicit failure.

## Smallest credible scope

- Centralize selection in session data or transitions.
- Update session execution and replay callers.
- Define stored-data validation and legacy snapshot behavior.

## Risks and migration

This changes durable recovery behavior. Old records may lack enough identity data. Define a safe migration or fail with an actionable consistency error; never choose an older request silently.

## Validation

Run session atomic-continuation and crash-safe parity tests.

Add cases:

- old completed snapshot plus newer claimed request without checkpoint -> restart newer request;
- matching snapshot -> resume that request;
- mismatched lease and snapshot -> typed consistency error.

## Acceptance criteria

- Recovery never resumes a request other than `lease.request_id`.
- One function owns recovery-target selection.
- Inconsistent durable data is visible and safe.

## Out of scope

- New session storage backends.
- Changes to normal non-recovery execution.
