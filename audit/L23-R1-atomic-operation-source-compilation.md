---
id: L23-R1
title: Compile each operation source once
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P1
impact: high
confidence: high
effort: medium
blast_radius: medium
dependencies: [L16-R1]
---

# Compile each operation source once

## Objective

Create one atomic compiled view for every operation source.

## Evidence

- `lib/jidoka/operation/source.ex:22-119` asks a source for operations, capability, and metadata through separate paths.
- `lib/jidoka/agent/tool_sources.ex:49-58` compiles source views separately.
- `lib/jidoka/agent.ex:146-150` consumes the resulting source data.
- `lib/jidoka/operation/source/mcp.ex:117-195` can run discovery more than once.

## Current problem

Dynamic sources can return different operations, metadata, and routes for one logical source. Repeated discovery costs work and can produce invalid advertised routes.

## Proposed representation and invariant

Return one compiled source snapshot with ordered operations, `routes_by_name`, and metadata. Build it from one discovery. Every advertised operation name has exactly one route; duplicate names are rejected.

## Smallest credible scope

- Change the `Operation.Source` behaviour and source compilation path.
- Update ToolSources, Agent definition, registry, prompt projection, MCP source, and Jido action adapter.
- Provide a compatibility adapter for third-party source implementations if needed.

## Risks and migration

This changes a behaviour contract. Dynamic-source timing becomes snapshot based. Third-party sources need migration, and durable resume may need a source digest check.

## Validation

Run existing source, registry, MCP, deferred-source, and operation tests.

Add cases:

- changing fake source -> one discovery and internally matching views;
- each advertised name -> exactly one route;
- duplicate operation name -> typed error;
- resume with changed source digest -> defined failure.

## Acceptance criteria

- Each source compiles once per use.
- Operations, routes, and metadata come from one snapshot.
- Duplicate names fail before execution.

## Out of scope

- New operation source kinds.
- A general caching service across requests.
