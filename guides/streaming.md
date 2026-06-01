# Streaming

Every turn can publish events as it runs. Use streaming when a UI needs partial
assistant text, progress events, or a live activity feed.

## Use This When

- a UI needs to render partial assistant text as it is
  produced (chat UIs, CLIs, agent dashboards).
- an operator console wants live progress events.
- do not use streaming as durable telemetry. Live events are best-effort
  and per-request. For post-hoc inspection use
  [Tracing And Events](tracing-and-events.md).

## Prerequisites

- A turn or session you can run with a live provider.
- A consumer process (the caller itself, a `GenServer`, or a LiveView)
  ready to receive mailbox messages.

```bash
mix deps.get
mix test
```

## Stream A Chat

For UI work, start the chat asynchronously and request streaming events.

```elixir
{:ok, request} =
  Jidoka.chat_async(MyApp.SupportAgent, "Hi", stream: true)

stream = Jidoka.stream(request)

for event <- stream do
  if text = Jidoka.Stream.text_delta(event) do
    IO.write(text)
  end
end

{:ok, text} = Jidoka.await(request)
```

The stream yields `Jidoka.Event` values and stops when the turn finishes,
fails, or hibernates.

## Concepts

Streaming is a per-request side channel. The runtime stays terminal-result
oriented.

```diagram
╭───────────────────────╮     ╭──────────────────────╮
│ Jidoka.turn(stream_to:│────▶│  Jidoka.Stream.emit/2│
│   pid, on_event: fun) │     ╰──────┬───────────────╯
╰───────────────────────╯            │
                                     ▼
                         ╭───────────────────────────╮
                         │  Caller mailbox:          │
                         │  {:jidoka_turn_event,     │
                         │   %Jidoka.Event{}}        │
                         ╰──────┬────────────────────╯
                                │
                                ▼
                         ╭───────────────────────────╮
                         │ Receive loop until        │
                         │ Stream.terminal?(event)   │
                         ╰───────────────────────────╯
```

Key facts:

- [`Jidoka.Stream.message_tag/0`](`Jidoka.Stream.message_tag/0`) returns
  `:jidoka_turn_event`. Every mailbox-routed event is the 2-tuple
  `{tag, %Jidoka.Event{}}`.
- [`Jidoka.Stream.terminal?/1`](`Jidoka.Stream.terminal?/1`) returns
  `true` for `:turn_finished`, `:turn_failed`, and `:turn_hibernated`.
  These are the only events that end the stream.
- `:stream_to` may be a pid or `{:pid, pid}`. `:on_event` is a 1-arity
  function called inline; failures are silently ignored so a buggy
  callback never poisons the turn.
- `Jidoka.Stream.text_delta/1` extracts content text from `:llm_delta`
  events. `Jidoka.Stream.thinking_delta/1` does the same for reasoning
  channels.
- `Jidoka.Stream.events/2` builds a mailbox-backed `Stream` enumerable
  scoped to a `request_id`. Use it when you want a lazy enumerable rather
  than a hand-rolled `receive`.

## How To

### Step 1: Stream To A Pid

Pass the consumer process as `:stream_to`. The caller is the simplest
consumer.

```elixir
{:ok, _result} =
  Jidoka.turn(MyApp.SupportAgent, "Hello",
    stream_to: self()
  )
```

Inside a `GenServer`, set `stream_to: self()` from the handler that
issued the turn; the events arrive in `handle_info/2`.

### Step 2: Use The Receive Loop

The terminal-event contract makes the loop trivial.

```elixir
def collect_events(request_id) do
  tag = Jidoka.Stream.message_tag()

  Stream.repeatedly(fn ->
    receive do
      {^tag, %Jidoka.Event{request_id: ^request_id} = event} -> event
    after
      5_000 -> :timeout
    end
  end)
  |> Enum.reduce_while([], fn
    :timeout, acc -> {:halt, Enum.reverse(acc)}
    event, acc -> if Jidoka.Stream.terminal?(event), do: {:halt, Enum.reverse([event | acc])}, else: {:cont, [event | acc]}
  end)
end
```

Always filter on `request_id`. The mailbox tag is shared across turns,
and a parallel turn from the same caller will interleave events.

### Step 3: Render Token Deltas

For chat UIs, the interesting event is `:llm_delta`. Use
`Jidoka.Stream.text_delta/1` to grab the content text.

```elixir
def handle_info({:jidoka_turn_event, %Jidoka.Event{} = event}, state) do
  case Jidoka.Stream.text_delta(event) do
    text when is_binary(text) ->
      {:noreply, append_delta(state, text)}

    nil ->
      {:noreply, state}
  end
end
```

`Jidoka.Stream.thinking_delta/1` is the matching helper for reasoning
channels. Capabilities that emit `:llm_delta` directly should call
`Jidoka.Stream.emit/2` from inside the LLM function.

### Step 4: Use An `on_event` Callback

`:on_event` is a 1-arity function. It runs inline before the next event
is emitted; raised or thrown values are swallowed so the turn keeps
running.

