---
id: D08-R1
title: Require the latest Lua catalog execution to succeed
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P1
impact: medium
confidence: high
effort: low
blast_radius: low
dependencies: []
---

# Require the latest Lua catalog execution to succeed

## Objective

Make the Lua-tools showcase control check the latest `catalog_execute` result.

## Evidence

- `showcase/lib/jidoka_showcase/lua_tools_agent/controls/require_lua_execution.ex:9-19` accepts any earlier completed execution.
- `showcase/lib/jidoka_showcase/lua_tools_agent/agent.ex:87` installs this control.

## Current problem

An old successful execution can hide a later failed execution. The control accepts a turn that ended with failure.

## Proposed representation and invariant

Select the last `catalog_execute` result in turn order and require that result to be completed.

Invariant: the control decision describes the latest catalog execution, not any historical success.

## Smallest credible scope

- `showcase/lib/jidoka_showcase/lua_tools_agent/controls/require_lua_execution.ex`
- Its unit or showcase integration tests

No public library, persisted, or wire change is required.

## Risks and migration

This changes only showcase control behavior. Existing tests can rely on the old permissive result.

## Validation

Run existing Lua-tools showcase tests.

Add these cases:

- Completed execution then failed execution -> control rejects.
- Failed execution then completed execution -> control accepts.
- No catalog execution -> current expected failure remains unchanged.

## Acceptance criteria

- A later failure always prevents acceptance.
- A later success can recover from an earlier failure.

## Out of scope

- Changes to catalog execution or Lua runtime behavior.
