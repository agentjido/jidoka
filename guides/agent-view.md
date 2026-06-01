# Agent View

`Jidoka.AgentView` is a surface-neutral UI projection. It is not a Phoenix
view, it never renders HTML, and it never owns pids or transcripts. It is
a small data struct that LiveView, CLI examples, channel handlers, jobs,
and tests can use to keep UI state separate from the durable agent
runtime. This guide covers the struct, the `use Jidoka.AgentView` macro,
and the lifecycle hooks for applying turns and streamed events.

## When To Use This

- Use `AgentView` when a UI needs a stable representation of an agent
  conversation that survives renders and resumes.
- Use `AgentView` when you want to share UI state code between LiveView,
  CLI, channels, and tests without binding any of them to a specific
  surface.
- Do not use `AgentView` as a durable transcript store. Persist the
  underlying `Jidoka.Session` or `Jidoka.Turn.Result`; `AgentView` is a
  projection only.

## Prerequisites

- A Jidoka agent module or `Jidoka.Agent.Spec` you want to project.
- Familiarity with `Jidoka.turn/3` and `Jidoka.Event`; see
  [Getting Started](getting-started.md) and
  [Streaming](streaming.md).

```bash
mix deps.get
mix test
```

## Quick Example

The smallest view is `use Jidoka.AgentView, agent: MyAgent`.

```elixir
defmodule MyApp.SupportAgent do
  use Jidoka.Agent

  agent :support_agent do
    instructions "Answer support questions tersely."
  end
end

defmodule MyApp.SupportView do
  use Jidoka.AgentView, agent: MyApp.SupportAgent
end

{:ok, view} = MyApp.SupportView.initial(%{conversation_id: "case_123"})

view.agent_id
#=> "support_agent-case_123"
view.conversation_id
#=> "case_123"
view.runtime_context
#=> %{session: "case_123"}
view.status
#=> :idle
```

The `view` is plain data. Pass it to a LiveView assign, a CLI render, or
a test assertion without changing the contract.

## Concepts

The view is a projection of three things: the agent identity, the visible
messages, and the runtime events that produced them.

```diagram
╭───────────────────────╮     ╭──────────────────────╮
│ use Jidoka.AgentView, │────▶│ MyAgentView module   │
│   agent: MyAgent      │     ╰──────┬───────────────╯
╰───────────────────────╯            │
                                     ▼
                          ╭──────────────────────╮
                          │ AgentView struct     │
                          │ - agent_id           │
                          │ - conversation_id    │
                          │ - runtime_context    │
                          │ - visible_messages   │
                          │ - streaming_message  │
                          │ - events             │
                          │ - status / error     │
                          ╰──────┬───────────────╯
                                 │
                  ╭──────────────┼──────────────╮
                  ▼              ▼              ▼
            before_turn     apply_event     after_turn
            (user msg)      (Jidoka.Event)  (Turn.Result /
                                            snapshot / error)
```

- The struct has `agent_id`, `conversation_id`, `runtime_context`,
  `visible_messages`, `streaming_message`, `events`, `status`, `error`,
  `error_text`, `outcome`, and `metadata`. Nothing more, nothing less.
- `@statuses` is `[:idle, :running, :error, :interrupted, :handoff]`.
  Lifecycle helpers move the view through these statuses deterministically.
- The view never stores a pid, a transcript reference, a provider client,
  process state, or adapter data. Persistence belongs in a session or
  store.
- The `use Jidoka.AgentView` macro defines a default `prepare/1`,
  `agent_module/1`, `conversation_id/1`, `agent_id/1`, and
  `runtime_context/1`, plus convenience functions `initial/2`,
  `before_turn/2`, `after_turn/2`, `apply_event/2`, `run/3`, and
  `visible_messages/1`. Override any of the behaviour callbacks.

## How To

### Step 1: Wire The View Module

`use Jidoka.AgentView, agent: SomeAgent` is the common case. The macro
defaults pick a stable `agent_id` from the spec and a `conversation_id`
from the input.

