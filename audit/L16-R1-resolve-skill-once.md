---
id: L16-R1
title: Resolve each skill specification once
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P2
impact: medium
confidence: high
effort: medium
blast_radius: low-medium
dependencies: []
---

# Resolve each skill specification once

## Objective

Resolve actions, prompt text, and metadata from one skill snapshot.

## Evidence

- `lib/jidoka/adapter/jido/skill.ex:52` resolves action modules.
- `lib/jidoka/adapter/jido/skill.ex:125` separately builds prompt and metadata.
- `lib/jidoka/agent/tool_sources/skill.ex:14` adds an authoring resolution path.

## Current problem

A skill file or module can change between independent reads. One operation list
can then disagree with its prompt text or metadata. Error handling can also
differ between the separate paths.

## Proposed representation and invariant

Build one ordered resolved-skill value that contains action descriptors, prompt
text, metadata, and source identity. Derive all public views from this value.
One compilation observes one skill snapshot.

## Smallest credible scope

- `lib/jidoka/adapter/jido/skill.ex`.
- `lib/jidoka/agent/tool_sources/skill.ex`.
- The source-compilation input used by L23-R1, if that task is implemented.
- Skill adapter and operation-source tests.

Keep public tool descriptors compatible. This task does not require a new skill
wire format.

## Risks and migration

File-change timing becomes explicit: a change affects the next compilation, not
one view in the active compilation. Preserve current module-resolution errors
and action ordering.

## Validation

Run existing skill and operation-source tests.

- Input: a fake skill that changes after its first read. Expected: one resolution
  and matching actions, prompt, and metadata.
- Input: invalid action module. Expected: one typed resolution error on every
  derived view.
- Input: normal skill. Expected: current action order and prompt output.

## Acceptance criteria

- One compilation performs one skill resolution.
- Actions, prompt, and metadata come from the same resolved value.
- Error behavior and action order remain stable.

## Out of scope

- Runtime hot reload of an already compiled skill.
- Operation-source registry redesign beyond the shared input contract.
