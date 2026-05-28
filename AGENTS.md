# AGENTS.md - Jidoka Package Guide

## Intent

This directory contains the `jidoka` Elixir package.

`jidoka` is an opinionated orchestration layer over Jido and Jido.AI for
building developer-friendly LLM agents with a narrow public API.

Jidoka owns the authoring and application-facing layer: DSL compilation, prompt
assembly, runtime context, controls, memory, compaction, delegation, schedules,
inspection, and tracing. Jido and Jido.AI remain the lower runtime foundation
for provider calls, ReAct execution, threads, signals, directives, and durable
runtime storage.

The package currently has two public authoring paths:

- the compile-time Elixir DSL via `use Jidoka.Agent`
- the runtime import path for constrained JSON/YAML agent specs

Both paths describe the same conceptual Jidoka agent.

## Working Rules

- This project tracks work with `bw` (beadwork), which persists plans, progress,
  and decisions to git so they survive compaction, session boundaries, and
  context loss.
- Always run `bw prime` before starting work. Without it, agents miss workflow
  context, current state, and repo hygiene warnings.
- Committing, closing Beadwork issues, and syncing are part of completing a task,
  not separate actions requiring additional permission.
- Prefer changes in this package over changes in vendored dependencies.
- Keep the public Jidoka API small, explicit, and biased toward common agent use
  cases.
- Hide low-level Jido/Jido.AI concepts by default unless there is a clear DX
  reason to expose them.
- Favor compile-time validation for the Elixir DSL and strong runtime
  validation for imported specs.

## Parity Rule

Imported agents are not a side path. They are a first-class Jidoka surface.

When adding a new public Jidoka agent feature, evaluate both authoring paths at
the same time:

- `Jidoka.Agent` should gain the feature in the Elixir DSL when appropriate.
- imported JSON/YAML agents should gain the same feature when it can be
  represented safely in the constrained spec format.
- if the imported-agent path cannot support the feature yet, document that gap
  explicitly in code, tests, and README instead of letting the APIs drift
  silently.

The goal is feature parity by default, with intentional exceptions rather than
accidental divergence.

## Current Scope

Right now the shared public agent shape is intentionally minimal:

- `agent.id`
- optional `agent.description`
- optional compiled context `schema`
- `defaults.instructions`
- optional `defaults.model`
- `capabilities`
- `lifecycle`

The Elixir DSL may expose richer compile-time ergonomics, but the imported
agent format should stay aligned on capability as features are added.

## Commands

Run package commands from this directory:

- `mix deps.get`
- `mix compile`
- `mix test`
- `mix format`

## References

- `README.md`