```elixir
{:ok, _result} =
  Jidoka.turn(MyApp.SupportAgent, "Hello",
    on_event: fn event ->
      :telemetry.execute(
        [:my_app, :agent, :event],
        %{seq: event.seq},
        %{event: event.event, agent_id: event.agent_id}
      )
    end
  )
```

`:stream_to` and `:on_event` can be used together. The callback fires
first; the mailbox delivery happens immediately after.

### Step 5: Build A Lazy Enumerable

For consumers that prefer `Enum.reduce/3`, the
`Jidoka.Stream.events/2` helper wraps the receive loop.

```elixir
Task.async(fn ->
  Jidoka.turn(MyApp.SupportAgent, "Hello",
    request_id: "req_demo",
    stream_to: self()
  )
end)

events =
  "req_demo"
  |> Jidoka.Stream.events(stream_event_timeout_ms: 5_000)
  |> Enum.to_list()

Enum.map(events, & &1.event)
```

The enumerable halts when it sees a terminal event for the request or
when the per-event timeout fires.

### Step 6: Stream Through A Session

Sessions accept the same options.

```elixir
{:ok, _session, _text} =
  Jidoka.Session.chat(session_id, "Hi",
    store: store,
    stream_to: self(),
    on_event: &MyApp.Audit.publish/1
  )
```

The terminal events still apply: `:turn_hibernated` ends the stream for
that turn even though the session may continue later.

## Common Patterns

- **Always filter on `request_id`.** Concurrent turns share the mailbox
  tag. Filtering keeps consumers correct under load.
- **Render deltas, log lifecycle.** UIs typically only care about
  `:llm_delta`; observability layers care about `:turn_started`,
  `:turn_finished`, `:turn_failed`.
- **Treat `:turn_hibernated` as a stream terminator.** It is not an
  error; it is a normal pause. Resume separately.
- **Use `on_event:` for in-process side effects.** Mailbox delivery is
  best for cross-process consumers; inline callbacks are best for
  telemetry inside the same process.
- **Do not lean on streaming for state.** Use `Turn.Result` for the final
  truth; use streaming for UX.

## Testing

The runtime's own tests use `assert_receive` against the mailbox tag.

```elixir
test "stream_to publishes lifecycle events" do
  llm = fn _intent, _journal ->
    {:ok, %{type: :final, content: "stream ok"}}
  end

  request = Jidoka.Turn.Request.new!(input: "Hello", request_id: "req_x")

  assert {:ok, %Jidoka.Turn.Result{content: "stream ok"}} =
           Jidoka.turn(MyApp.SupportAgent, request, llm: llm, stream_to: self())

  tag = Jidoka.Stream.message_tag()
  assert_receive {^tag, %Jidoka.Event{event: :turn_started, request_id: "req_x"}}
  assert_receive {^tag, %Jidoka.Event{event: :prompt_assembled, request_id: "req_x"}}
  assert_receive {^tag, %Jidoka.Event{event: :turn_finished, request_id: "req_x"} = terminal}

  assert Jidoka.Stream.terminal?(terminal)
end
```

For UI tests, prefer the `events/2` enumerable so the test runs
deterministically without polling.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| Mailbox receives no events | `:stream_to` was not passed to the turn. | Pass `stream_to: pid` (or `{:pid, pid}`) on the call. |
| Wrong events arrive | Concurrent turns share the mailbox tag. | Match on `request_id` in the receive clause. |
| `:llm_delta` events missing | Capability did not call `Jidoka.Stream.emit/2`. | Emit `:llm_delta` from the LLM function or use a streaming provider. |
| `on_event:` callback errors disappear | Jidoka ignores callback failures so the turn can finish. | Log inside the callback before raising. |
| Loop never terminates | Consumer never saw a terminal event. | Always check `Jidoka.Stream.terminal?/1` and add an `after` timeout. |
| `Jidoka.Stream.events/2` halts immediately | Default `:stream_event_timeout_ms` elapsed before the turn ran. | Increase the timeout, or start the turn before subscribing. |

## Reference

Key modules touched in this guide:

- [`Jidoka.Stream`](`Jidoka.Stream`) - `message_tag/0`, `terminal?/1`,
  `text_delta/1`, `thinking_delta/1`, `events/2`, `emit/2`.
- [`Jidoka.Event`](`Jidoka.Event`) - the struct delivered through the
  stream.
- [`Jidoka.turn/3`](`Jidoka.turn/3`) - accepts `:stream_to` and
  `:on_event`.
- [`Jidoka.Session.run/3`](`Jidoka.Session.run/3`) - forwards the same
  options for session-backed turns.
- [`Jidoka.Runtime.TurnRunner`](`Jidoka.Runtime.TurnRunner`) - emits
  lifecycle events that consumers observe.

## Related Guides

- [Tracing And Events](tracing-and-events.md) - post-hoc projection of
  the same event data.
- [Agent View](agent-view.md) - UI projection that applies streamed
  events to a `Jidoka.AgentView`.
- [Sessions And Stores](sessions-and-stores.md) - streaming through a
  session call.
- [Runtime And Harness](runtime-and-harness.md) - where lifecycle events
  are emitted from.
