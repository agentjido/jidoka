# Snapshots And Resume

A Jidoka snapshot is the serializable pause point of a turn. It captures the
spec, request, pending work, journal, and any pending review interrupt. It never
captures pids, sockets, or provider clients.

## When To Use This

- Use snapshots whenever a turn might be paused and continued later: human
  approval, batch deferral, long-running tool work, or a redeploy in the
  middle of a long conversation.
- Use snapshots as the unit you persist in a job queue. They are designed to
  round-trip through any binary-safe store.
- Do not use snapshots as a substitute for sessions. A session contains a
  list of snapshots plus durable metadata. See
  [Sessions And Stores](sessions-and-stores.md).

## Prerequisites

- An agent and a runtime capability that can produce a turn (LLM, and
  operations if the agent declares tools).
- Familiarity with `Jidoka.turn/3` and `Jidoka.resume/2`; the resume path is
  the only API that consumes a snapshot.
- A persistent target (database, queue, file) for serialized snapshots
  when crossing process or node boundaries.

```bash
mix deps.get
mix test
```

## Quick Example

The smallest hibernate/resume cycle uses the `:after_prompt` checkpoint.

```elixir
{:hibernate, snapshot} =
  Jidoka.turn(MyApp.SupportAgent, "Hello",
    checkpoint: :after_prompt
  )

{:ok, serialized} = Jidoka.Runtime.AgentSnapshot.serialize(snapshot)
String.starts_with?(serialized, "jidoka:snapshot:v1:")
#=> true

{:ok, result} = Jidoka.resume(serialized)
result.content
```

The snapshot carried everything Jidoka needed to keep going. Runtime
capabilities still come from the host process at resume time.

## Concepts

A snapshot is data. The runtime treats it as an inert payload until
`Jidoka.resume/2` lifts it back into a live `Turn.State`.

```diagram
╭──────────────────╮     ╭──────────────────────╮     ╭──────────────╮
│ Jidoka.turn/3    │────▶│   Turn.State + Cursor │────▶│ AgentSnapshot│
│ checkpoint: ...  │     ╰──────────────────────╯     ╰──────┬───────╯
╰──────────────────╯                                          │
                                                              ▼
                                                ╭──────────────────────╮
                                                │ serialize / store /  │
                                                │ deserialize          │
                                                ╰──────┬───────────────╯
                                                       │
                                                       ▼
                                                ╭──────────────────────╮
                                                │ Jidoka.resume/2      │
                                                │ same capabilities    │
                                                ╰──────────────────────╯
```

Key facts:

- [`Jidoka.Runtime.AgentSnapshot`](`Jidoka.Runtime.AgentSnapshot`) has a
  `schema_version/0` of `1`. Unknown versions fail at normalization.
- `serialize/1` returns `"jidoka:snapshot:v1:" <> base64`. The body is
  `:erlang.term_to_binary/1` over the validated struct.
- Snapshots are validated for portability before serialization: pids,
  ports, references, and functions are rejected so a snapshot can never
  capture local-only runtime state.
- `from_input/1` accepts a struct, a map of attributes, a keyword list, or
  the opaque string returned by `serialize/1`. This is what makes
  `Jidoka.resume/2` flexible without leaking format details.
- The `cursor` field describes where the turn paused: `:after_prompt`,
  `:before_effect`, or `:review`. Resume reads it to decide whether to
  apply an approval response or continue with the pending effect.

## How To

### Step 1: Choose A Checkpoint Policy

The turn runner accepts one of four policies on `:checkpoint`:

- `:none` is the default. The turn runs to completion or to an error and
  only hibernates if an operation control returns an interrupt.
- `:after_prompt` hibernates immediately after the first prompt is
  assembled and before the first effect runs. Use this when you want to
  inspect or persist work before paying for any model call.
- `:after_each_phase` hibernates after prompt assembly and again before any
  pending effect. Use this for batch pipelines that resume one phase per
  job.
