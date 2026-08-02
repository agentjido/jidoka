# Workflow Composition Agent

## Purpose

This example shows one fulfillment agent with a complete workflow graph. The
same graph runs directly, as one agent tool, in the background, and from a
schedule.

## Features

```text
typed order
  -> validate
  -> choose priority or standard route
  -> enrich items in parallel
  -> reduce item results
  -> retry inventory reservation
  -> loop over shipment work
       -> create one extra welcome-card item
  -> typed result
```

The example is deterministic. It does not need a provider key or network
access. It uses an injected model function and an in-memory event store.

## Read It In This Order

1. `lib/fulfillment_workflow.ex` - the complete workflow graph.
2. `lib/functions.ex` - small functions used by the graph steps.
3. `lib/agent.ex` - one agent operation that owns the full workflow.
4. `lib/scenario.ex` - direct, background, and scheduled execution.
5. `test/workflow_composition_test.exs` - the behavior authority.
6. `example.exs` - the guided command runner.
7. `workflow_composition.livemd` - the interactive walkthrough.

The agent and workflow modules are application code patterns. The scenario,
scripted model, command runner, manifest, and test make the example repeatable.
Use a durable Runic store instead of the default ETS store when background
runs must survive a VM restart.

## Run It

```bash
mix run examples/workflow_composition/example.exs
mix test --only example:workflow_composition
mix test examples/workflow_composition/test/workflow_composition_test.exs --trace
mix test --only bounded_dynamic_loops
```

Open `workflow_composition.livemd` to inspect the graph and run each execution
form one step at a time.

## Expected Result

The command shows that direct and agent-owned runs return the same result. It
also prints completed background and scheduled run evidence.

## Next Guide

Read [Workflows](../../guides/workflows.md) for the public workflow DSL and
[Tools And Operations](../../guides/tools-and-operations.md) for the agent tool
boundary.
