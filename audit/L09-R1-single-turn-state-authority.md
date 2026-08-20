---
id: L09-R1
title: Single turn state authority
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P2
impact: medium-high
confidence: high
effort: high
blast_radius: high
dependencies: []
---

# Single turn state authority

## Objective

Remove copied turn state that can diverge during execution or resume.

## Evidence

- `lib/jidoka/turn/state.ex:12` stores `spec` beside `plan.spec`.
- `lib/jidoka/turn/state/operation_planner.ex:69` stores an operation plan beside
  pending effects.
- `lib/jidoka/turn/execution.ex:210` reads and advances turn state.
- `lib/jidoka/adapter/runic/turn_compiler.ex:11` compiles the same turn data for
  the Runic adapter.

## Current problem

`Turn.State.spec` can differ from `Turn.Plan.spec`. An operation plan can differ
from current pending effects and journal evidence. Recovery then has more than
one possible source for the same fact.

## Proposed representation and invariant

`Turn.Plan` owns the immutable specification. Pending effects and journal
evidence own operation progress. `Turn.State` must not store derived copies.
Every fresh and resumed turn must derive the same effective state from these
authorities.

## Smallest credible scope

- `lib/jidoka/turn/state.ex` and `lib/jidoka/turn/state/operation_planner.ex`.
- `lib/jidoka/turn/execution.ex` and `lib/jidoka/loop.ex`.
- `lib/jidoka/adapter/runic/turn_compiler.ex` and operation-batch inputs.
- Turn snapshot codecs, projections, and compatibility normalizers.
- Turn-state, loop, operation-recovery, and snapshot tests.

Persisted turn payloads need a versioned normalizer for old copied fields.

## Risks and migration

Public state shape and durable snapshot shape can change. Old snapshots can
contain conflicting copies. Define one deterministic normalization rule, or
return a typed corruption error where safe normalization is impossible.

## Validation

Run existing turn-state, loop, operation-recovery, Runic, and snapshot tests.

- Input: old state where `state.spec` conflicts with `plan.spec`. Expected:
  documented normalization or typed error.
- Input: old state where operation-plan copy conflicts with pending effects.
  Expected: documented normalization or typed error.
- Input: fresh and resumed equivalent turn. Expected: equal effective state and
  equal next effect.

## Acceptance criteria

- One location owns immutable turn specification.
- One location owns current operation progress.
- No execution path reads a stale copied field.
- Old durable payloads have defined decode behavior.

## Out of scope

- A new public turn-state type hierarchy.
- Changes to effect execution semantics.
