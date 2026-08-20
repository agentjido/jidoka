---
id: L36-R1
title: Use closed typed evaluation assertions
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P1
impact: medium
confidence: high
effort: low
blast_radius: medium
dependencies: []
---

# Use closed typed evaluation assertions

## Objective

Reject unknown and empty evaluation assertions before a run starts.

## Evidence

- `lib/jidoka/eval/case.ex:15-25` accepts an open assertion map.
- `lib/jidoka/eval.ex:31-53` recognizes only selected keys.
- `lib/jidoka/eval.ex:76-124` can evaluate an empty recognized set as success.

## Current problem

An unknown assertion key can produce zero checks. The evaluation then passes without
testing the intended condition.

## Proposed representation and invariant

Normalize input into closed contains, equals, or operation-called variants. A case has
at least one recognized assertion. Unknown tags are invalid.

## Smallest credible scope

- Change Eval.Case construction, assertion evaluation, run projection, and JSON normalization.
- Accept valid old map forms through one compatibility normalizer.

## Risks and migration

Custom assertion keys now fail. Preserve supported input and output when possible.
Version external JSON only if it exposes the raw open-map shape.

## Validation

- Run existing eval tests.
- Input: each variant. Expected: same result as current valid maps.
- Input: multiple assertions of one kind. Expected: all run.
- Input: unknown tag or empty assertions. Expected: construction error.
- Input: projected then decoded case. Expected: same variants.

## Acceptance criteria

- No evaluation can pass with zero assertions.
- Unknown assertion input returns a typed error.
- Existing supported assertions remain compatible.

## Out of scope

Do not add expression language or custom assertion plugins.
