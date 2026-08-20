---
id: L29-R2
title: Use one complete path-aware contract walker
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

# Use one complete path-aware contract walker

## Objective

Validate all nested execution-environment contract data with one complete walker.

## Evidence

- `lib/jidoka/execution_environment/contract.ex:89-134` contains walkers with different recursion rules.
- `lib/jidoka/execution_environment/contract.ex:148-163` has separate portable-value handling.
- `lib/jidoka/execution_environment/contract.ex:6-25,66-87` defines contract data that can contain nested values.

## Current problem

Nested lists and tuples can escape key, portability, or limit checks because each walker handles a different subset of shapes.

## Proposed representation and invariant

Use one recursive walker for maps, map keys, lists, and tuples. It accepts explicit allowed key and leaf types and returns the full value path on failure. Every nested contract value is checked by that same rule.

## Smallest credible scope

- Replace the overlapping walkers in `execution_environment/contract.ex`.
- Keep current public validation entry points and error category names where possible.

## Risks and migration

Previously accepted nested credentials or negative limits can now fail. Error path text can change. Keep the same top-level error contract if callers depend on it.

## Validation

Run existing contract and restricted-contract tests.

Add cases:

- invalid value in nested map, list, and tuple -> typed error with exact path;
- unsafe nested key -> typed error;
- invalid portable map key -> typed error, not exception;
- valid mixed nesting -> accepted.

## Acceptance criteria

- No contract validation path skips lists or tuples.
- Each error reports the complete path.
- All checks use one walker.

## Out of scope

- New supported value types.
- Changes to environment adapter APIs.
