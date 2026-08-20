---
id: L21-R2
title: Restrict require_review decisions to operation effects
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P0
impact: high
confidence: high
effort: low
blast_radius: low
dependencies: []
---

# Restrict require_review decisions to operation effects

## Objective

Prevent non-operation effects from becoming false operation-review interrupts.

## Evidence

- `lib/jidoka/policy/gate.ex:51-55` accepts all effect kinds.
- `lib/jidoka/policy/gate.ex:115-122,264-283` builds a review decision and interrupt.
- `lib/jidoka/review/interrupt.ex:11-40` defines only operation-review fields.

## Current problem

`require_review` for an LLM or other non-operation effect produces an interrupt that claims an operation meaning it does not have.

## Proposed representation and invariant

Permit `require_review` only when the gated effect is an operation. For every other effect kind, return a typed unsupported-decision error. Add a typed non-operation review only when its full contract exists.

## Smallest credible scope

- Add effect-kind validation in `policy/gate.ex`.
- Update policy decision validation and error documentation.

## Risks and migration

Policies that return `require_review` for LLM effects will fail closed. This is safer than emitting a false interrupt.

## Validation

Run existing policy-gate tests.

Add cases:

- LLM plus `require_review` -> typed unsupported-decision error;
- operation plus `require_review` -> current review interrupt;
- allow and deny for all effect kinds -> unchanged.

## Acceptance criteria

- Every review interrupt refers to an operation effect.
- Unsupported review decisions fail closed with a typed error.

## Out of scope

- Design of an LLM review contract.
- Changes to operation review UX.
