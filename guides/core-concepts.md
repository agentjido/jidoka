# Core Concepts

Read this when a Jidoka term shows up and you need the mental model.

The short version:

```text
DSL or import
-> Agent.Spec
-> Turn.Plan
-> runtime
-> model calls + tool calls
-> Turn.Result or Snapshot
```

Most application code should stay at the `Jidoka` facade: `chat/3`, `turn/3`,
`session/2`, `preflight/3`, and `inspect/2`.

## Authoring Produces Data

The DSL is an authoring layer:

```elixir
defmodule MyApp.Assistant do
  use Jidoka.Agent

  agent :assistant do
    model "openai:gpt-4o-mini"
    instructions "Answer clearly."
  end
end
```

It compiles to `Jidoka.Agent.Spec`:

```elixir
spec = MyApp.Assistant.spec()
spec.id
#=> "assistant"
```

JSON/YAML import produces the same struct:

```elixir
{:ok, spec} =
  Jidoka.import("""
  agent:
    id: assistant
    model: openai:gpt-4o-mini
    instructions: Answer clearly.
  """)
```

Specs are data. They do not contain provider clients, processes, credentials,
sessions, or stores.

## Plans Make Specs Executable

`Jidoka.plan/1` turns a spec into `Jidoka.Turn.Plan`:

```elixir
{:ok, plan} = Jidoka.plan(MyApp.Assistant)

plan.workflow_profile
#=> :tool_loop

plan.max_model_turns
#=> 8
```

Planning validates runtime policy and applies defaults. It still does not call
an LLM.

## Turns Run Through The Runtime

`chat/3` returns the assistant text:

```elixir
{:ok, text} = Jidoka.chat(MyApp.Assistant, "Summarize Jidoka in one sentence.")
```

`turn/3` returns the full result:

```elixir
{:ok, result} =
  Jidoka.turn(MyApp.Assistant, "Summarize Jidoka in one sentence.")

result.content
result.events
result.journal
```

Both calls use the same runtime path. Jidoka normalizes the request, recalls
memory when configured, calls the model, runs requested tools, and returns data.

## Calls Are Recorded

The runtime records external work:

- `:llm` effects call a model through ReqLLM.
- `:operation` effects call tools such as Jido actions, browser tools, MCP
  tools, workflows, or subagents.

Every model or tool call is recorded in the journal:

```elixir
result.journal.intents
result.journal.results
```

That journal is what makes debugging, replay, pause/resume, and idempotency
possible.

## Tools Are Operations

Tools compile to `Jidoka.Agent.Spec.Operation` data:

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
    instructions "Use local_time for time questions."
  end

  tools do
    action MyApp.LocalTime
  end
end
```

Inspect the compiled operation:

```elixir
Jidoka.inspect(MyApp.TimeAgent).operations
#=> [%{name: "local_time", kind: :action, ...}]
```

The model sees one operation contract. The runtime decides how to execute it.

## Snapshots Pause A Turn

Controls can pause a turn for human review:

```elixir
case Jidoka.turn(MyApp.RefundAgent, "Refund order A1001") do
  {:ok, result} ->
    result.content

  {:hibernate, snapshot} ->
    snapshot.metadata["pending_review"]
end
```

Resume continues the saved turn:

```elixir
{:ok, result} = Jidoka.resume(snapshot, approval: approval)
```

Snapshots are serializable data. They do not hold processes or provider
clients.

## Sessions Keep State Across Turns

A single `turn/3` call is stateless. Use sessions for conversations:

```elixir
{:ok, session} = Jidoka.session(MyApp.Assistant, "customer-123")
{:ok, session, text} = Jidoka.chat(session, "Remember my account is A1001.")
{:ok, session, text} = Jidoka.chat(session, "What account did I mention?")
```

Sessions store requests, results, snapshots, pending reviews, and replay data.

## Runtime Flow

At a high level, each turn assembles a prompt, calls the model, runs any tools
the model requests, and returns either an answer or a snapshot. Application
code configures agents through the DSL and runs them through the facade.

## What To Reach For

| Need | Use |
| --- | --- |
| Final text | `Jidoka.chat/3` |
| Full result, events, journal, snapshot | `Jidoka.turn/3` |
| Multi-turn state | `Jidoka.session/2` |
| Prompt/tool inspection | `Jidoka.preflight/3` |
| Compiled agent shape | `Jidoka.inspect/2` |
| Data projection for goldens/UI | `Jidoka.project/1` |
| Human-review continuation | `Jidoka.resume/2` |

## Next

- [Public Facade](public-facade.md) - the top-level API.
- [Agent DSL](agent-dsl.md) - authoring agents.
- [Tools And Operations](tools-and-operations.md) - model-callable work.
- [Runtime And Harness](runtime-and-harness.md) - runtime internals.
- [Snapshots And Resume](snapshots-and-resume.md) - hibernation and review.
