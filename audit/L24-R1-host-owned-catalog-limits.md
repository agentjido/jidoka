---
id: L24-R1
title: Make catalog limits host-owned ceilings
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P1
impact: high
confidence: high
effort: medium
blast_radius: medium
dependencies: [L29-R2, L30-R1]
---

# Make catalog limits host-owned ceilings

## Objective

Ensure catalog requests cannot increase host safety limits.

## Evidence

- `lib/jidoka/operation/source/catalog.ex:29-49` exposes request parameters.
- `lib/jidoka/operation/source/catalog.ex:135-155,208-235` merges caller values into catalog settings.
- `lib/jidoka/operation/source/catalog/parameters.ex:27-38` exposes call, parallelism, and timeout values to callers.
- `lib/jidoka/workflow/lua/policy.ex:165-175` treats these values as global safety limits.

## Current problem

A model or request can supply a higher call, parallelism, or timeout limit than the host configured.

## Proposed representation and invariant

Publish the host maximum in the catalog schema. A request can lower or equal the maximum. A value above the maximum returns a typed ceiling error. The host remains the only owner of maxima.

## Smallest credible scope

- Update catalog parameter schema and merge validation.
- Update Lua policy input and error projection.
- Update public schema tests and guide examples.

## Risks and migration

Callers that currently raise limits per request will fail. Do not silently clamp values, because the caller must see the rejected request.

## Validation

Run catalog-source and Lua integration tests.

Add cases for call, parallelism, and timeout limits:

- lower value -> accepted;
- equal value -> accepted;
- higher value -> typed ceiling error.

## Acceptance criteria

- No request can increase a host maximum.
- Schema publishes the maximum.
- Rejections identify the limit and requested value.

## Out of scope

- Changing host default limits.
- Per-tenant quota design.
