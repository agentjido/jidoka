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
- operation source contracts that normalize non-action sources onto the same
  operation spine;
- DSL and JSON/YAML import parity for `action`, `ash_resource`, `browser`, and
  `catalog` tool sources;
- `input`, `operation`, and `output` controls as data on `Agent.Spec.Controls`;
- runtime execution for input, operation, and output controls;
- operation controls that match by operation kind, name, source, idempotency,
  and metadata;
- human-in-the-loop operation interrupts through durable approval snapshots;
- ergonomic `Jidoka.Session` facade over harness sessions with a swappable store
  behaviour and in-memory store;
- session replay projections over snapshots, journals, and trace events;
- visible memory recall/write through `Agent.Spec.memory` and memory stores;
- structured result schemas with validated `Turn.Result.value`;
- bounded result repair when model output does not match the declared schema;
- `max_turns` and `timeout` turn limits under `controls`;
- default process hosting through `Jidoka.Jido` and `Jido.AgentServer`;
- a constrained JSON model-decision protocol;
- a Runic-backed ReAct-style loop;
- hibernate/resume at safe boundaries;
- a small `Jidoka.Extension` behaviour, with trace as the first built-in
  extension;
- neutral `Jidoka.Event` values emitted through `Jidoka.Turn.Transition` and
  projected by the trace extension;
- optional trace sinks through `Jidoka.Trace.Sink`, with an in-memory sink and
  trace sampling/redaction policy;
- stable inspection through `Jidoka.inspect/1` and prompt preflight through
  `Jidoka.preflight/3`;
- deterministic eval cases through `Jidoka.Eval.run_case/2`;
- deterministic unit tests and an opt-in live ReqLLM integration test.

Extensions are package/runtime code only. They are not exposed as DSL entities;
the public DSL stays limited to `agent`, `tools`, and `controls`.

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

## Example App

The Phoenix showcase app lives in [`example/`](example). It depends on this
package by path and exposes one LiveView route per agent example.

```bash
cd example
mix deps.get
mix phx.server
```

The example app loads live LLM keys from `.env` files in the package root,
`example/`, or the process environment.

## Livebooks

Advanced deterministic Livebooks live in [`livebook/`](livebook):

- `01_v2_contracts_and_runic_spine.livemd`
- `02_controls_sessions_and_human_review.livemd`
- `03_import_eval_and_trace.livemd`

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

Trace capture is caller-owned:

```elixir
{:ok, pid} = Jidoka.Trace.Sink.InMemory.start_link()
{:ok, result} = Jidoka.run_turn(spec, "Hello", llm: llm)

:ok =
  Jidoka.Trace.record(result.events, {Jidoka.Trace.Sink.InMemory, pid: pid},
    policy: Jidoka.Trace.Policy.new!()
  )
```

Deterministic eval cases use the same harness path:

```elixir
{:ok, run} =
  Jidoka.Eval.run_case(
    [
      id: "assistant_smoke",
      agent: spec,
      input: "Say hello",
      assertions: %{contains: "hello"}
    ],
    llm: llm
  )
```

When `model` is omitted, Jidoka uses:

```elixir
config :jidoka,
  default_model: "openai:gpt-4o-mini"
```

## Human-In-The-Loop

Operation controls may pause a turn before a tool/action runs:

```elixir
defmodule MyApp.RequireApproval do
  use Jidoka.Control, name: "require_approval"

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

An interrupt returns a hibernated snapshot:

```elixir
{:hibernate, snapshot} = Jidoka.run_turn(spec, "Refund order_123", llm: llm, operations: ops)
approval = Jidoka.Review.Response.approve(snapshot.turn_state.pending_interrupt)
{:ok, result} = Jidoka.resume(snapshot, approval: approval, llm: llm, operations: ops)
```

The snapshot contains `snapshot.metadata["pending_review"]` as a
`Jidoka.Review.Request`. Denials and expired approvals fail deterministically
without executing the pending operation.

## Structured Results

Agents may declare a Zoi result schema. The final assistant text remains in
`Turn.Result.content`; the validated application value is available as
`Turn.Result.value`.

```elixir
defmodule MyApp.ProfileAgent do
  use Jidoka.Agent

  agent :profile_agent do
    instructions "Return a short profile summary."

    result schema: Zoi.object(%{
             name: Zoi.string(),
             confidence: Zoi.integer()
           }),
           max_repairs: 1
  end
end

{:ok, result} = MyApp.ProfileAgent.run_turn("Summarize Ada.")
result.value
```

For JSON/YAML imports, result schemas stay data-safe by resolving refs through
`result_schemas` or `registries: %{result_schemas: ...}`.

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

## API Stability

This is the `1.0.0-beta.1` V2 baseline. Stable application-facing concepts are:

- `Jidoka.Agent.Spec` as immutable agent definition data;
- `Jidoka.Turn.Plan`, `Jidoka.Turn.Request`, and `Jidoka.Turn.Result`;
- `Jidoka.Session` for app-facing session workflows;
- `Jidoka.Harness` for execution, resume, stores, replay, and memory internals;
- `Jidoka.Effect.Intent` / `Jidoka.Effect.Result` for external work;
- `controls`, `operations`, `result`, `memory`, `trace`, and `eval` vocabulary.

Current versioned data boundaries are import document `version: 1`, snapshot
`schema_version: 1`, serialized snapshot prefix `jidoka:snapshot:v1:`, and
harness session `schema_version: 1`.

Production store/runtime integrations, handoffs, workflow DSL, MCP sources, and
native provider tool-calling are still future surfaces.

## Guides

- [Getting Started](guides/getting-started.md)
- [Agent DSL](guides/agent-dsl.md)
- [Controls](guides/controls.md)
- [Structured Results](guides/structured-results.md)
- [Runtime And Harness](guides/runtime-and-harness.md)
- [Live LLM Tool Loop](guides/live-llm-tool-loop.md)
- [Migration From V1](guides/migration-from-v1.md)
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
- Operation idempotency is explicit; `:unsafe_once` operations require an
  operation control and incomplete unsafe intents are not retried automatically.
- ReqLLM and Jido.Action are first-class runtime dependencies.

Long-form architecture notes live in [JIDOKA_V2.md](JIDOKA_V2.md).
Milestone release notes live in [CHANGELOG.md](CHANGELOG.md).
