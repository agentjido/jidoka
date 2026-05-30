# Jidoka

Jidoka is an opinionated agent harness for the Jido ecosystem.

The V2 package keeps the public namespace `Jidoka`, but starts from a smaller
architecture:

```text
Spark DSL / programmatic input
-> Jidoka.Agent.Spec
-> Jidoka.Turn.Plan
-> Jidoka.Harness
-> Runic workflow
-> Effect.Intent / Effect.Result
-> ReqLLM + Jido.Action
```

Jidoka is Jido-native, but it does not delegate the core loop to
`Jido.AI.ReAct`. A ReAct-style turn is represented as Jidoka data, executed
through the Runic spine, and paused/resumed through explicit snapshots.

## Current Status

This is the V2 kernel. It currently supports:

- Spark DSL agents through `use Jidoka.Agent`;
- JSON/YAML imports through `Jidoka.import/2`;
- Zoi-backed `Agent.Spec`, turn, effect, and snapshot structs;
- model normalization through ReqLLM/LLMDB;
- Jido actions as model-callable tools;
- `input`, `operation`, and `result` controls as data on `Agent.Spec.Controls`;
- runtime execution for input and result controls;
- `max_turns` and `timeout` turn limits under `controls`;
- default process hosting through `Jidoka.Jido` and `Jido.AgentServer`;
- a constrained JSON model-decision protocol;
- a Runic-backed ReAct-style loop;
- hibernate/resume at safe boundaries;
- a small `Jidoka.Extension` behaviour, with trace as the first built-in
  extension;
- neutral `Jidoka.Event` values emitted through `Jidoka.Turn.Transition` and
  projected by the trace extension;
- stable inspection through `Jidoka.inspect/1` and prompt preflight through
  `Jidoka.preflight/3`;
- deterministic unit tests and an opt-in live ReqLLM integration test.

## Quick Start

```elixir
defmodule MyApp.LocalTime do
  use Jidoka.Action,
    name: "local_time",
    description: "Returns the local time for a city.",
    schema: Zoi.object(%{city: Zoi.string()})

  @impl true
  def run(params, _context) do
    city = Map.get(params, :city) || Map.get(params, "city")
    {:ok, %{city: city, time: "09:30"}}
  end
end

defmodule MyApp.TimeAgent do
  use Jidoka.Agent

  agent :time_agent do
    model "openai:gpt-4o-mini"
    instructions "Call local_time when asked for the time."
  end

  tools do
    action MyApp.LocalTime
  end
end

{:ok, text} = MyApp.TimeAgent.chat("What time is it in Chicago?")
```

To run the same agent as a supervised Jido process:

```elixir
{:ok, pid} = MyApp.TimeAgent.start(id: "time-agent-1")
{:ok, result} = Jidoka.run_turn(pid, "What time is it in Chicago?")
{:ok, text} = Jidoka.chat("time-agent-1", "What time is it in Chicago?")
```

The smallest possible DSL agent only needs an id:

```elixir
defmodule MyApp.Assistant do
  use Jidoka.Agent

  agent :assistant
end
```

The equivalent JSON/YAML import can be just as small:

```yaml
agent:
  id: assistant
  model: openai:gpt-4o-mini
```

```elixir
yaml = """
agent:
  id: assistant
  model: openai:gpt-4o-mini
"""

{:ok, spec} = Jidoka.import(yaml)
{:ok, text} = Jidoka.chat(spec, "Hello")
```

For debugging, inspect the compiled agent or preflight the exact prompt without
calling an LLM:

```elixir
Jidoka.inspect(MyApp.Assistant)
{:ok, preflight} = Jidoka.preflight(MyApp.Assistant, "What can you do?")
```

When `model` is omitted, Jidoka uses:

```elixir
config :jidoka,
  default_model: "openai:gpt-4o-mini"
```

## Commands

```bash
mix deps.get
mix compile --warnings-as-errors
mix test
mix test --cover
```

Live ReqLLM integration is opt-in:

```bash
cp .env.example .env
# edit .env with OPENAI_API_KEY or ANTHROPIC_API_KEY
mix test --include live test/jidoka/live_req_llm_test.exs
```

## Guides

- [Getting Started](guides/getting-started.md)
- [Agent DSL](guides/agent-dsl.md)
- [Runtime And Harness](guides/runtime-and-harness.md)
- [Live LLM Tool Loop](guides/live-llm-tool-loop.md)
- [Getting Started Livebook](guides/jidoka_v2_getting_started.livemd)

## Golden Tests

The public DSL-to-spec contract is locked by golden tests in
`test/jidoka/golden/dsl_to_spec_test.exs`. These tests intentionally compare a
stable `Jidoka.projection/1` view of `Agent.Spec` and `Turn.Plan` rather than
the full LLMDB or Spark internals.

## Design Notes

- `Agent.Spec` is immutable definition data, not a process.
- `Turn.Plan` is executable data compiled from the spec.
- `Jidoka.Harness` is the execution boundary for turn requests, resume, context
  validation, runtime, and checkpoint policy.
- `Jidoka.Runtime.TurnRunner` owns the current loop mechanics.
- `Jidoka.Jido` starts the default Jido process substrate for AgentServer-hosted
  Jidoka agents.
- `Effect.Intent` and `Effect.Result` make external work journalable and
  replayable.
- ReqLLM and Jido.Action are first-class runtime dependencies.

Long-form architecture notes live in [JIDOKA_V2.md](JIDOKA_V2.md).