- `:before_each_effect` hibernates right before each pending effect.
  Use this for the tightest external durability boundary.

```elixir
{:hibernate, snapshot} =
  Jidoka.turn(MyApp.SupportAgent, "Look up A1001",
    llm: llm,
    operations: operations,
    checkpoint: :before_each_effect
  )

snapshot.cursor.phase
#=> :before_effect
```

### Step 2: Serialize And Persist

Snapshots survive any byte-safe transport. The serialized payload is opaque;
the contract is the `"jidoka:snapshot:v1:"` prefix and the `schema_version`
field.

```elixir
{:ok, payload} = Jidoka.Runtime.AgentSnapshot.serialize(snapshot)

:ok = MyApp.Queue.enqueue(job_id, payload)
```

`serialize/1` raises through `serialize!/1`, but production code should
prefer the tuple form so that a non-portable value (a stray pid in
metadata, for example) is surfaced as `{:error,
{:non_serializable_snapshot_value, _, _}}` rather than an exception.

### Step 3: Resume From Any Snapshot Input

`Jidoka.resume/2` accepts every shape `AgentSnapshot.from_input/1` accepts:

```elixir
# A struct.
{:ok, result} = Jidoka.resume(snapshot, llm: llm)

# Map-shaped attributes that match the schema.
{:ok, result} = Jidoka.resume(Map.from_struct(snapshot), llm: llm)

# The opaque serialized string.
{:ok, result} = Jidoka.resume(payload, llm: llm)
```

Resume runs through the same harness boundary as `Jidoka.turn/3`. Supply
the same runtime capabilities (`llm:`, `operations:`, and optionally
`memory_store:`) and, when resuming a review pause, an `:approval` option.

### Step 4: Continue, Hibernate, Or Error

Resume returns the same three outcomes as `turn/3`:

```elixir
case Jidoka.resume(snapshot, llm: llm, operations: operations) do
  {:ok, %Jidoka.Turn.Result{} = result} ->
    handle_result(result)

  {:hibernate, %Jidoka.Runtime.AgentSnapshot{} = snapshot} ->
    persist_again(snapshot)

  {:error, reason} ->
    log_failure(reason)
end
```

`{:hibernate, snapshot}` is normal: a single resume may hit another
checkpoint or another review interrupt. Always loop until you see `{:ok,
_}` or `{:error, _}`.

### Step 5: Honor Schema Versioning

The struct carries `schema_version: 1`. Anything else fails up front:

```elixir
Jidoka.Runtime.AgentSnapshot.new(%{
  schema_version: 99,
  snapshot_id: "snap_x",
  agent_id: "support",
  cursor: cursor,
  turn_state: turn_state
})
#=> {:error, {:unsupported_snapshot_schema_version, 99, 1}}
```

Likewise, `deserialize/1` only accepts the `"jidoka:snapshot:v1:"` prefix:

```elixir
Jidoka.Runtime.AgentSnapshot.deserialize("v0:garbage")
#=> {:error, :invalid_snapshot_serialization}
```

When the snapshot version eventually changes, older payloads will not be
silently coerced; Jidoka returns a versioned error and the application owns the
migration.

### Step 6: Reuse Snapshots In A Session

The session keeps snapshots in order. The latest snapshot is what
`Jidoka.Session.resume/2` continues from.

```elixir
{:hibernate, session, snapshot} =
  Jidoka.Session.chat(session_id, "Refund A1001",
    store: store,
    llm: llm,
    checkpoint: :after_prompt
  )

{:ok, ^snapshot} = Jidoka.Session.get(store, session_id) |> then(&{:ok, Jidoka.Harness.Session.latest_snapshot(elem(&1, 1))})
```

Use sessions when you want lifecycle, pending reviews, and metadata for
free. Use raw snapshots when the durable unit is a job, not a conversation.

## Common Patterns

