---
id: L26-R1
title: Use Zoi as workflow parameter schema authority
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P2
impact: medium
confidence: high
effort: low
blast_radius: medium
dependencies: []
---

# Use Zoi as workflow parameter schema authority

## Objective

Use Zoi to create workflow JSON Schema instead of maintaining a partial local encoder.

## Evidence

- `lib/jidoka/workflow/parameters_schema.ex:5-26` contains a local partial schema encoder.
- `lib/jidoka/workflow/definition.ex:45-52` publishes its result.
- `deps/zoi/lib/zoi.ex:523-528` provides `Zoi.to_json_schema/1`.

## Current problem

The local encoder can lose optional fields, defaults, refinements, arrays, and additional-property rules that Zoi already models.

## Proposed representation and invariant

Use `Zoi.to_json_schema/1` as the sole schema encoder. Apply one key-normalization pass only if the Jidoka wire contract requires string keys.

Invariant: workflow parameter schema preserves the semantics of the source Zoi schema.

## Smallest credible scope

- `lib/jidoka/workflow/parameters_schema.ex`
- `lib/jidoka/workflow/definition.ex`
- Workflow definition and DSL schema tests

Published schema output can change for unsupported local cases. There is no persisted workflow-state change.

## Risks and migration

Consumers can depend on current incomplete schema output. Record intentional output differences and update published schema fixtures. Keep stable key types where documented.

## Validation

Run existing workflow DSL and definition tests.

Add these cases:

- Nested required and optional fields -> correct `required` list.
- Default and refined fields -> Zoi output retained.
- Arrays and maps -> valid JSON Schema.
- Published schema -> accepted by a JSON Schema validator.

## Acceptance criteria

- No local recursive schema encoder remains.
- Published workflow schemas preserve Zoi optional, default, and refinement semantics.
- Existing supported schemas remain valid JSON Schema.

## Out of scope

- New workflow parameter types.
- Runtime parameter validation changes.
