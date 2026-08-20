---
id: L22-R1
title: Use one typed memory route
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P2
impact: medium-high
confidence: high
effort: medium
blast_radius: medium
dependencies: []
---

# Use one typed memory route

## Objective

Give all memory stores one unambiguous partition route.

## Evidence

- `lib/jidoka/memory/recall_request.ex:6-17` combines scope and nullable session ID.
- `lib/jidoka/memory/runtime.ex:21-32` and `:109-147` split route handling.
- `lib/jidoka/memory/store/in_memory.ex:79-86` uses scope and session rules.
- `lib/jidoka/memory/store/jido_memory.ex:109-124` uses namespace rules.

## Current problem

The same request can select different data partitions for different stores.

## Proposed representation and invariant

Use a closed route: agent, session, or named namespace. Each route has its required
identity. Runtime and stores receive this route, not loose scope fields.

## Smallest credible scope

- Change RecallRequest, memory runtime, InMemory, JidoMemory, and session call sites.
- Normalize old valid request fields at the public boundary.

## Risks and migration

Ambiguous old requests can fail. Existing stored entries need a defined route mapping.
Do not silently merge session and namespace partitions.

## Validation

- Run memory unit, integration, and continuity parity tests.
- Input: agent, session, namespace routes. Expected: same partition in both stores.
- Input: session route without ID. Expected: typed construction error.
- Input: old valid request. Expected: documented normalized route.

## Acceptance criteria

- Stores do not interpret raw scope fields independently.
- Every route has required identifiers.
- Partition behavior is equal across supported stores.

## Out of scope

Do not change memory ranking, recall scoring, or backend APIs beyond routing.
