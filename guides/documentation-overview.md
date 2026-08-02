# Documentation Overview

Use this page to select the shortest path through the Jidoka documentation.
You do not have to read the guides in sidebar order.

## Start Here

| Goal | Read first | Read next |
| --- | --- | --- |
| Build your first agent | [Getting Started](getting-started.md) | [Agent DSL](agent-dsl.md) |
| Understand the data and execution model | [Core Concepts](core-concepts.md) | [Public Facade](public-facade.md) |
| Use the stable application API | [Public Facade](public-facade.md) | [Sessions And Stores](sessions-and-stores.md) |
| Prepare a production deployment | [Configuration](configuration.md) | [Idempotency And Safety](idempotency-and-safety.md) |
| Diagnose a failure | [Troubleshooting](troubleshooting.md) | [Inspection And Preflight](inspection-and-preflight.md) |
| Contribute to Jidoka | [Contributor Testing](contributor-testing.md) | [Runic Spine Internals](runic-spine-internals.md) |

## Application Developer Path

Use this path when you build an application with Jidoka:

1. [Getting Started](getting-started.md) - install Jidoka and run one agent.
2. [Agent DSL](agent-dsl.md) - define the model, instructions, tools, and
   controls.
3. [Tools And Operations](tools-and-operations.md) - expose work to the model.
4. [Testing And Evals](testing-and-evals.md) - use deterministic capabilities
   in tests.

Add these guides when the product needs the related feature:

- [Controls](controls.md) and [Human In The Loop](human-in-the-loop.md) for
  policy and human review.
- [Structured Results](structured-results.md) for validated application
  output.
- [Sessions And Stores](sessions-and-stores.md) for durable multi-turn state.
- [Memory](memory.md) for prompt recall and durable writes.
- [Streaming](streaming.md) and [Agent View](agent-view.md) for interactive
  user interfaces.
- [Workflows](workflows.md), [Agent Orchestration](agent-orchestration.md), and
  [Handoffs](handoffs.md) for composed work.
- [Import (JSON/YAML)](import-json-yaml.md) for portable agent definitions.

## Production Operator Path

Use this path when you deploy or operate Jidoka:

1. [Configuration](configuration.md) - configure defaults, credentials, and
   runtime services.
2. [Sessions And Stores](sessions-and-stores.md) - select durable store
   implementations.
3. [Snapshots And Resume](snapshots-and-resume.md) - persist and resume paused
   turns.
4. [Idempotency And Safety](idempotency-and-safety.md) - control replay and
   side effects.
5. [Tracing And Events](tracing-and-events.md) - collect safe operational
   evidence.
6. [Troubleshooting](troubleshooting.md) - diagnose common failures.

The in-memory stores are suitable for tests, examples, and one-node
development. Use application-owned durable stores when session state, memory,
trace data, or handoff ownership must survive process or node loss.

## Integration Path

Read only the integration guides that apply to your system:

- [Live LLM Tool Loop](live-llm-tool-loop.md) - verify a real provider and the
  complete model-operation loop.
- [Jido Process Integration](jido-process-integration.md) - run agents in the
  Jido process tree.
- [AshJido Resources](ash-jido.md) - expose selected Ash resource actions.
- [Browser Tools](browser-tools.md) - expose browser-backed actions.
- [MCP Tools](mcp-tools.md) - load and call remote MCP tools.
- [Skill, Workflow, And Subagent Tools](skill-workflow-subagent-tools.md) -
  expose composed operations.
- [Kino Notebooks](kino-notebooks.md) - use Jidoka in Livebook.

## Contract Reference

Use the contract guides when you serialize data, implement an adapter, or
write compatibility tests:

- [Agent Spec Contract](agent-spec-contract.md)
- [Turn And Effect Contracts](turn-and-effect-contracts.md)
- [Operation Source Contracts](operation-source-contracts.md)
- [Memory Contracts](memory-contracts.md)
- [Import And Snapshot Contracts](import-and-snapshot-contracts.md)
- [Errors And Config Reference](errors-and-config-reference.md)

The module pages are the source for function signatures and types. The guides
explain how the contracts work together.

## Maintainer Path

The internals guides describe implementation boundaries. They are not a
second public API.

1. [Runic Spine Internals](runic-spine-internals.md) - pure turn planning.
2. [Turn Runner And Effect Interpreter](turn-runner-and-effect-interpreter.md) -
   the effect shell and replay boundary.
3. [Runtime Capabilities Internals](runtime-capabilities-internals.md) -
   injected runtime functions and adapters.
4. [Projection Internals](projection-internals.md) - stable debug and UI data.
5. [Contributor Testing](contributor-testing.md) - local quality and test
   commands.

Preserve the main architecture rule: pure transitions belong in the workflow
steps, external work belongs in effect intents, and adapter calls belong in
the effect interpreter.

## Public API And Internals

Prefer the `Jidoka` facade and the documented DSL in application code. Public
data contracts, behaviours, and adapter boundaries are also documented in the
module reference.

Implementation-only Runtime, Adapter, Execution, Projection, Harness, and
Schema module pages are filtered from the normal module index. Maintainers can
use the internals guides and source. The **Advanced Extension Support** group
contains the small set of current runtime and adapter seams that application
guides still require.

## Verify The Documentation

Run these commands before a release:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix docs
mix doctor --raise
```

`mix docs` must complete without warnings. `mix doctor --raise` enforces the
documentation and type-specification thresholds in `.doctor.exs`.

## Help

- [Glossary](glossary.md) defines the common runtime terms.
- [Troubleshooting](troubleshooting.md) maps symptoms to likely causes and
  checks.
- [Inspection And Preflight](inspection-and-preflight.md) shows how to inspect
  an agent without calling a provider.
