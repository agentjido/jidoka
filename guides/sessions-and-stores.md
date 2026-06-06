# Sessions And Stores

A Jidoka session keeps an agent conversation alive across turns. It stores
request history, snapshots, pending reviews, and the latest result. It does not
own provider clients or long-running processes.

## Use This When

- Use a session when the same agent answers more than one user message.
- Use a session when a turn must resume after a process restart.
- Use a session when a human-in-the-loop interrupt must be picked up later.
- Use a single `Jidoka.turn/3` or `Jidoka.chat/3` call when the work is
  one-shot and the caller does not need to remember anything between turns.
- Use a store when sessions must survive a node restart or be shared across
  workers; keep the in-memory store for tests and local exploration.

## Prerequisites

- A working Jidoka agent. The smallest one is enough; see
  [Getting Started](getting-started.md).
- A provider key in scope for live examples.
- For persistence: a started [`Jidoka.Harness.Store.InMemory`](`Jidoka.Harness.Store.InMemory`)
  process, or a module that implements [`Jidoka.Harness.Store`](`Jidoka.Harness.Store`).

```bash
mix deps.get
mix test
```

## Start A Session

The smallest durable session is a store plus a session id.

```elixir
{:ok, pid} = Jidoka.Harness.Store.InMemory.start_link()
store = {Jidoka.Harness.Store.InMemory, pid: pid}

{:ok, session} =
  Jidoka.Session.start(MyApp.SupportAgent, "support-123", store: store)

{:ok, session, text} =
  Jidoka.Session.chat(session.session_id, "Say hi to Ada.", store: store)
```

That call ran through the same runtime as `Jidoka.turn/3`, then persisted the
updated session under id `"support-123"`. A second `Jidoka.Session.chat/3`
against the same id continues the conversation.

## Concepts

A session is data. Apps usually call `Jidoka.Session`; stores persist the
session data between turns.

```diagram
╭──────────────────────╮
│   Jidoka.Session     │
│ start / run / chat   │
│ resume / replay      │
╰──────────┬───────────╯
           │ reads and writes
           ▼
╭──────────────────────────╮
│ Durable session data     │
│ spec / requests          │
│ snapshots / result       │
│ pending_reviews          │
╰──────────┬───────────────╯
           │ persists through
           ▼
╭──────────────────────────╮
│ Store                    │
│ put / get / list / claim │
╰──────────────────────────╯
```

- [`Jidoka.Session`](`Jidoka.Session`) is the developer-facing facade. It
  wraps `start/run/chat/resume` and derives sensible defaults.
- [`Jidoka.Harness.Session`](`Jidoka.Harness.Session`) is the durable data
  struct. Its `schema_version/0` is `1`; older or newer payloads fail at
  normalization rather than silently loading a half-valid session.
- [`Jidoka.Harness.Store`](`Jidoka.Harness.Store`) is the persistence
  behaviour: `put_session/2`, `get_session/2`, `list_sessions/1`, and
  optional `claim_session/3` for atomic single-runner semantics.

A session status is one of `:new`, `:running`, `:hibernated`, `:waiting`,
`:finished`, or `:error`. Jidoka computes it from snapshots, pending reviews,
and the latest result.

## How To

### Step 1: Start A Session

`Jidoka.Session.start/2` accepts a DSL module, a `Jidoka.Agent.Spec`, or a
keyword list of spec attributes. Pass `store:` to persist immediately.

```elixir
{:ok, session} =
  Jidoka.Session.start(MyApp.SupportAgent,
    session_id: "support-123",
    store: store,
    metadata: %{tenant: "acme"}
  )

session.session_id
#=> "support-123"
session.status
#=> :new
session.metadata
#=> %{tenant: "acme"}
```

If no session id is supplied, Jidoka generates one through
`Jidoka.Id.generate/2`. Passing `session_id:` is preferred for any flow that
needs a persistent external handle (a chat thread id, a ticket id, a workflow id).

### Step 2: Run Turns

`Jidoka.Session.run/3` is the full-result API. It returns the underlying
`Jidoka.Turn.Result`, a hibernation snapshot, or an error, along with the
updated session struct so callers without a store still have durable state.

```elixir
{:ok, session, %Jidoka.Turn.Result{} = result} =
  Jidoka.Session.run(session.session_id, "Look up order A1001",
    store: store
  )

result.content
result.events
result.value
```

`Jidoka.Session.chat/3` is the text-only API. It is the right default for
product code.

```elixir
{:ok, session, text} =
  Jidoka.Session.chat(session.session_id, "And what is its status?",
    store: store
  )
```

Both functions accept either a session struct or a session id. With a store
the id is enough; without a store, hold onto the returned struct.

### Step 3: Hibernate And Resume

Pass a checkpoint policy when you want the turn to pause at a safe boundary:

```elixir
{:hibernate, session, snapshot} =
  Jidoka.Session.chat(session.session_id, "Refund order A1001",
    store: store,
    checkpoint: :after_prompt
  )

session.status
#=> :hibernated
```

Resume picks up the latest snapshot recorded on the session:

```elixir
{:ok, session, %Jidoka.Turn.Result{}} =
  Jidoka.Session.resume(session.session_id,
    store: store
  )
```

See [Snapshots And Resume](snapshots-and-resume.md) for the full snapshot
lifecycle and serialization format.

### Step 4: List Pending Reviews

Pending review requests are derived from snapshot metadata when an operation
control returns `{:interrupt, reason}`. They can be listed per session or
across an entire store:

```elixir
{:ok, [%Jidoka.Review.Request{} = request]} =
  Jidoka.Session.pending_reviews(session)

{:ok, all_pending} = Jidoka.Session.pending_reviews(store)
```