```elixir
defmodule MyApp.SupportView do
  use Jidoka.AgentView, agent: MyApp.SupportAgent
end

{:ok, view} =
  MyApp.SupportView.initial(%{conversation_id: "VIP Case!"})

view.agent_id
#=> "support_agent-vip_case"
view.conversation_id
#=> "vip_case"
```

For a custom runtime context (tenants, roles, locale), override
`runtime_context/1`:

```elixir
defmodule MyApp.TenantSupportView do
  use Jidoka.AgentView, agent: MyApp.SupportAgent

  @impl true
  def runtime_context(input) do
    %{tenant: Map.fetch!(input, :tenant), session: conversation_id(input)}
  end
end
```

`prepare/1` is a hook for input validation; return `{:error, reason}` to
short-circuit `initial/2`.

### Step 2: Apply A User Message Optimistically

`before_turn/2` adds a pending user message and flips the view to
`:running`. Use it immediately before kicking off a turn so the UI shows
the message without waiting for the agent.

```elixir
view = MyApp.SupportView.before_turn(view, "Look up order A1001")

view.status
#=> :running

Enum.map(view.visible_messages, & &1.role)
#=> [:user]
```

### Step 3: Run A Turn Through The View

`run/3` is the convenience that ties `before_turn`, the actual
`Jidoka.turn/3` call, and `after_turn` together.

```elixir
llm = fn _intent, _journal ->
  {:ok, %{type: :final, content: "Order A1001 is in transit."}}
end

view = MyApp.SupportView.run(view, "Look up A1001", llm: llm)

view.status
#=> :idle

view.visible_messages
#=> [%{role: :user, content: "Look up A1001", pending?: false},
#    %{role: :assistant, content: "Order A1001 is in transit."}]
```

You can also drive the steps manually. This is the right pattern when
the turn runs in a Task, a job, or a `GenServer`.

```elixir
running = MyApp.SupportView.before_turn(view, "Look up A1001")
result = Jidoka.turn(MyApp.SupportAgent, "Look up A1001", llm: llm)
view = MyApp.SupportView.after_turn(running, result)
```

`after_turn/2` matches on `{:ok, Turn.Result}`, `{:hibernate, snapshot}`,
and `{:error, reason}` and sets `status`, `streaming_message`,
`visible_messages`, `outcome`, and `error_text` accordingly.

### Step 4: Consume Streamed Events

For live UIs, pair the view with `stream_to:` from the
[Streaming](streaming.md) guide. Each event updates the view through
`apply_event/2`.

```elixir
def handle_info({:jidoka_turn_event, %Jidoka.Event{} = event}, %{view: view} = state) do
  {:noreply, %{state | view: MyApp.SupportView.apply_event(view, event)}}
end
```

`apply_event/2`:

- appends content deltas (via `Jidoka.Stream.text_delta/1`) to
  `streaming_message`;
- folds reasoning deltas into a "Thinking..." placeholder;
- appends non-delta events to `events` as compact debug projections;
- never reaches into runtime state.

### Step 5: Render From The View

The view is plain data. A LiveView template might assign
`view.visible_messages` and `view.streaming_message`; a CLI might print
them. The view never assumes a surface.

```elixir
def render(assigns) do
  ~H"""
  <div data-status={@view.status}>
    <%= for message <- @view.visible_messages do %>
      <p class={message.role}><%= message.content %></p>
    <% end %>

    <%= if @view.streaming_message do %>
      <p class="assistant streaming">
        <%= @view.streaming_message.content %>
      </p>
    <% end %>
  </div>
  """
end
```

The same `view` data can be asserted on in a test, serialized for an
agent dashboard, or used to drive a CLI repaint.

### Step 6: Persist Beyond The View

The view does not own durability. When the surface session ends, persist
the underlying `Jidoka.Session` (or `Jidoka.Turn.Result`) and rebuild a
fresh view on the next render.

```elixir
{:ok, view} = MyApp.SupportView.initial(%{conversation_id: session_id})

view =
  Enum.reduce(stored_session.requests, view, fn request, view ->
    {:ok, result} = run_or_lookup_result(request)
    MyApp.SupportView.after_turn(view, {:ok, result})
  end)
```

