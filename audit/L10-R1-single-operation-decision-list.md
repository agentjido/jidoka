---
id: L10-R1
title: Store one operation-decision list
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P1
impact: medium-high
confidence: high
effort: medium
blast_radius: high
dependencies: [L23-R1]
---

# Store one operation-decision list

## Objective

Remove conflicting singular and plural operation decision fields.

## Evidence

- `lib/jidoka/effect/llm_decision.ex:16-31` stores singular name and arguments with operations.
- `lib/jidoka/effect/llm_decision.ex:84-100` reads one decision view.
- `lib/jidoka/effect/model_interaction.ex:108-129` reads another view.
- `lib/jidoka/turn/state.ex:187-198` consumes operation decisions.

## Current problem

Name and arguments can describe one operation while operations describes another set.
Consumers can make different choices.

## Proposed representation and invariant

Store one nonempty ordered operations list. Derive legacy singular accessors from its
first item only. Each item holds its name and arguments together.

## Smallest credible scope

- Change LLMDecision, model interaction, turn transitions, projections, and provider adapters.
- Normalize an old valid singular operation to a list of one.

## Risks and migration

Public and durable decision shapes change. Reject old payloads where singular and
plural data conflict. Preserve parallel operation order.

## Validation

- Run existing ReqLLM decision and parallel-operation tests.
- Input: old singular decision. Expected: normalized list of one.
- Input: conflicting singular and plural fields. Expected: typed validation error.
- Input: multiple operations. Expected: exact source order is preserved.

## Acceptance criteria

- Stored decisions have no independent singular operation fields.
- All consumers read one operations list.
- Old valid payloads pass one normalizer.

## Out of scope

Do not change provider tool-call semantics.