- **Pair the snapshot with its request id.** The snapshot is portable, but
  observability ties to `request_id`. Persist both.
- **Round-trip in tests.** Always exercise `serialize/1` followed by
  `deserialize/1` in unit tests for any code that stashes snapshots. This
  catches non-portable metadata immediately.
- **Validate at boundaries, not in handlers.** Let `from_input/1` reject
  bad inputs at the entry point instead of pattern-matching deep inside
  application code.
- **Treat checkpoint policy as request-scoped.** Different callers can pick
  different policies against the same agent without redefining the spec.
- **Do not mutate snapshot fields.** Build a new struct with `new!/1` if
  you really need to project a derived shape; never reach into
  `turn_state` directly.

## Testing

A round-trip test gives you most of the value with very little setup:

```elixir
test "snapshot round-trips through opaque serialization" do
  llm = fn _intent, _journal ->
    {:ok, %{type: :final, content: "ok"}}
  end

  {:hibernate, snapshot} =
    Jidoka.turn(MyApp.SupportAgent, "Hello",
      llm: llm,
      checkpoint: :after_prompt
    )

  assert {:ok, serialized} = Jidoka.Runtime.AgentSnapshot.serialize(snapshot)
  assert String.starts_with?(serialized, "jidoka:snapshot:v1:")

  assert {:ok, ^snapshot} = Jidoka.Runtime.AgentSnapshot.deserialize(serialized)
  assert {:ok, %Jidoka.Turn.Result{content: "ok"}} = Jidoka.resume(serialized, llm: llm)
end
```

For approval flows, see the resume-with-`:approval` examples in
[Human In The Loop](human-in-the-loop.md).

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, :invalid_snapshot_serialization}` | Payload does not start with `"jidoka:snapshot:v1:"`. | Re-serialize from the source `AgentSnapshot` or migrate the persisted row. |
| `{:error, {:non_serializable_snapshot_value, path, :pid}}` | A pid was placed in snapshot metadata or context. | Remove runtime references before persisting; keep only data. |
| `{:error, {:unsupported_snapshot_schema_version, n, 1}}` | Persisted snapshot was written under a different schema. | Migrate the persisted payload or discard the older snapshot. |
| `Jidoka.resume/2` returns `{:hibernate, _}` again | Checkpoint policy or review interrupt still in effect. | Loop until `{:ok, _}` or `{:error, _}`; supply `:approval` if waiting on review. |
| `{:error, {:missing_pending_effect, _}}` on resume | The snapshot was finalized or already consumed. | Start a new turn; do not resume a snapshot whose work has already completed. |

## Reference

Key modules touched in this guide:

- [`Jidoka.Runtime.AgentSnapshot`](`Jidoka.Runtime.AgentSnapshot`) -
  `new/1`, `from_input/1`, `serialize/1`, `deserialize/1`,
  `schema_version/0`, `from_turn_state/3`.
- [`Jidoka.Turn.Cursor`](`Jidoka.Turn.Cursor`) - the `cursor.phase` field
  on a snapshot (`:after_prompt`, `:before_effect`, `:review`).
- [`Jidoka.Turn.State`](`Jidoka.Turn.State`) - the inner runtime state a
  snapshot wraps.
- [`Jidoka.Harness`](`Jidoka.Harness`) - `resume/2` boundary that
  `Jidoka.resume/2` delegates to.
- [`Jidoka.Effect.Journal`](`Jidoka.Effect.Journal`) - replay-safe record
  of effect intents and results inside the snapshot.

## Related Guides

- [Sessions And Stores](sessions-and-stores.md) - the durable wrapper that
  owns snapshots in order.
- [Human In The Loop](human-in-the-loop.md) - resuming with an
  `:approval` response.
- [Idempotency And Safety](idempotency-and-safety.md) - how the journal
  decides which effects re-run on resume.
- [Runtime And Harness](runtime-and-harness.md) - architectural overview.
