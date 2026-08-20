---
id: L33-R1
title: Share pure turn preparation between inspection and execution
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P2
impact: medium
confidence: medium-high
effort: high
blast_radius: high
dependencies: [L08-R1, L23-R1]
---

# Share pure turn preparation between inspection and execution

## Objective

Make inspection and execution produce the same prepared turn from the same resolved inputs.

## Evidence

- `lib/jidoka/inspection.ex:99-108` starts inspection preparation.
- `lib/jidoka/inspection.ex:326-364` assembles inspection data through its own path.
- `lib/jidoka/turn/execution.ex:52-73` starts execution preparation.
- `lib/jidoka/turn/execution.ex:248-251` performs separate execution assembly.

## Current problem

Preflight and execution can show different prompts, limits, instructions, memory, or operations for the same logical turn.

## Proposed representation and invariant

Add a deterministic `PreparedTurn` value. Its builder receives resolved operations, instructions, limits, and memory. The execution shell performs effectful discovery and recall before it calls the builder.

Invariant: equal resolved inputs produce equal prepared turn data. Inspection never performs MCP discovery, memory recall, or another external effect.

## Smallest credible scope

- `lib/jidoka/inspection.ex`
- `lib/jidoka/turn/execution.ex`
- New pure preparation module and its tests
- Prompt, instruction, operation, limit, and memory input types as needed

Do not persist `PreparedTurn` unless an existing snapshot contract requires it.

## Risks and migration

Preparation ordering can affect prompts. Keep effect resolution in the shell. Preflight must use explicit resolved inputs or return clear unresolved diagnostics.

## Validation

Run existing inspection, projection, turn-execution, and prompt tests.

Add these cases:

- Equal resolved inputs -> inspection and execution produce equal prepared plan and prompt.
- Inspection with MCP or memory configuration -> no source or store call.
- Missing resolved input -> explicit diagnostic, not an external call.

## Acceptance criteria

- One pure builder owns preparation rules.
- Inspection is effect-free.
- Execution keeps all external work in the effect shell.

## Out of scope

- Moving MCP discovery or memory recall into inspection.
- Changing turn execution ownership.
