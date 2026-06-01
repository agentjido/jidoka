# Tracing And Events

Every important transition in a Jidoka turn produces a `Jidoka.Event`.
Events are neutral data that applications can inspect, sample, redact, and
forward. This guide covers the event shape, the trace projection in
`Jidoka.Trace`, sampling and redaction with `Jidoka.Trace.Policy`, and writing
a `Jidoka.Trace.Sink`.

## When To Use This

- Use trace projections when you want a compact, sequence-stable timeline
  of what an agent did, suitable for logging or operator UIs.
- Use a trace sink when you want a caller-owned location (an `Agent`, a
  database table, a log sink) to receive projected entries.
- Do not use tracing as a replacement for `Jidoka.Stream`. The trace path
  is post-hoc projection; live event streaming is described in
  [Streaming](streaming.md).

## Prerequisites

- A turn or session that produces events. Any
  `Jidoka.turn/3`/`Jidoka.Session.run/3` call qualifies.
- For sinks: an in-process `Jidoka.Trace.Sink.InMemory` agent, or a module
  implementing `Jidoka.Trace.Sink`.

```bash
mix deps.get
mix test
```

## Quick Example

Run a turn, project its events through a policy, and inspect the timeline.

```elixir
llm = fn _intent, _journal ->
  {:ok, %{type: :final, content: "done"}}
end

{:ok, result} = Jidoka.turn(MyApp.SupportAgent, "Hello", llm: llm)

policy =
  Jidoka.Trace.Policy.new!(
    sample_rate: 1.0,
    redact_keys: [:api_key, :authorization],
    omit_keys: [:messages, :prompt]
  )

timeline = Jidoka.Trace.timeline(result.events, policy: policy)
Enum.map(timeline, & &1.event)
#=> [:turn_started, :prompt_assembled, :effect_planned, :effect_started,
#    :capability_call_started, :capability_call_completed,
#    :effect_completed, :turn_finished]
```

The same `result.events` feeds replay, agent views, sinks, and ad-hoc
inspection without re-running the turn.

## Concepts

Events flow out of the workflow as raw data. `Jidoka.Trace` handles projection,
sampling, and redaction when callers want a timeline.

```diagram
╭───────────────────╮     ╭─────────────────────╮     ╭──────────────╮
│ Turn.Transition   │────▶│   Jidoka.Event       │────▶│ result.events│
╰───────────────────╯     ╰────────┬─────────────╯     ╰──────┬───────╯
                                   │                          │
                                   ▼                          ▼
                         ╭───────────────────╮     ╭───────────────────╮
                         │ Jidoka.Stream     │     │ Jidoka.Trace      │
                         │ (live mailbox)    │     │ (timeline + policy)│
                         ╰───────────────────╯     ╰──────┬─────────────╯
                                                          │
                                                          ▼
                                                ╭─────────────────────╮
                                                │ Jidoka.Trace.Sink   │
                                                │ (caller-owned)      │
                                                ╰─────────────────────╯
```

- A [`Jidoka.Event`](`Jidoka.Event`) carries `seq`, `event`, `category`,
  `phase`, `status`, `agent_id`, `request_id`, `loop_index`, `effect_id`,
  `effect_kind`, `operation`, `data`, and `error`. Defaults are filled
  from a table keyed by event name.
- Event names include workflow lifecycle (`:turn_started`,
  `:prompt_assembled`, `:turn_finished`, `:turn_failed`,
  `:turn_hibernated`), effect lifecycle (`:effect_planned`,
  `:effect_started`, `:effect_replayed`, `:effect_completed`,
  `:effect_failed`), capability lifecycle
  (`:capability_call_started/completed/failed`), control lifecycle
  (`:control_allowed/blocked/interrupted/failed`), review lifecycle
  (`:approval_requested/responded/applied`), result validation, memory, and
  `:llm_delta` for streamed tokens.
