---
id: L12-R1
title: Keep one timeout owner for each operation
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P0
impact: high
confidence: high
effort: low
blast_radius: medium
dependencies: []
---

# Keep one timeout owner for each operation

## Objective

Make `CapabilityInvoker` the only owner of per-operation timeout behavior.

## Evidence

- `lib/jidoka/adapter/runic/operation_batch.ex:25-42` sends the capability timeout to Runic as timeout and deadline.
- `lib/jidoka/runtime/capability_invoker.ex:14-78,131-159` already owns task lifecycle and typed timeout behavior.
- `lib/jidoka/runtime/operation_invoker.ex:42-80` calls capability invocation from operation execution.

## Current problem

Runic can time out the outer batch while the capability task has its own timeout. The outer timeout can leave the step runnable and unsafe work can schedule again.

## Proposed representation and invariant

Remove the capability-derived Runic batch timeout. Keep the turn deadline in Runic and keep capability timeout, cancellation, cleanup, and typed errors in `CapabilityInvoker`.

## Smallest credible scope

- Update `adapter/runic/operation_batch.ex` timeout options.
- Confirm `runtime/capability_invoker.ex` remains the sole per-operation timeout owner.
- Update Runic batch and capability tests.

## Risks and migration

Parallel error timing can change. Do not remove the turn-wide deadline or change capability error types.

## Validation

Run existing parallel-operation and capability-invoker tests.

Add cases:

- fast and hung operations -> ordered results with one typed timeout;
- timed-out operation -> runs once only;
- timeout -> no orphan task remains;
- turn deadline -> still stops the batch.

## Acceptance criteria

- One component owns each per-operation timeout.
- A timed-out operation cannot run again from an outer batch retry.
- Turn deadline behavior remains available.

## Out of scope

- Changing configured timeout values.
- Replacing Runic scheduling.
