---
id: L38-R1
title: Compile ignore rules once for each search
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P2
impact: medium
confidence: high
effort: medium
blast_radius: low
dependencies: []
---

# Compile ignore rules once for each search

## Objective

Avoid repeated ignore-file loading and pattern compilation during one search.

## Evidence

- `lib/jidoka/coding_pack/search.ex:110-153` asks ignore logic for each candidate.
- `lib/jidoka/coding_pack/ignore.ex:37-121` loads and evaluates ignore rules.
- `lib/jidoka/coding_pack/ignore.ex:184-204` compiles patterns.

## Current problem

One workspace search can repeatedly read the same ignore files and compile patterns
for thousands of paths.

## Proposed representation and invariant

Build one immutable ignore evaluator at search start. It holds ordered rules and
compiled patterns. A rule-file change affects the next search, not the active search.

## Smallest credible scope

- Change CodingPack search setup and Ignore construction.
- Keep nested ignore-file, negation, and invalid-rule behavior unchanged.

## Risks and migration

Current searches can observe a rule-file change mid-run. The new behavior is a stable
per-operation snapshot. Document this timing rule.

## Validation

- Run existing coding search and integration tests.
- Input: many files with same rules. Expected: one rule load and compile per search.
- Input: change ignore file mid-search. Expected: current search is unchanged.
- Input: new search after change. Expected: new rules apply.

## Acceptance criteria

- Search does not reload or compile unchanged rules per path.
- Current matching and negation fixtures keep the same results.
- Errors keep rule-file and path context.

## Out of scope

Do not add a cross-search cache or file watcher.
