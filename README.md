# Jidoka

[![Hex.pm](https://img.shields.io/hexpm/v/jidoka.svg)](https://hex.pm/packages/jidoka)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jidoka/)
[![CI](https://github.com/agentjido/jidoka/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jidoka/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jidoka.svg)](https://github.com/agentjido/jidoka/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

> A data-driven Elixir agent framework for the Jido ecosystem.

Jidoka turns agent definitions into inspectable, resumable model and tool
turns. Use it to build application agents that call LLMs, expose Jido actions,
apply controls, keep conversation state, and pause safely for human review.

```text
Elixir DSL / JSON / YAML
          ↓
  Jidoka.Agent.Spec
          ↓
    Jidoka.Turn.Plan
          ↓
pure workflow steps → effect intents → runtime adapters
          ↓
result / events / journal / snapshot / session
```

Jidoka keeps agent definitions small and keeps runtime state explicit. Model
calls and operations cross one effect boundary, so tests can replace them with
deterministic capabilities.

## Why Jidoka

- **Data first:** the DSL compiles to an immutable `Jidoka.Agent.Spec`.
- **Inspectable:** preflight, events, journals, and projections show how each
  turn was planned and run.
- **Safe to pause:** controls can return a serializable snapshot for review and
  later resume.
- **Deterministic to test:** injected LLM and operation capabilities keep normal
  tests offline.
- **Jido native:** Jido actions, agent processes, browser tools, MCP tools, Ash
  resources, workflows, skills, and subagents can become model operations.
- **Built for applications:** sessions, structured results, memory, streaming,
  handoffs, idempotency policy, and tracing have explicit contracts.

## Installation

Jidoka requires Elixir 1.18 or later.

If your project uses [Igniter](https://hex.pm/packages/igniter), install the
current beta from Hex:

```bash
mix igniter.install jidoka@0.8.0-beta.1
```

For manual installation, add Jidoka to `mix.exs`:

```elixir
def deps do
  [
    {:jidoka, "~> 0.8.0-beta.1"}
  ]
end
```

Then fetch the dependencies:

```bash
mix deps.get
```

Jidoka is beta software. The public API can change before a stable release.

## Quick Start

Define an agent with the Spark DSL:

```elixir
defmodule MyApp.Assistant do
  use Jidoka.Agent

  agent :assistant do
    model "openai:gpt-4o-mini"
    instructions "Answer clearly and briefly."
  end
end
```

Export a provider key before a live call:

```bash
export OPENAI_API_KEY=...
# or
export ANTHROPIC_API_KEY=...
```

Jidoka does not implement dotenv loading. ReqLLM is a Jidoka runtime
dependency, and it loads `.env` from the current working directory by default
when the application starts. Existing system environment values take priority.
For production, disable this behavior and provide credentials through the
deployment environment or a secret manager:

```elixir
# config/runtime.exs
import Config

config :req_llm, load_dotenv: false
```

Call `chat/3` when you need only the final text:

```elixir
{:ok, text} = Jidoka.chat(MyApp.Assistant, "What can you help me with?")
```

Call `turn/3` when you also need usage, events, and the effect journal:

```elixir
{:ok, result} =
  Jidoka.turn(MyApp.Assistant, "What can you help me with?")

result.content
result.usage
result.events
result.journal.results
```

## Add A Tool

A **tool** is work declared in an agent's `tools` block. An **action** is one
Elixir implementation type for a tool. Jidoka normalizes each tool into an
**operation**, which is the contract that the model and runtime use.

```elixir
defmodule MyApp.LocalTime do
  use Jidoka.Action,
    name: "local_time",
    description: "Returns the local time for a city.",
    schema: Zoi.object(%{city: Zoi.string() |> Zoi.default("Chicago")})

  @impl true
  def run(params, _context) do
    city = Map.get(params, :city) || Map.get(params, "city") || "Chicago"
    {:ok, %{city: city, time: "09:30"}}
  end
end

defmodule MyApp.TimeAgent do
  use Jidoka.Agent

  agent :time_agent do
    model "openai:gpt-4o-mini"
    instructions "Use local_time when the user asks for the time."
  end

  tools do
    action MyApp.LocalTime
  end
end

{:ok, preflight} =
  Jidoka.preflight(MyApp.TimeAgent, "What time is it in Chicago?")

preflight.prompt.operations

{:ok, text} =
  Jidoka.chat(MyApp.TimeAgent, "What time is it in Chicago?")
```

The model can request `local_time`. Jidoka validates the arguments, runs the
action, adds the result to agent state, and asks the model for the final answer.

## Choose The Right API

| Need | API |
| --- | --- |
| Final assistant text | `Jidoka.chat/3` |
| Full result, usage, events, and journal | `Jidoka.turn/3` |
| Multi-turn conversation state | `Jidoka.session/2` and `Jidoka.chat/3` |
| Async UI request and event stream | `Jidoka.chat_async/3`, `Jidoka.stream/2`, `Jidoka.await/2`, and `Jidoka.cancel/2` |
| Resume a paused turn | `Jidoka.resume/2` |
| Approve or deny pending work | `Jidoka.approve/3` and `Jidoka.deny/3` |
| Inspect the compiled agent or runtime data | `Jidoka.inspect/2` |
| Assemble a prompt without live effects | `Jidoka.preflight/3` |
| Run under a Jido agent process | `Jidoka.start_agent/2` |
| Import or export portable agent data | `Jidoka.import/2` and `Jidoka.export/2` |

Prefer the `Jidoka` facade in application code. Use the public contract modules
when you build stores, adapters, integrations, or inspection tools.

The main success shapes are:

| Call target | Success shape |
| --- | --- |
| Agent, spec, plan, or hosted agent with `chat/3` | `{:ok, text}` |
| Caller-managed session with `chat/3` | `{:ok, updated_session, text}` |
| Agent, spec, plan, or hosted agent with `turn/3` | `{:ok, %Jidoka.Turn.Result{}}` |
| Paused direct turn | `{:hibernate, snapshot}` |
| Paused caller-managed session | `{:hibernate, updated_session, snapshot}` |

## Inspect Before A Live Call

Preflight validates the request and assembles the prompt without calling a
model or an operation:

```elixir
{:ok, preflight} =
  Jidoka.preflight(
    MyApp.TimeAgent,
    "What time is it in Chicago?"
  )

preflight.prompt.messages
preflight.prompt.operations
preflight.timeline
```

Use `Jidoka.inspect/2` to read the compiled spec and plan:

```elixir
Jidoka.inspect(MyApp.TimeAgent)
```

After a turn, use `Jidoka.Debug.request/2` for a complete request summary:

```elixir
{:ok, summary} = Jidoka.Debug.request(result)

summary.prompt.messages
summary.operation_results
summary.usage
summary.replay_diagnostics.status
```

## Keep State And Pause Safely

Use a session when the same agent must keep state across turns:

```elixir
{:ok, session} = Jidoka.session(MyApp.Assistant, "support-thread-123")

{:ok, session, _text} =
  Jidoka.chat(session, "Remember that my team is called Platform.")

{:ok, session, text} =
  Jidoka.chat(session, "What is my team called?")
```

Controls can stop a turn before unsafe work. A stopped turn returns a snapshot:

```elixir
{:hibernate, snapshot} =
  Jidoka.turn(MyApp.SupportAgent, "Refund order A1001")

approval =
  snapshot.turn_state.pending_interrupt
  |> Jidoka.Review.Response.approve()

{:ok, result} = Jidoka.resume(snapshot, approval: approval)
```

The built-in in-memory stores are for tests and one-node development. Use
application-owned durable stores when state must survive a process or node
failure.

## Author With Data

You can import agents from JSON or YAML:

```yaml
version: 1
agent:
  id: assistant
  model: openai:gpt-4o-mini
  instructions: Answer clearly and briefly.
```

```elixir
{:ok, spec} = Jidoka.import(yaml)
{:ok, text} = Jidoka.chat(spec, "Hello")
```

Import resolves executable references, such as actions, controls, Ash
resources, and Zoi schemas, through explicit registries. Do not resolve
untrusted references without an application policy.

## Production Checklist

Before live traffic:

- set an explicit model, generation settings, turn limit, and timeout;
- keep provider credentials in the host application or release environment;
- apply controls to side-effecting operations;
- select safe idempotency rules for retry and resume;
- persist sessions and snapshots in an application-owned durable store;
- redact sensitive prompt, tool, result, and trace data;
- record provider usage, errors, and terminal turn events;
- keep model and operation concurrency within provider and service limits;
- use deterministic capabilities in the normal test suite;
- keep real-provider checks small and opt-in.

Start with [Configuration](guides/configuration.md),
[Idempotency And Safety](guides/idempotency-and-safety.md), and
[Tracing And Events](guides/tracing-and-events.md).

## Examples

The package includes deterministic reference agents under `examples/`:

```bash
mix run examples/support_agent/example.exs
mix test --only example:support_agent
mix test --only tool_calling
```

The [Support Agent](examples/support_agent/README.md) demonstrates a controlled tool
call, human approval with snapshot resume, and operation-result handling. The
default scenarios do not use provider keys, network calls, or recorded model
fixtures.

The Phoenix showcase application lives in `showcase/`:

```bash
cd showcase
mix deps.get
mix phx.server
```

Standalone Livebooks live in `guides/livebooks/`. Complete examples keep their
Livebook beside their agent code and scenario tests.

## Documentation

Use the [Documentation Overview](guides/documentation-overview.md) to select a
path for application development, production operation, integrations, contract
work, or maintenance.

| Goal | Start here |
| --- | --- |
| Install and run one agent | [Getting Started](guides/getting-started.md) |
| Understand specs, plans, turns, and effects | [Core Concepts](guides/core-concepts.md) |
| Select a public facade function | [Public Facade](guides/public-facade.md) |
| Define agents and tools | [Agent DSL](guides/agent-dsl.md) and [Tools And Operations](guides/tools-and-operations.md) |
| Use sessions and durable stores | [Sessions And Stores](guides/sessions-and-stores.md) |
| Add controls and human review | [Controls](guides/controls.md) and [Human In The Loop](guides/human-in-the-loop.md) |
| Test without live providers | [Testing And Evals](guides/testing-and-evals.md) |
| Verify a real provider loop | [Live LLM Tool Loop](guides/live-llm-tool-loop.md) |
| Prepare a deployment | [Production Operator Path](guides/documentation-overview.md#production-operator-path) |

The complete module reference is available on
[HexDocs](https://hexdocs.pm/jidoka/).

## Development

Run the standard checks from the package root:

```bash
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix quality
mix docs.check
```

Run all example and guide Livebooks with:

```bash
mix run scripts/check_livebooks.exs -- --project examples/*/*.livemd guides/livebooks/*.livemd
```

Live provider tests are opt-in:

```bash
mix test --include live test/jidoka/live_req_llm_test.exs
```

See [Contributing](CONTRIBUTING.md) and
[Contributor Testing](guides/contributor-testing.md) before you submit a
change.

## Project Status

The current package version is `0.8.0-beta.1`. The stable application surface
is centered on the `Jidoka` facade, the agent DSL, and public data contracts.

The runtime uses a provider-neutral JSON decision protocol. Native provider
tool calling, inline workflow syntax, and additional production adapters remain
active design areas.

## License

Jidoka is available under the Apache License 2.0. See [LICENSE](LICENSE).
