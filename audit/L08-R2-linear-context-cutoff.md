---
id: L08-R2
title: Calculate transcript cutoff in one pass
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P3
impact: medium
confidence: high
effort: medium
blast_radius: low
dependencies: []
---

# Calculate transcript cutoff in one pass

## Objective

Make long-transcript compaction use bounded repeated work.

## Evidence

- `lib/jidoka/context_window.ex:41-76` rebuilds candidate message lists.
- `lib/jidoka/context_window.ex:82-119` flattens and encodes remaining messages while it searches.

## Current problem

The cutoff search can repeatedly encode large transcript tails. Long conversations
can have quadratic work.

## Proposed representation and invariant

Walk message groups once. Keep cumulative size evidence and return one oldest
retained-group index. Preserve complete group boundaries and estimator rules.

## Smallest credible scope

- Change only ContextWindow cutoff and compaction helpers.
- Preserve public result, truncation metadata, and token-estimator interface.

## Risks and migration

Group boundary or exact-size behavior can change. Add golden cases before replacement.

## Validation

- Run existing context-window tests.
- Input: large grouped transcript. Expected: same retained groups and metadata.
- Input: group larger than budget. Expected: current documented truncation behavior.
- Instrumented input: many groups. Expected: bounded encode or scan count.

## Acceptance criteria

- Cutoff has one forward group traversal.
- Current fixtures produce equivalent output.
- No partial group is retained.

## Out of scope

Do not change model selection or token estimation.
