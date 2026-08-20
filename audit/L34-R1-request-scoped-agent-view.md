---
id: L34-R1
title: Scope AgentView updates to the active request
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P2
impact: medium
confidence: high
effort: medium
blast_radius: medium
dependencies: [L17-R1, L35-R1]
---

# Scope AgentView updates to the active request

## Objective

Prevent stale events from changing the view of a later request.

## Evidence

- `lib/jidoka/agent_view.ex:20-36` stores independent status, result, error, and streaming fields.
- `lib/jidoka/agent_view.ex:194-270` accepts generic state updates.
- `lib/jidoka/agent_view/events.ex:46-80` creates or changes a stream on deltas without an active request check.

## Current problem

An event from an old request can update a newer view. Independent fields can also represent contradictory terminal and streaming states.

## Proposed representation and invariant

Keep the public view shape, but add an active request ID and lifecycle checks inside its reducer.

Invariant: only events for the active request can change the view. A request gets one terminal state. Blank input is a no-op.

## Smallest credible scope

- `lib/jidoka/agent_view.ex`
- `lib/jidoka/agent_view/events.ex`
- AgentView and showcase consumer tests

The new request ID is internal unless current view projection already exposes it.

## Risks and migration

Existing callers can send uncorrelated events. Define a compatibility path only for events created by current public APIs. Do not accept stale events silently without observability.

## Validation

Run existing AgentView and showcase tests.

Add these cases:

- Delta from an old request -> ignored.
- Terminal event for active request -> one terminal non-streaming state.
- Blank submit -> unchanged state.

## Acceptance criteria

- Stale events cannot affect the current request view.
- Reducer rejects contradictory lifecycle changes.
- Existing active-request rendering remains valid.

## Out of scope

- Global event sequencing. That is L35-R1.
