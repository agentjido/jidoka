# AGENTS.md - Jidoka

## Intent

This directory contains the official Jidoka package. The public module
namespace is `Jidoka`. The public architecture is documented in `guides/`.

## Working Rules

- Keep this package focused on the documented Jidoka architecture.
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

## Release Hygiene

- Do not modify `CHANGELOG.md`; release notes are generated from Git history during release, so keep changes focused on proper Conventional Commits.