- Categories are `:workflow`, `:effect`, `:runtime`, `:operation`,
  `:control`, `:approval`, `:result`, and `:memory`. Phases partition the
  workflow into `:start`, `:control`, `:review`, `:memory`,
  `:assemble_prompt`, `:plan_model_effect`, `:interpret_effect`,
  `:validate_result`, `:apply_operation_results`, and `:finish`.
- [`Jidoka.Trace`](`Jidoka.Trace`) projects events into compact maps. It
  is stateless; the runtime emits events and callers decide whether to trace.
- [`Jidoka.Trace.Policy`](`Jidoka.Trace.Policy`) is data that controls
  whether projection runs at all (`enabled`), how aggressively to sample
  (`sample_rate`), and which keys to omit or redact.
- [`Jidoka.Trace.Sink`](`Jidoka.Trace.Sink`) is the small behaviour for
  forwarding projected entries; sinks never see provider clients or
  credentials.

## How To

### Step 1: Read Events From A Result

`Turn.Result.events` already holds the canonical event list for a turn.

```elixir
{:ok, result} = Jidoka.turn(MyApp.SupportAgent, "Hello", llm: llm)

Enum.map(result.events, & &1.event)
#=> [:prompt_assembled, :effect_planned, :effect_started,
#    :capability_call_started, :capability_call_completed,
#    :effect_completed, :turn_finished]
```

For projections that include `:turn_started`, use `Jidoka.Trace.timeline/2`
with the events you have collected.

### Step 2: Build A Policy

A default policy redacts common secret keys and omits prompt-heavy fields.
Adjust as needed.

```elixir
policy =
  Jidoka.Trace.Policy.new!(
    enabled: true,
    sample_rate: 0.25,
    redact_keys: ["api_key", "authorization", "token"],
    omit_keys: ["messages", "prompt", "raw_response"]
  )

Jidoka.Trace.Policy.default_redact_keys()
#=> ["api_key", "authorization", "bearer", "password", "secret", "token"]
```

Policies are coerced from keyword lists or maps wherever
`Jidoka.Trace.timeline/2`, `Jidoka.Trace.record/3`, or
`Jidoka.Trace.redact/2` accepts a `:policy`.

### Step 3: Project A Timeline

The timeline is a sorted, projected, sampled, redacted list of maps. It is
safe to log directly.

```elixir
timeline = Jidoka.Trace.timeline(result.events, policy: policy)

for entry <- timeline do
  Logger.info("event=#{entry.event} seq=#{entry.seq}")
end
```

Each entry includes `:projection => :trace` so downstream pipelines can route
on origin. Sampling is deterministic on
`{request_id, seq, event}` so the same trace projects the same subset
across reruns.

### Step 4: Record Into A Sink

The in-process sink is enough for tests, examples, and ad-hoc local use.

```elixir
{:ok, pid} = Jidoka.Trace.Sink.InMemory.start_link()
sink = {Jidoka.Trace.Sink.InMemory, pid: pid}

:ok = Jidoka.Trace.record(result.events, sink, policy: policy)

Jidoka.Trace.Sink.InMemory.list(pid)
```

`record/3` projects, samples, and redacts before the sink ever sees an
entry. Sinks are caller-owned; the runtime never reaches them directly.

### Step 5: Implement A Custom Sink

Implement `Jidoka.Trace.Sink` and accept whatever transport opts you need.

```elixir
defmodule MyApp.LoggerTraceSink do
  @behaviour Jidoka.Trace.Sink

  @impl true
  def record(entries, %Jidoka.Trace.Policy{}, _opts) when is_list(entries) do
    for entry <- entries do
      Logger.info(fn -> "trace " <> inspect(entry) end)
    end

    :ok
  end
end
```

Wire it the same way as any other sink:

```elixir
:ok = Jidoka.Trace.record(result.events, MyApp.LoggerTraceSink, policy: policy)
```

### Step 6: Reach Through Replay

