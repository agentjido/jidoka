---
id: L03-R1
title: Enforce role-specific agent message fields
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P2
impact: medium
confidence: high
effort: medium
blast_radius: medium
dependencies: []
---

# Enforce role-specific agent message fields

## Objective

Ensure that each agent message role contains only its valid fields.

## Evidence

- `lib/jidoka/agent/message.ex:15-30` defines one flat struct with many nullable fields.
- `lib/jidoka/agent/message.ex:111-153` defines structural validation.
- `lib/jidoka/agent/message.ex:165-241` defines semantic validation.
- `lib/jidoka/agent/state.ex:8-39` embeds `Message.schema/0` and can bypass `Message.new/1` semantic validation.

## Current problem

The model permits invalid combinations, such as tool-result fields on a user message. A state built from the schema can avoid the message constructor checks.

## Proposed representation and invariant

Keep the public message struct. Add canonical role constructors and one role-specific validator at every trusted input boundary.

Invariant: a message role has all required fields and no fields that belong only to another role.

## Smallest credible scope

- `lib/jidoka/agent/message.ex`
- `lib/jidoka/agent/state.ex`
- Transcript, turn, adapter, and message tests that construct messages

The public struct stays available. Wire and persisted message input must pass the canonical validator.

## Risks and migration

Some existing callers can construct partial messages directly. Preserve valid legacy shapes through normalization. Reject invalid combinations with stable typed errors.

## Validation

Run existing data-struct, transcript, multimodal, and adapter message tests.

Add these cases:

- Every role -> valid canonical message.
- Irrelevant role field -> validation error.
- Agent.State schema input with invalid role combination -> validation error.
- Existing valid direct struct -> normalized message.

## Acceptance criteria

- State construction cannot bypass role semantics.
- Invalid cross-role field combinations fail before turn planning.
- Existing valid message forms remain accepted.

## Out of scope

- New public message roles.
- Provider-specific message conversion changes.
