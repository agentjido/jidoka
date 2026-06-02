# Jidoka

[![Hex.pm](https://img.shields.io/hexpm/v/jidoka.svg)](https://hex.pm/packages/jidoka)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jidoka/)
[![CI](https://github.com/agentjido/jidoka/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jidoka/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jidoka.svg)](https://github.com/agentjido/jidoka/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

> **A data-driven agent framework for the Jido ecosystem with a Spark DSL and durable turn runtime.**

Jidoka is a small Elixir agent framework for the Jido ecosystem.

Use it when you want an application agent that can call a real LLM, expose
Jido actions as tools, keep turns inspectable, and pause safely for approval or
resume later.

```text
DSL / JSON / YAML
-> Jidoka.Agent.Spec
-> Jidoka.chat / Jidoka.turn / Jidoka.Session
-> model calls + tool calls
-> text, Turn.Result, or snapshot
```

Jidoka keeps the authoring surface narrow: `agent`, `tools`, and `controls`.
The rest is data: specs, requests, results, journals, snapshots, sessions, and
events.

## Install

If your project uses [Igniter](https://hex.pm/packages/igniter), install the
current beta from Hex:

```bash
mix igniter.install jidoka@0.8.0-beta.1
```

For manual installation, add `jidoka` to your dependencies:

```elixir
def deps do
  [
    {:jidoka, "~> 0.8.0-beta"}
  ]
end
```

```bash
mix deps.get
```

Export a provider key before running live examples:

```bash
export OPENAI_API_KEY=...
# or
export ANTHROPIC_API_KEY=...
```

Jidoka does not load `.env` files for applications. Put that policy in your
app, release config, example app, or shell.

Jidoka is beta software. The `0.8.x` beta line is intended for early adopters
while the public API is still allowed to change before a stable release.

## Define An Agent

```elixir
defmodule MyApp.Assistant do
  use Jidoka.Agent

  agent :assistant do
    model "openai:gpt-4o-mini"
    instructions "Answer clearly and briefly."
  end
end

{:ok, text} = MyApp.Assistant.chat("What can you help me with?")
```

Use `chat/3` when you only need the final assistant text. Use `turn/3` when
you need the full result:

```elixir
{:ok, result} = Jidoka.turn(MyApp.Assistant, "What can you help me with?")

result.content
result.events
result.journal.results
```

## Add A Tool

Tools are Jido actions exposed to the model as operations.

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

{:ok, text} = MyApp.TimeAgent.chat("What time is it in Chicago?")
```

The model decides whether to call `local_time`. Jidoka runs the action, feeds
the observation back to the model, and returns the final answer.

## Keep A Conversation

Use `Jidoka.Session` when the same agent should answer across turns.

```elixir
{:ok, session} = Jidoka.session(MyApp.Assistant, "support-thread-123")

{:ok, session, _text} =
  Jidoka.chat(session, "Remember that my team is called Platform.")

{:ok, session, text} =
  Jidoka.chat(session, "What is my team called?")
```

Sessions can run in memory for development and tests, or through a custom
store in production.

## Pause For Approval

Controls run at explicit boundaries. An operation control can pause before a
risky tool call:

```elixir
defmodule MyApp.RequireRefundApproval do
  use Jidoka.Control, name: "require_refund_approval"

  @impl true
  def call(%Jidoka.Runtime.Controls.OperationContext{} = operation) do
    if operation.operation == "refund_order" do
      {:interrupt, :approval_required}
    else
      :cont
    end
  end
end
```

An interrupt returns a snapshot. Store it, review it, then resume:

```elixir
{:hibernate, snapshot} = Jidoka.turn(MyApp.SupportAgent, "Refund order A1001")

approval =
  snapshot.turn_state.pending_interrupt
  |> Jidoka.Review.Response.approve()

{:ok, result} = Jidoka.resume(snapshot, approval: approval)
```

## Inspect Before You Spend Tokens

```elixir
Jidoka.inspect(MyApp.TimeAgent)

{:ok, preflight} =
  Jidoka.preflight(MyApp.TimeAgent, "What time is it in Chicago?")

preflight.prompt.messages
preflight.prompt.tool_definitions
```

`preflight/3` validates the prompt and tool metadata without calling a model.

After a turn, use `Jidoka.Debug.request/2` when you need the full request view
for a user report, notebook, or test:

```elixir
{:ok, result} = Jidoka.turn(MyApp.TimeAgent, "What time is it in Chicago?")
{:ok, summary} = Jidoka.Debug.request(result)

summary.prompt.messages
summary.operation_results
summary.usage
summary.replay_diagnostics.status
```

## Author With Data

Agents can also be imported from JSON or YAML:

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

Executable refs such as actions, controls, Ash resources, and Zoi schemas are
resolved through explicit registries during import.

## Examples And Livebooks

The Phoenix showcase app lives in `example/`.

```bash
cd example
mix deps.get
mix phx.server
```

Livebooks live in `livebook/` and focus on contracts, controls, sessions,
imports, evals, and trace output.

## Test

```bash
mix test
mix test --cover
mix format --check-formatted
```

Live provider tests are opt-in:

```bash
mix test --include live test/jidoka/live_req_llm_test.exs
```

Unit tests should inject fake `llm:` and `operations:` capabilities. Product
guides and examples should use real provider keys.

## Guides

Start here:

- [Getting Started](guides/getting-started.md)
- [Agent DSL](guides/agent-dsl.md)
- [Tools And Operations](guides/tools-and-operations.md)
- [Workflows](guides/workflows.md)
- [Controls](guides/controls.md)
- [Sessions And Stores](guides/sessions-and-stores.md)
- [Inspection And Preflight](guides/inspection-and-preflight.md)
- [Testing And Evals](guides/testing-and-evals.md)

Useful next topics:

- [Structured Results](guides/structured-results.md)
- [Memory](guides/memory.md)
- [Streaming](guides/streaming.md)
- [Import JSON/YAML](guides/import-json-yaml.md)
- [Inspection And Preflight](guides/inspection-and-preflight.md)

## Status

This is the `1.0.0-beta.1` baseline. The public vocabulary is centered on:

- `Jidoka.Agent.Spec`
- `Jidoka.Turn.Request`, `Jidoka.Turn.Plan`, and `Jidoka.Turn.Result`
- `Jidoka.Session`
- `Jidoka.import/2`, `Jidoka.chat/3`, `Jidoka.turn/3`, `Jidoka.resume/2`
- `tools`, `controls`, `memory`, `result`, `trace`, and `eval`

Native provider tool calling, inline workflow sugar, and production
store/runtime adapters are still active design areas.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
