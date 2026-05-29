# AGENTS.md - Jidoka V2 Spike

## Intent

This directory contains the fresh Jidoka V2 spike. The public module namespace
remains `Jidoka`, but the implementation starts from the V2 plan in
`JIDOKA_V2.md`.

The old implementation was moved to `../jidoka_v1` and should be treated as the
V1 reference.

## Working Rules

- Keep this package focused on the V2 architecture.
- Preserve the functional-core/effect-shell boundary:
  - pure data transitions in `Jidoka.Workflow`;
  - external effects through `Jidoka.Runtime.EffectIntent`;
  - adapter calls through `Jidoka.Runtime.EffectInterpreter`.
- Do not reintroduce `Jido.AI.ReAct` as the owner of the agent loop.
- Keep MVP tests deterministic with injected adapters.

## Commands

- `mix deps.get`
- `mix format`
- `mix test`
