# AGENTS.md - Jidoka V2

## Intent

This directory contains the Jidoka V2 package. The public module namespace
remains `Jidoka`, and the implementation follows the V2 plan in `JIDOKA_V2.md`.

The old implementation was moved to `../jidoka_v1` and should be treated as the
V1 reference.

## Working Rules

- Keep this package focused on the V2 architecture.
- Preserve the functional-core/effect-shell boundary:
  - pure data transitions in `Jidoka.Workflow.Steps`;
  - external effects through `Jidoka.Effect.Intent`;
  - adapter calls through `Jidoka.Runtime.EffectInterpreter`.
- Do not reintroduce `Jido.AI.ReAct` as the owner of the agent loop.
- Keep tests deterministic with injected runtime capabilities.

## Commands

- `mix deps.get`
- `mix format`
- `mix test`