Treat the view as cache, not source of truth. The truth lives in the
session, snapshot, and store.

## Common Patterns

- **One view module per agent.** Keep the view thin and override only
  the callbacks you need. Cross-cutting helpers belong outside the view.
- **Drive UI status from `view.status`.** It is the single field LiveView
  templates, CLI renderers, and channels need to decide what to show.
- **Filter events with `apply_event/2`, not by hand.** It already knows
  how to merge deltas and dedupe events by id.
- **Do not put state into `runtime_context`.** It is request context that
  flows to the agent; use `metadata` for view-local notes.
- **Tests are the cheapest sanity check.** A round-trip
  `initial -> before_turn -> after_turn` assertion catches most regressions.

## Testing

`AgentView` was designed to be unit-testable without any LiveView or HTTP
machinery.

```elixir
test "before/after turn keep visible messages and tool events" do
  llm = fn _intent, _journal ->
    {:ok, %{type: :final, content: "Order A1001 is in transit."}}
  end

  {:ok, view} = MyApp.SupportView.initial(%{conversation_id: "case_123"})

  running = MyApp.SupportView.before_turn(view, " Check order A1001 ")
  assert running.status == :running
  assert [%{role: :user, content: "Check order A1001", pending?: true}] =
           running.visible_messages

  view =
    MyApp.SupportView.after_turn(
      running,
      Jidoka.turn(MyApp.SupportAgent, "Check order A1001", llm: llm)
    )

  assert view.status == :idle
  assert Enum.any?(view.visible_messages, &(&1.role == :assistant))
end
```

For streaming, assert that `apply_event/2` collects text deltas into
`streaming_message` and that `:turn_finished` flips the status back to
`:idle`.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `ArgumentError: must pass agent:` | `use Jidoka.AgentView` was called without `agent:` and `agent_module/1` was not overridden. | Pass the agent on `use`, or override `agent_module/1`. |
| `view.agent_id` looks weird | Conversation id normalizer lower-snakes anything not `[a-z0-9_]`. | Pass a clean id, or override `conversation_id/1`. |
| Streaming text never appears | Callback did not fold events through `apply_event/2`. | Pipe every `{:jidoka_turn_event, _}` message through the view. |
| `after_turn` shows `:error` instead of `:interrupted` | The runtime returned `{:error, _}` rather than `{:hibernate, _}`. | Confirm the operation control returned `{:interrupt, _}`; see [Human In The Loop](human-in-the-loop.md). |
| Duplicate events appear in `view.events` | Multiple sources called `apply_event/2` with the same event. | The view dedupes by id; ensure each event has a stable `request_id`. |

## Reference

Key modules touched in this guide:

- [`Jidoka.AgentView`](`Jidoka.AgentView`) - struct, `@statuses`
  enum, `initial/3`, `before_turn/2`, `after_turn/2`, `apply_event/2`,
  `run/4`, `visible_messages/1`.
- [`Jidoka.AgentView` (behaviour)](`Jidoka.AgentView`) - callbacks
  `prepare/1`, `agent_module/1`, `conversation_id/1`, `agent_id/1`,
  `runtime_context/1`.
- [`Jidoka.Event`](`Jidoka.Event`) - the event shape `apply_event/2`
  consumes.
- [`Jidoka.Stream`](`Jidoka.Stream`) - `text_delta/1`,
  `thinking_delta/1`, the helpers `apply_event/2` calls.
- [`Jidoka.Turn.Result`](`Jidoka.Turn.Result`) - the result `after_turn/2`
  consumes on success.

## Related Guides

- [Streaming](streaming.md) - the event channel `apply_event/2` is built
  to consume.
- [Tracing And Events](tracing-and-events.md) - post-hoc projection of
  the same event data.
- [Sessions And Stores](sessions-and-stores.md) - durable backing for the
  conversation the view projects.
- [Getting Started](getting-started.md) - the agent definition the view
  wraps.
