---
id: L29-R1
title: Accept only validated environment selections
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P0
impact: critical
confidence: high
effort: medium
blast_radius: medium
dependencies: [L29-R2]
---

# Accept only validated environment selections

## Objective

Ensure session and manager code can use only an environment registration that the resolver validated.

## Evidence

- `lib/jidoka/execution_environment/profile_resolver.ex:14-25` validates enabled state and capability fit.
- `lib/jidoka/execution_environment/manager.ex:98-131` validates adapter callbacks but not the full profile contract.
- `lib/jidoka/session/environment_runtime.ex:255-288` can pass a raw registration to runtime work.

## Current problem

Raw registrations can bypass the resolver. A disabled, wrong-profile, or insufficient environment can open an adapter.

## Proposed representation and invariant

Add an `ExecutionEnvironment.Selection` value. Only `ProfileResolver` constructs it after identity, enabled-state, profile, and capability validation. Manager and session runtime accept `Selection`, not a raw registration.

## Smallest credible scope

- Add `Selection` near `profile_resolver.ex`.
- Change `manager.ex` and `session/environment_runtime.ex` inputs.
- Update raw-registration call sites and public examples.
- Keep a short compatibility adapter only if public callers require it.

## Risks and migration

Custom callers that pass raw registrations must first resolve them. Do validation before adapter `open/…` so failed selection does not create effects.

## Validation

Run existing resolver, manager, conformance, and session-environment tests.

Add cases:

- disabled registration -> typed error before `open`;
- wrong environment identity -> typed error before `open`;
- malformed profile -> typed error;
- missing capability -> typed error;
- valid resolved selection -> adapter opens once.

## Acceptance criteria

- Manager and session runtime cannot accept raw registrations.
- Only the resolver creates a valid selection.
- All rejected selections fail before adapter effects.

## Out of scope

- New environment profile features.
- Changes to adapter callback semantics.
