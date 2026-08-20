---
id: T02-R1
title: Bound parity restart wait
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P3
impact: low
confidence: high
effort: low
blast_radius: low
dependencies: []
---

# Bound parity restart wait

## Objective

Make the reconnectable background-workflow parity wait terminate with useful
failure information.

## Evidence

- `test/parity/reconnectable_background_workflow_test.exs:91` calls the restart
  helper.
- `test/parity/reconnectable_background_workflow_test.exs:133` starts recursive
  polling.
- `test/parity/reconnectable_background_workflow_test.exs:143` repeats without a
  monotonic deadline.

## Current problem

When restart does not occur, the helper can poll forever. The test process then
gives no bounded failure or final runner and supervisor state.

## Proposed representation and invariant

Pass a monotonic deadline through the wait helper. Return `:ok` when the target
state appears. At deadline, fail with the last observed runner and supervisor
values. The helper must always terminate.

## Smallest credible scope

- `test/parity/reconnectable_background_workflow_test.exs` only.

Use the existing test time configuration where possible. Do not change runtime
behavior.

## Risks and migration

A too-short deadline can cause intermittent CI failures. Use a deadline that is
consistent with existing integration timeouts and include diagnostic state.

## Validation

Do not run tests in this task.

- Input: restart reaches expected state before deadline. Expected: `:ok`.
- Input: forced nonmatching state. Expected: finite failure with last observed
  values and elapsed deadline.

## Acceptance criteria

- The helper has an explicit monotonic deadline.
- A nonmatching state cannot create an infinite wait.
- Timeout diagnostics identify the last observed state.

## Out of scope

- Runtime scheduler changes.
- General replacement of all test polling helpers.
