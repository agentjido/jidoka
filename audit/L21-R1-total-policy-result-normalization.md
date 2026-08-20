---
id: L21-R1
title: Normalize all policy callback results at one boundary
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P1
impact: high
confidence: high
effort: low
blast_radius: low
dependencies: []
---

# Normalize all policy callback results at one boundary

## Objective

Fail closed and predictably for every malformed policy callback result.

## Evidence

- `lib/jidoka/policy/gate.ex:75-96` accepts policy callback output.
- `lib/jidoka/policy/gate.ex:203-244` has incomplete result matching.

## Current problem

Malformed tuples, thrown values, exits, and exceptions can escape as match errors instead of a defined policy denial.

## Proposed representation and invariant

Add one total normalizer at the callback boundary. It accepts valid `Decision` forms and converts every other return, throw, exit, or exception into one typed fail-closed result.

## Smallest credible scope

- Add a private normalization function in `policy/gate.ex`.
- Reuse existing `Decision` validation where possible.
- Keep only portable, bounded cause data in the failure.

## Risks and migration

Callers that relied on exceptions will now receive a typed denial. Keep useful cause information without leaking nonportable runtime values.

## Validation

Run existing policy-gate tests.

Add cases:

- malformed tuple, map, throw, exit, and exception -> typed denial;
- valid allow, deny, and review decisions -> unchanged results.

## Acceptance criteria

- No policy callback result causes a match error.
- Invalid callback output always fails closed.
- Valid results remain unchanged.

## Out of scope

- New policy callback signatures.
- Changes to policy ordering.
