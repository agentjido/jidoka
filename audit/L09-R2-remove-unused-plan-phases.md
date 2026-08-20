---
id: L09-R2
title: Remove unused turn plan phases
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P3
impact: low-medium
confidence: high
effort: low
blast_radius: medium
dependencies: [L09-R1]
---

# Remove unused turn plan phases

## Objective

Remove turn-plan fields that imply configurable execution but do not control it.

## Evidence

- `lib/jidoka/turn/plan.ex:16` exposes workflow profile and phase fields.
- `lib/jidoka/adapter/runic/turn_compiler.ex:11` builds a fixed sequence.
- `lib/jidoka/turn/plan.ex:61` validates plan data that the compiler does not
  consume.

## Current problem

The public plan model suggests that callers can configure phases. The active
compiler does not use these fields. This gives two models for one fixed process.

## Proposed representation and invariant

Remove unused phase and workflow-profile fields from the active `Turn.Plan`
representation. Inspection should derive phase labels from the fixed compiler.
The plan must contain only data that changes execution.

## Smallest credible scope

- `lib/jidoka/turn/plan.ex`.
- `lib/jidoka/adapter/runic/turn_compiler.ex`.
- Turn projections, inspection output, constructors, and callers.
- Turn, inspection, and stabilization tests.

Use an explicit legacy normalizer if durable or public input still contains the
removed keys.

## Risks and migration

This changes public plan shape. External callers can supply the fields today,
even if they have no effect. Reject them with a typed compatibility error, or
discard them only in a named legacy input path.

## Validation

Run existing turn, inspection, and stabilization tests.

- Input: normal plan. Expected: same compiled fixed sequence.
- Input: removed phase list through current public input. Expected: typed error
  or documented legacy normalization.
- Input: inspection request. Expected: phase labels match the compiler sequence.

## Acceptance criteria

- Every active `Turn.Plan` field affects execution or required public output.
- Inspection does not require a copied phase list.
- Removed-field compatibility behavior is documented and tested.

## Out of scope

- Adding configurable turn phases.
- Changing the fixed Runic sequence.