The store-level helper iterates `list_sessions/1` and flattens
`session.pending_reviews`, so it works the same for any compliant backend.
For the durable approval flow itself, see
[Human In The Loop](human-in-the-loop.md).

### Step 5: Implement A Custom Store

A store is a module implementing `Jidoka.Harness.Store`. The required
callbacks are small.

```elixir
defmodule MyApp.PostgresSessionStore do
  @behaviour Jidoka.Harness.Store

  alias Jidoka.Harness.Session

  @impl true
  def put_session(%Session{} = session, _opts) do
    MyApp.Repo.upsert_session(session)
    {:ok, session}
  end

  @impl true
  def get_session(session_id, _opts) when is_binary(session_id) do
    case MyApp.Repo.fetch_session(session_id) do
      nil -> {:error, {:session_not_found, session_id}}
      session -> {:ok, session}
    end
  end

  @impl true
  def list_sessions(_opts) do
    {:ok, MyApp.Repo.all_sessions()}
  end
end
```

`claim_session/3` is optional. Implement it when the backend has a native
atomic compare-and-set; otherwise the default fallback uses `get_session/2`
followed by `put_session/2` after rejecting any session already in
`:running` state.

Callers reference a store as either `Module` or `{Module, opts}`. The
in-memory store is `{Jidoka.Harness.Store.InMemory, pid: pid}` so the same
shape works for stores that need configuration (database, namespace, region).

### Step 6: Inspect Sessions

Replay is a data-only projection over what a session already knows. It does
not call any capability and is safe to run anywhere.

```elixir
{:ok, replay} = Jidoka.Session.replay(session)
replay.timeline
replay.journal
replay.pending_reviews
```

For human-readable inspection of a session, snapshot, or request, use
`Jidoka.inspect/1`. For trace projection see
[Tracing And Events](tracing-and-events.md).

## Common Patterns

- **Session per external identifier.** Use the same id the surrounding
  product uses (chat thread, ticket, workflow) instead of generating a fresh
  one. This keeps lookups idempotent.
- **Pass the store on every call.** The store reference is just data, and
  passing it makes the call self-contained. Avoid hiding it behind global
  state.
- **Prefer `chat/3` for product code.** Reach for `run/3` when you need the
  full result, the journal, or to observe a hibernation snapshot.
- **Keep capabilities out of session metadata.** Provider clients, pids,
  and credentials belong in the runtime options for each call, not on the
  serializable session.
- **Use `claim_session/3` in multi-worker deployments.** It is the
  difference between two workers racing on the same turn and one worker
  observing `{:error, {:session_already_running, _}}` and backing off.

## Testing

Sessions are easy to test because every capability is injectable. A
deterministic LLM and the in-memory store are usually enough.

```elixir
test "session keeps history across turns" do
  {:ok, pid} = Jidoka.Harness.Store.InMemory.start_link()
  store = {Jidoka.Harness.Store.InMemory, pid: pid}

  llm = fn _intent, journal, _ctx ->
    case map_size(journal.results) do
      0 -> {:ok, %{type: :final, content: "first"}}
      _ -> {:ok, %{type: :final, content: "second"}}
    end
  end

  {:ok, session} = Jidoka.Session.start(MyApp.SupportAgent, "s1", store: store)
  {:ok, _session, "first"} = Jidoka.Session.chat("s1", "hi", store: store, llm: llm)
  {:ok, session, "second"} = Jidoka.Session.chat("s1", "again", store: store, llm: llm)

  assert length(session.requests) == 2
  assert session.status == :finished
end
```

For multi-worker safety, write a test that calls `Jidoka.Session.run/3`
twice concurrently against the same id and assert one call returns
`{:error, {:session_already_running, _}}`.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, :missing_harness_store}` | A session id was passed without a `store:` option. | Pass the store on every call, or hold the session struct and pass it directly. |
| `{:error, {:session_not_found, id}}` | The id was never started against this store. | Call `Jidoka.Session.start/3` with `session_id: id, store: store`. |
| `{:error, {:session_already_running, id}}` | Two callers tried to run the same session at the same time. | Serialize callers; if this is expected, retry after the prior call returns. |
| `{:error, {:missing_session_snapshot, id}}` | Resume was called on a session that never hibernated. | Run a new turn instead, or hibernate explicitly with a checkpoint policy. |
| `{:error, {:conflicting_session_ids, _, _}}` | Both `:id` and `:session_id` were passed with different values. | Pass only `:session_id`, or make them equal. |
| `{:error, {:unsupported_session_schema_version, _, 1}}` | A persisted payload predates the current schema. | Migrate the row to schema version 1 or discard it. |

## Reference

Key modules touched in this guide:

- [`Jidoka.Session`](`Jidoka.Session`) - public facade for `start/2`,
  `run/3`, `chat/3`, `resume/2`, `pending_reviews/1`, `replay/1`.
- [`Jidoka.Harness.Session`](`Jidoka.Harness.Session`) - durable session
  struct with `schema_version/0 == 1`.
- [`Jidoka.Harness.Store`](`Jidoka.Harness.Store`) - persistence behaviour.
- [`Jidoka.Harness.Store.InMemory`](`Jidoka.Harness.Store.InMemory`) -
  reference store for tests and examples.
- [`Jidoka.Review.Request`](`Jidoka.Review.Request`) - shape returned by
  `pending_reviews/1`.

## Related Guides

- [Snapshots And Resume](snapshots-and-resume.md) - the durable artifact a
  session hibernates to.
- [Human In The Loop](human-in-the-loop.md) - pending reviews and the
  approve/deny resume path.
- [Tracing And Events](tracing-and-events.md) - what
  `Jidoka.Session.replay/1` projects under the hood.
- [Runtime And Harness](runtime-and-harness.md) - internals for sessions,
  stores, and replay.
