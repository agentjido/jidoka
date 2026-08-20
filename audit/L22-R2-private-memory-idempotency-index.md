---
id: L22-R2
title: Keep memory idempotency in a private store index
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

# Keep memory idempotency in a private store index

## Objective

Keep idempotency keys separate from user entry metadata.

## Evidence

- `lib/jidoka/memory/store/in_memory.ex:34-65` stores and scans dedupe data in metadata.
- `lib/jidoka/memory/store/jido_memory.ex:58-75` uses a separate ID and metadata rule.

## Current problem

User metadata can look like internal dedupe evidence. The stores use different key
rules, so dedupe behavior is not portable.

## Proposed representation and invariant

Each store owns a private index from normalized route plus idempotency key to entry
identity. User metadata is opaque and cannot affect idempotency.

## Smallest credible scope

- Change the memory store behaviour if it exposes dedupe details.
- Update InMemory and JidoMemory write paths and persistence or rebuild behavior.
- Keep entry metadata wire shape unchanged.

## Risks and migration

Existing entries have no private index. Choose lazy rebuild, eager migration, or a
documented version boundary. Keep same keys in distinct routes independent.

## Validation

- Run memory unit and integration tests.
- Input: user metadata with former internal-looking key. Expected: no false dedupe.
- Input: same route and true key twice. Expected: one logical write.
- Input: same key in different routes. Expected: independent writes.
- Input: old persisted entries. Expected: documented rebuild or migration result.

## Acceptance criteria

- User metadata cannot create or suppress idempotency.
- Both stores use the same normalized key rule.
- Durable migration behavior is tested and documented.

## Out of scope

Do not change recall results or add distributed locking.
