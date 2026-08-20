---
id: L06-R1
title: Make public error projections portable
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P1
impact: medium-high
confidence: high
effort: low
blast_radius: medium
dependencies: []
---

# Make public error projections portable

## Objective

Ensure that `Jidoka.Error.to_map/1` returns a bounded portable data value.

## Evidence

- `lib/jidoka/error/format.ex:35-75` states that formatted errors are serializable.
- `lib/jidoka/error/format.ex:128-163` passes nested tuples and runtime values through sanitization.
- Runtime values can include PIDs, references, and functions that are not portable.

## Current problem

The public error map can contain values that JSON encoders, snapshots, logs, or remote consumers cannot store. The declared wire property is not always true.

## Proposed representation and invariant

Add one bounded portable-value projector for maps, lists, tuples, exceptions, and runtime-only terms.

Invariant: every value returned by `Error.to_map/1` is portable, finite, and safe to encode. Runtime-only values use a stable tagged or string representation.

## Smallest credible scope

- `lib/jidoka/error/format.ex`
- Error normalization and formatter tests
- Public error-map documentation if it states an exact shape

No error struct field needs to change. Only the projected map changes for non-portable details.

## Risks and migration

Existing consumers can inspect exact nested error detail values. Use stable tags and bounded truncation markers. Do not change portable scalar and map values without need.

## Validation

Run existing error-format and error-normalization tests.

Add these cases:

- Nested PID, reference, function, tuple, and exception -> portable map with stable representations.
- Deep or large details -> bounded output with a truncation marker.
- Existing scalar and portable-map examples -> unchanged output.
- Result -> JSON encoding succeeds.

## Acceptance criteria

- `Error.to_map/1` never returns a PID, reference, function, or unbounded nested value.
- Existing normal error output stays compatible.
- Error formatting tests prove JSON-safe output.

## Out of scope

- Changes to error classification or origin fields.
- Logging transport changes.