For a session that has produced multiple turns, the replay projection
already calls `Jidoka.Trace.timeline/2` under the hood.

```elixir
{:ok, replay} = Jidoka.Session.replay(session)
replay.timeline
```

This is the cheapest way to get a stable timeline for a session without
caring about which snapshot produced which events.

## Common Patterns

- **Project once, record many.** Projected entries are plain maps and can
  be sent to multiple sinks without re-projection.
- **Treat events as the source of truth.** The runtime only emits, never
  consumes, events. Build all observability on `result.events` or the
  streamed mailbox path.
- **Use deterministic sampling.** Because sampling hashes on
  `{request_id, seq, event}`, the same partial trace shows up on every
  re-projection. Avoid time-based sampling in tests.
- **Keep redact lists conservative.** Add domain-specific keys rather
  than relaxing defaults.
- **Pair traces with structured logging.** A compact projected entry is
  the easiest shape to log; the raw `Jidoka.Event` is the right shape
  for tests.

## Testing

Use the in-memory sink and a deterministic LLM to assert on the projected
timeline.

```elixir
test "in-memory sink records projected entries" do
  llm = fn _intent, _journal ->
    {:ok, %{type: :final, content: "done"}}
  end

  {:ok, result} = Jidoka.turn(MyApp.SupportAgent, "Hello", llm: llm)

  {:ok, pid} = Jidoka.Trace.Sink.InMemory.start_link()
  sink = {Jidoka.Trace.Sink.InMemory, pid: pid}

  policy = Jidoka.Trace.Policy.new!(sample_rate: 1.0)

  assert :ok = Jidoka.Trace.record(result.events, sink, policy: policy)

  entries = Jidoka.Trace.Sink.InMemory.list(pid)
  assert Enum.any?(entries, &(&1.event == :turn_finished))
  refute Enum.any?(entries, &Map.has_key?(&1.data, :prompt))
end
```

For redaction tests, build an event with a known sensitive value and
assert it round-trips through `Jidoka.Trace.redact/2`.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `Jidoka.Trace.timeline/2` returns `[]` | Policy `enabled: false` or `sample_rate: 0.0`. | Set `enabled: true` and a positive sample rate. |
| Sensitive values appear in entries | Key is not in `redact_keys` or `omit_keys`. | Extend the policy with the offending key (string form). |
| Sink returns `{:error, {:invalid_trace_sink, _}}` | Module is missing or lacks `record/3`. | Ensure the module compiles and implements `Jidoka.Trace.Sink`. |
| `:llm_delta` entries are missing | Provider/capability never emitted delta events. | Provide them through `Jidoka.Stream.emit/2`; see [Streaming](streaming.md). |
| `seq` ordering looks wrong across requests | Sequences are per-request, not global. | Group by `request_id` before sorting on `seq`. |

## Reference

Key modules touched in this guide:

- [`Jidoka.Event`](`Jidoka.Event`) - core event struct, defaults table,
  `events/0`, `build/3`, `to_map/1`.
- [`Jidoka.Trace`](`Jidoka.Trace`) - `timeline/1`, `timeline/2`,
  `record/3`, `redact/2`.
- [`Jidoka.Trace.Policy`](`Jidoka.Trace.Policy`) - projection policy data
  with `default_redact_keys/0` and `default_omit_keys/0`.
- [`Jidoka.Trace.Sink`](`Jidoka.Trace.Sink`) - behaviour for caller-owned
  sinks.
- [`Jidoka.Trace.Sink.InMemory`](`Jidoka.Trace.Sink.InMemory`) - in-process
  reference sink for tests and examples.

## Related Guides

- [Streaming](streaming.md) - request-scoped live events instead of
  post-hoc projection.
- [Agent View](agent-view.md) - the UI projection that consumes events.
- [Sessions And Stores](sessions-and-stores.md) - how `replay/1` projects
  a session timeline.
- [Runtime And Harness](runtime-and-harness.md) - where event emission
  fits in the runtime loop.
