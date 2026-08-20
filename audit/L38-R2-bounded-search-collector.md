---
id: L38-R2
title: Bound text-search collection memory
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P1
impact: high
confidence: high
effort: medium
blast_radius: medium
dependencies: []
---

# Bound text-search collection memory

## Objective

Make result limits also bound in-memory search collection.

## Evidence

- `lib/jidoka/coding_pack/search.ex:201-215` appends file matches.
- `lib/jidoka/coding_pack/search.ex:236-286` builds line matches and applies limits after collection.

## Current problem

A result limit does not limit temporary memory. A large workspace or broad query can
retain all matches before it returns a bounded result set.

## Proposed representation and invariant

Use a deterministic collector that retains no more than result and byte limits while
it continues to count omitted matches. Preserve current order and truncation.

## Smallest credible scope

- Change CodingPack text-search collection helpers only.
- Keep public result shape, total-count meaning, sort order, and error precedence.

## Risks and migration

Ordering changes can affect callers. Define byte accounting. Do not partly retain an
entry unless the current API permits it.

## Validation

- Run existing search and coding integration tests.
- Input: very large match stream. Expected: peak retained count and bytes stay bounded.
- Input: matches above limit. Expected: exact count and stable truncation.
- Input: mixed file errors and matches. Expected: current error precedence.

## Acceptance criteria

- Collector memory is bounded by limits plus fixed overhead.
- Returned matches retain current ordering.
- Counts and truncation remain correct.

## Out of scope

Do not change search syntax or add external indexing.
