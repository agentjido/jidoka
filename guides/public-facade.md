# Public Facade

Use the `Jidoka` module from application code. It builds, runs, inspects, and
resumes agents.

## Build

Use the DSL for normal agent modules:

```elixir
defmodule MyApp.Assistant do
  use Jidoka.Agent

  agent :assistant do
    model "openai:gpt-4o-mini"
    instructions "Answer clearly and briefly."
  end
end
```

Use `agent/1` when an agent comes from runtime data:

```elixir
{:ok, spec} =
  Jidoka.agent(
    id: "assistant",
    model: "openai:gpt-4o-mini",
    instructions: "Answer clearly and briefly."
  )
```

Use `import/2` for JSON or YAML strings:

```elixir
{:ok, spec} =
  Jidoka.import("""
  agent:
    id: assistant
    model: openai:gpt-4o-mini
    instructions: Answer clearly and briefly.
  """)
```

Use `export/2` when you need portable agent data:

```elixir
{:ok, yaml} = Jidoka.export(MyApp.Assistant, format: :yaml)
```

Use `plan/1` when you want the executable turn data before running:

```elixir
{:ok, plan} = Jidoka.plan(MyApp.Assistant)
```

Reserve `agent!/1` and `plan!/1` for boot paths and tests where invalid data
should raise.

## Run

Use `chat/3` for product code that only needs text:

```elixir
{:ok, text} = Jidoka.chat(MyApp.Assistant, "Draft a short status update.")
```

Use `turn/3` when you need the full result:

```elixir
{:ok, result} =
  Jidoka.turn(MyApp.Assistant, "Draft a short status update.")

result.content
result.events
result.journal.results
```

Both functions accept a DSL module, `Agent.Spec`, `Turn.Plan`, process id, pid,
or session where appropriate.

## Stream For UI

Use `chat_async/3` when a UI needs to start work now and collect events while
the turn runs:

```elixir
{:ok, request} =
  Jidoka.chat_async(MyApp.Assistant, "Write a two paragraph summary.",
    stream: true
  )

stream = Jidoka.stream(request)

for event <- stream do
  if delta = Jidoka.Stream.text_delta(event) do
    IO.write(delta)
  end
end

{:ok, text} = Jidoka.await(request)
```

`stream/2` yields `Jidoka.Event` values. `await/2` returns the same normalized
shape as `chat/3`.

## Keep State

Use sessions for multi-turn conversations:

```elixir
{:ok, session} = Jidoka.session(MyApp.Assistant, "conversation-123")

{:ok, session, text} =
  Jidoka.chat(session, "Remember that my account is A1001.")

{:ok, session, text} =
  Jidoka.chat(session, "Which account did I mention?")
```

Use `session/3` when passing a store or runtime options:

```elixir
{:ok, session} =
  Jidoka.session(MyApp.Assistant, "conversation-123",
    store: {Jidoka.Harness.Store.InMemory, pid: store_pid}
  )
```

## Resume

When a control pauses a turn, `turn/3` returns a snapshot:

```elixir
case Jidoka.turn(MyApp.RefundAgent, "Refund order A1001") do
  {:ok, result} ->
    result.content

  {:hibernate, snapshot} ->
    {:ok, [review]} = Jidoka.pending_reviews(snapshot)
    Jidoka.approve(snapshot, review)
end
```

`resume/2` accepts a snapshot struct, snapshot map, or serialized snapshot
string.

Use `pending_reviews/1`, `approve/3`, and `deny/3` for common approval UI
flows:

```elixir
{:ok, [review]} = Jidoka.pending_reviews(snapshot)

{:ok, result} = Jidoka.approve(snapshot, review)

{:error, reason} =
  Jidoka.deny(snapshot, review, reason: :operator_rejected)
```

Use `resume/2` directly when the application has already built a
`Jidoka.Review.Response`.

## Host In A Process

Use process hosting when the application wants a long-lived, addressable agent:

```elixir
{:ok, _pid} = Jidoka.start_agent(MyApp.Assistant, id: "assistant-1")

{:ok, text} = Jidoka.chat("assistant-1", "Are you running?")

pid = Jidoka.whereis("assistant-1")

:ok = Jidoka.stop_agent("assistant-1")
```

Hosted agents run as `Jido.AgentServer` processes. Turns still use the same
runtime.

## Inspect

Use `preflight/3` for prompt and tool wiring:

```elixir
{:ok, preflight} = Jidoka.preflight(MyApp.Assistant, "What can you do?")
preflight.prompt.messages
```

Use `inspect/2` for a readable compiled view:

```elixir
Jidoka.inspect(MyApp.Assistant)
```

Use `project/1` for data maps in tests, traces, and UI projections:

```elixir
projection = Jidoka.project(MyApp.Assistant.spec())
projection.id
```

## Handle Errors

Use the error helpers at application boundaries:

```elixir
case Jidoka.chat(MyApp.Assistant, "Hello") do
  {:ok, text} ->
    text

  {:error, reason} ->
    Logger.warning(Jidoka.format_error(reason))
    {:error, Jidoka.error_to_map(reason)}
end
```

`error_to_map/1` sanitizes likely credential fields.

## Handoffs

Handoffs are routing state. They tell your application which agent should own
future turns for a conversation:

```elixir
Jidoka.handoff("conversation-123")
#=> nil or %{agent_id: "...", ...}

:ok = Jidoka.reset_handoff("conversation-123")
```

Handoff operations happen inside turns. These helpers only read or clear the
owner state.

## Function Picker

| Need | Use |
| --- | --- |
| Build spec from data | `agent/1` |
| Import JSON/YAML | `import/2` |
| Export JSON/YAML | `export/2` |
| Compile runtime plan | `plan/1` |
| Final text | `chat/3` |
| Full turn result | `turn/3` |
| Async UI request | `chat_async/3` |
| Event stream | `stream/2` |
| Await async result | `await/2` |
| Multi-turn state | `session/2` or `session/3` |
| Continue a paused turn | `resume/2` |
| List pending reviews | `pending_reviews/1` |
| Approve a review | `approve/3` |
| Deny a review | `deny/3` |
| Start hosted process | `start_agent/2` |
| Stop hosted process | `stop_agent/2` |
| Lookup hosted process | `whereis/2` |
| Prompt/tool preflight | `preflight/3` |
| Human-readable inspection | `inspect/2` |
| Data projection | `project/1` |
| Format error string | `format_error/1` |
| Error map for logs/UI | `error_to_map/1` |
| Current handoff owner | `handoff/1` |
| Clear handoff owner | `reset_handoff/1` |

## Testing

Use real providers in product guides and demos. In tests, inject fake
capabilities:

```elixir
llm = fn _intent, _journal ->
  {:ok, %{type: :final, content: "ok"}}
end

assert {:ok, "ok"} = Jidoka.chat(MyApp.Assistant, "ping", llm: llm)
```

See [Testing And Evals](testing-and-evals.md) for operation capabilities,
golden tests, and integration tests.

## Next

- [Getting Started](getting-started.md) - build and run the first agent.
- [Core Concepts](core-concepts.md) - the data model behind the facade.
- [Configuration](configuration.md) - default model, generation, loop, and
  timeout settings.
- [Sessions And Stores](sessions-and-stores.md) - durable conversations.
- [Streaming](streaming.md) - event streams for UI.
