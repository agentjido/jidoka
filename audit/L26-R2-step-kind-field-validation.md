---
id: L26-R2
title: Validate fields by workflow step kind
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P3
impact: medium
confidence: medium
effort: medium
blast_radius: high
dependencies: []
---

# Validate fields by workflow step kind

## Objective

Reject workflow steps that combine fields from incompatible step kinds.

## Evidence

- `lib/jidoka/workflow/step.ex:7-37` defines one struct that permits fields for all step kinds.
- `lib/jidoka/workflow/definition/steps.ex` validates step collections.
- `lib/jidoka/workflow/definition/graph.ex:33-41` assumes a valid step kind.
- `lib/jidoka/workflow/runtime/step_runner.ex:60-122` branches by step kind and reads kind-specific fields.

## Current problem

A step can contain a valid kind plus fields for another kind. Later graph or runtime code must interpret an invalid combination.

## Proposed representation and invariant

Keep the current public `Step` struct and wire tag. Route construction through kind-specific validators that define allowed and required fields.

Invariant: each step has one kind and only fields that belong to that kind.

## Smallest credible scope

- `lib/jidoka/workflow/step.ex`
- Workflow DSL and definition normalizers
- Graph, reference, target, step-runner, adapter, snapshot, and projection tests that construct steps

Old valid `%Step{}` data must normalize. New validation affects public and snapshot input.

## Risks and migration

Direct struct construction is common in tests and user code. Preserve normal forms through a compatibility normalizer. Reject invalid old data with a typed error instead of changing execution behavior.

## Validation

Run existing workflow DSL, lifecycle, graph, and snapshot tests.

Add these cases:

- Each supported kind -> construct, project, and run.
- Cross-kind field -> construction error with field and kind.
- Old valid struct -> normalized result.
- Invalid restored snapshot -> typed error before step execution.

## Acceptance criteria

- No validated step has cross-kind fields.
- Runtime does not receive a structurally invalid step.
- Valid existing workflows remain compatible.

## Out of scope

- Replacing the public struct with a new public tagged hierarchy.
