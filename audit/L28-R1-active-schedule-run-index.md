---
id: L28-R1
title: Active schedule run index
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P2
impact: medium
confidence: high
effort: medium
blast_radius: medium
dependencies: []
---

# Active schedule run index

## Objective

Separate active schedule state from append-only run history.

## Evidence

- `lib/jidoka/workflow/scheduler.ex:67` keeps a history of runs.
- `lib/jidoka/workflow/scheduler.ex:211` appends historical run records.
- `lib/jidoka/workflow/scheduler.ex:278` scans history and calls background
  state to find active work.
- `lib/jidoka/workflow/scheduler.ex:295` cancels historical run IDs.

## Current problem

Each trigger and cancel can scan all old runs and query background state. A
terminal historical run can also be included in cancellation work.

## Proposed representation and invariant

Keep append-only history for evidence and a per-schedule active-run index for
live ownership. Add an active entry when a run starts. Remove it when a run is
terminal. Recovery rebuilds the index from stored history and current background
state. The index must contain only nonterminal runs.

## Smallest credible scope

- `lib/jidoka/workflow/scheduler.ex`.
- Background adapter interaction in `lib/jidoka/adapter/runic/background.ex`.
- Scheduler persistence or snapshot data, if it stores scheduler state.
- Scheduler, background, and reconnectable-workflow tests.

## Risks and migration

Persisted scheduler data may not contain the index. Rebuild it during load.
Define terminal-state handling before removal so recovery does not lose an active
run after a crash. Preserve history order and public history projection.

## Validation

Run existing scheduler, background, and reconnectable-background parity tests.

- Input: large completed history plus one active run. Expected: bounded active
  lookup and one background lookup for that run.
- Input: terminal completion. Expected: active index entry is removed and history
  remains.
- Input: recovered scheduler. Expected: index contains exactly active runs.
- Input: cancel after completed history. Expected: only active run IDs are sent.

## Acceptance criteria

- Active-run lookup does not scan historical records on normal operation.
- Cancellation targets only active runs.
- Recovery rebuilds correct active ownership.
- History remains append-only evidence.

## Out of scope

- History retention policy.
- New scheduler persistence backends.
