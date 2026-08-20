---
id: L35-R1
title: Give async chat one outbound event publisher
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P0
impact: high
confidence: high
effort: medium
blast_radius: medium
dependencies: [L17-R1]
---

# Give async chat one outbound event publisher

## Objective

Make the request controller the only publisher and sequence owner for async chat events.

## Evidence

- `lib/jidoka/runtime/event_dispatcher.ex:16-28` stamps and publishes worker events.
- `lib/jidoka/chat/request_controller.ex:424-438` replaces sequence values and publishes again.
- `lib/jidoka/chat/request_controller.ex:241-399` can hold or replace terminal events.

## Current problem

Extensions can receive a worker terminal event before the caller receives the controller terminal event. Timeout and cancellation can give sinks different terminal events or sequence numbers.

## Proposed representation and invariant

Use a private worker-to-controller relay without external sinks or sequence numbers. The controller assigns the request-local sequence and publishes each event once to mailbox, callback, and extensions.

## Smallest credible scope

- Change event-dispatch options for async workers.
- Update `chat/request_controller.ex`, `runtime/event_dispatcher.ex`, stream handling, and extension dispatch.
- Keep the global dispatcher behavior for direct turns.

## Risks and migration

Event timing and sequence values can change. Preserve direct-turn behavior and document the async request-local sequence rule.

## Validation

Run event-order, request-cleanup, stream, observability, and async parity tests.

Add cases:

- callback and extension receive the same event list and terminal event;
- timeout followed by late worker terminal -> one terminal event on all sinks;
- two equal request IDs in concurrent processes -> separate event sequences.

## Acceptance criteria

- Async chat has one external publisher.
- Every sink sees one ordered terminal event.
- Worker relay events never publish directly.

## Out of scope

- Replacing the global direct-turn sequence service.
- New event transport mechanisms.
