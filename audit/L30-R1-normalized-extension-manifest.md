---
id: L30-R1
title: Normalize process extension manifests at handshake
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P1
impact: medium-high
confidence: high
effort: medium
blast_radius: medium
dependencies: [L29-R2]
---

# Normalize process extension manifests at handshake

## Objective

Validate and index a process extension manifest once at handshake time.

## Evidence

- `lib/jidoka/extension/process_host.ex:80-98` validates a raw manifest map.
- `lib/jidoka/extension/process_host.ex:233-275` stores and uses raw manifest data.
- `lib/jidoka/extension/process_host.ex:316-350` reparses data during slot construction.

## Current problem

Handshake can accept data that later operation construction rejects. Names, Boolean
flags, idempotency data, and input policy are read in more than one place.

## Proposed representation and invariant

Construct a typed Manifest during handshake. It has normalized operation names,
indexed entries, Boolean flags, idempotency values, and input policy. Slot building
reads only Manifest. Define one unknown-key policy.

## Smallest credible scope

- Add a private Manifest value at the extension process-host boundary.
- Change handshake, host state, and slot construction.
- Update protocol fixtures and third-party extension contract documentation.

## Risks and migration

Some accepted maps can now fail earlier. Keep supported atom and string wire forms
through one normalizer. Error text can change.

## Validation

- Run process-host, protocol, and extension integration tests.
- Input: duplicate operation name. Expected: handshake validation error.
- Input: non-Boolean flag or bad idempotency. Expected: typed error.
- Input: accepted manifest. Expected: later slot construction does not raise.
- Input: unknown key. Expected: documented allow or reject result.

## Acceptance criteria

- Raw manifests are parsed only at handshake.
- Host state stores a normalized manifest.
- Every accepted manifest can construct advertised slots.

## Out of scope

Do not change extension transport or add new manifest features.
