---
id: L25-R1
title: Canonical handoff identity
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P2
impact: medium
confidence: medium-high
effort: low-medium
blast_radius: medium
dependencies: []
---

# Canonical handoff identity

## Objective

Make one conversation ID the authority for a handoff and its owner record.

## Evidence

- `lib/jidoka/handoff.ex:17` permits a handoff with a nullable `conversation_id`.
- `lib/jidoka/handoff/owner_store.ex:15` accepts a separate conversation key.
- `lib/jidoka/handoff/owner_store/in_memory.ex:39` stores copied owner fields.

## Current problem

The store key can be conversation A while the handoff says conversation B. The
owner fields then describe different identities. A missing conversation ID also
permits an incomplete handoff value.

## Proposed representation and invariant

Require `conversation_id` in every `Jidoka.Handoff` value. The owner-store key
must equal `handoff.conversation_id`. Store and return one canonical handoff
record. Reject a missing or mismatched ID at the store boundary.

## Smallest credible scope

- `lib/jidoka/handoff.ex`: validate required conversation ID.
- `lib/jidoka/handoff/owner_store.ex`: document and enforce key equality.
- `lib/jidoka/handoff/owner_store/in_memory.ex`: remove or derive copied owner
  identity fields.
- Handoff operation-source callers and handoff tests.

Persisted records without a conversation ID need a decode rule or a migration.
No new public handoff feature is required.

## Risks and migration

Old records can lack `conversation_id`. Decode these records only when the
store key can safely supply the ID; otherwise return a typed migration error.
Existing callers that create incomplete handoffs will fail earlier.

## Validation

Run existing handoff, owner-store, and parity tests.

- Input: store key A and handoff conversation B. Expected: typed mismatch error.
- Input: handoff with no conversation ID. Expected: construction error.
- Input: valid handoff round trip. Expected: returned record has one matching ID.
- Input: old keyed record without an ID. Expected: safe normalization or a clear
  migration error.

## Acceptance criteria

- A created handoff always has a conversation ID.
- Store key and handoff ID cannot differ.
- Owner identity is not copied independently from the handoff identity.
- Tests cover mismatch, missing ID, and round trip behavior.

## Out of scope

- New handoff routing policies.
- Changes to the agent-loop architecture.
