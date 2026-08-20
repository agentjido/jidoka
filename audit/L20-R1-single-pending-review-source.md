---
id: L20-R1
title: Keep pending review in one source
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P1
impact: high
confidence: high
effort: high
blast_radius: high
dependencies: [L11-R1]
---

# Keep pending review in one source

## Objective

Make `Turn.State.pending_interrupt` the only stored source for pending review.

## Evidence

- `lib/jidoka/turn/state.ex:149` owns `pending_interrupt`.
- `lib/jidoka/snapshot.ex:266-275` copies it into snapshot metadata.
- `lib/jidoka/session/data.ex:327-344` copies it into session data.
- `lib/jidoka/review/execution.ex:50-58` reads a copied value.

## Current problem

Three stored copies can disagree after resume, import, or partial migration.

## Proposed representation and invariant

Keep one pending interrupt in turn state. Derive Review.Request, session lists, and
legacy metadata views from it. A snapshot has one effective interrupt.

## Smallest credible scope

- Change turn-state, snapshot, session-data, and review-execution readers.
- Keep `metadata["pending_review"]` decoding as a legacy compatibility projection.
- Add durable-data normalization only when required.

## Risks and migration

Old data can contain different copies. Define whether turn state wins or decoding
returns a clear conflict error. Keep old read support for the durability window.

## Validation

- Run existing HITL, deferred-source, approval, snapshot, and session tests.
- Input: old payload with only metadata review. Expected: one normalized interrupt.
- Input: conflicting state and metadata. Expected: deterministic result or typed error.
- Input: approve review. Expected: all derived views show no pending review.

## Acceptance criteria

- New snapshots store one authoritative pending interrupt.
- No execution path uses metadata or session copies as authority.
- Old valid snapshots resume without a changed review result.

## Out of scope

Do not redesign review policy or approval identity. L11-R1 owns exact gate approval.
