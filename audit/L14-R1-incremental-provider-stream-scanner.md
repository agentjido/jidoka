---
id: L14-R1
title: Incremental provider stream scanner
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P2
impact: medium
confidence: high
effort: medium
blast_radius: low
dependencies: []
---

# Incremental provider stream scanner

## Objective

Make provider stream normalization linear in input size while preserving events.

## Evidence

- `lib/jidoka/adapter/req_llm/normalized_stream.ex:40` appends accumulated
  content.
- `lib/jidoka/adapter/req_llm/normalized_stream.ex:84` rescans accumulated data.
- `lib/jidoka/adapter/req_llm/normalized_stream.ex:188` repeats prefix decoding
  on the growing value.

## Current problem

Long streams repeatedly copy and decode the same prefix. Small chunks can make
the work grow approximately with the square of total stream size.

## Proposed representation and invariant

Keep an incremental scanner state: reverse iodata or equivalent accumulated
output, decoded event state, and one incomplete suffix. Each input byte is
copied and decoded a bounded number of times. Output event order and provider
error precedence must stay unchanged.

## Smallest credible scope

- `lib/jidoka/adapter/req_llm/normalized_stream.ex`.
- ReqLLM normalized-stream fixtures and tests.

Do not change public event structs or provider wire formats.

## Risks and migration

Chunk boundaries can expose parser errors. Preserve current treatment of partial
frames, empty chunks, tool-call deltas, and provider errors. There is no durable
data migration.

## Validation

Run existing normalized-stream and provider fixture tests.

- Input: current provider fixtures. Expected: exactly the current event sequence.
- Input: the same data one byte per chunk. Expected: same final events.
- Input: a large stream. Expected: linear processed-byte count and no quadratic
  accumulation behavior.
- Input: incomplete final frame and provider error. Expected: current error
  precedence.

## Acceptance criteria

- Scanner state retains only required undecoded suffix data.
- Event order and payloads match existing fixtures.
- Large and small chunk streams have bounded per-byte processing.

## Out of scope

- New provider protocols.
- Changes to request cancellation or event dispatch.
