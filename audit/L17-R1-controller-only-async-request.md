---
id: L17-R1
title: Make async chat requests controller-only
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P2
impact: high
confidence: high
effort: medium
blast_radius: medium
dependencies: []
---

# Make async chat requests controller-only

## Objective

Route all await and cancel actions through the request controller.

## Evidence

- `lib/jidoka/chat/request.ex:15-34` exposes a task, controller, and token in one request handle.
- `lib/jidoka/chat/async.ex:16-95` has controller and raw-task await and cancel paths.
- `lib/jidoka/chat/request_controller.ex:77-102` owns lifecycle flags and cleanup state.
- `lib/jidoka/chat/request_controller.ex:241-399` owns terminal handling and cancellation.

## Current problem

A manually built or raw-task handle can bypass controller timeout, cleanup, retention, and terminal-event rules.

## Proposed representation and invariant

Use one opaque controller-backed request handle. Remove raw-task await and cancel fallbacks.

Invariant: every public async request action passes through the controller exactly once.

## Smallest credible scope

- `lib/jidoka/chat/request.ex`
- `lib/jidoka/chat/async.ex`
- `lib/jidoka/chat/request_controller.ex`
- Stream helpers and request tests

The request handle is a public interface. Preserve valid construction paths through a compatibility constructor if needed.

## Risks and migration

Tests or users can construct `%Request{}` directly or inspect its task field. Mark direct construction unsupported or add a versioned constructor. Keep cancellation timing stable.

## Validation

Run existing request cleanup, stream, cancellation, and async parity tests.

Add these cases:

- Handle without controller -> construction or await error.
- Cancel and await -> controller receives both operations.
- Controller cleanup -> no retained task or subscriber.

## Acceptance criteria

- No public request operation uses a raw task fallback.
- Controller remains the only owner of request lifecycle state.
- Existing normal async request behavior remains valid.

## Out of scope

- Event sequencing changes. They are owned by L35-R1.
