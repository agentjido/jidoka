---
id: L18-R2
title: Declare durable session storage as none or complete
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

# Declare durable session storage as none or complete

## Objective

Reject partial durable session stores before they can claim work.

## Evidence

- `lib/jidoka/session/store.ex:17-53` declares six lifecycle callbacks as individually optional.
- `lib/jidoka/session/store.ex:81-89,198-213` checks callbacks one at a time.
- `lib/jidoka/session/execution.ex:874-1039` needs the full lifecycle after a claim.

## Current problem

A store can claim a lease but not implement renew, checkpoint, commit, recover, or another required durable operation.

## Proposed representation and invariant

Define two store modes: no durable lifecycle callbacks, or all six callbacks. Validate the mode during startup before a claim. Stores with none use the existing non-durable fallback.

## Smallest credible scope

- Add one capability-set validator in `session/store.ex`.
- Call it from session execution startup.
- Update custom-store documentation and test support.

## Risks and migration

Partial custom stores will now fail configuration. This is intentional. Preserve the non-durable behavior for stores that implement none of the durable callbacks.

## Validation

Run existing in-memory, DETS, and durability tests.

Add cases:

- zero durable callbacks -> non-durable compatibility mode;
- all callbacks -> durable mode;
- each partial callback set -> configuration error before claim.

## Acceptance criteria

- No partial durable store can claim work.
- Mode detection has one owner.
- Existing complete and non-durable stores keep their defined behavior.

## Out of scope

- New store callbacks.
- Changes to lease semantics.
