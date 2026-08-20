---
id: L27-R1
title: Keep one workflow suspension cursor
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P1
impact: high
confidence: high
effort: medium
blast_radius: high
dependencies: []
---

# Keep one workflow suspension cursor

## Objective

Use one durable cursor for a suspended workflow.

## Evidence

- `lib/jidoka/workflow/runtime/step_runner.ex:302-317` keeps suspension state.
- `lib/jidoka/adapter/runic/workflow.ex:245-264` and `:508-555` keep adapter cursor data.
- `lib/jidoka/workflow/snapshot.ex:13-42` stores `loop_cursor`.

## Current problem

State suspension, suspended outcomes, and snapshot cursor can disagree. Resume then
has no single authority.

## Proposed representation and invariant

The unique suspended outcome owns the cursor. There can be zero or one suspended
outcome. Two outcomes or a mismatched cursor is invalid durable data.

## Smallest credible scope

- Change step runner, Runic workflow adapter, workflow snapshot, and projections.
- Add v1 snapshot decoding into the new one-cursor representation.

## Risks and migration

This changes durable workflow data. Define normalization for old valid data and clear
errors for conflicting old copies.

## Validation

- Run workflow lifecycle, resume, background, and parity tests.
- Input: v1 valid snapshot. Expected: resume at the same step.
- Input: two suspended outcomes. Expected: typed invalid-state error.
- Input: conflicting cursor copies. Expected: typed decode error or documented winner.

## Acceptance criteria

- Fresh snapshots have one cursor authority.
- Resume reads only that authority.
- Legacy valid snapshots remain supported.

## Out of scope

Do not redesign workflow retry policy or Runic scheduling.
