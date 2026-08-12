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
- For persistence: a started [`Jidoka.Session.Store.InMemory`](`Jidoka.Session.Store.InMemory`)
  or [`Jidoka.Session.Store.Dets`](`Jidoka.Session.Store.Dets`) process, or a
  module that implements [`Jidoka.Session.Store`](`Jidoka.Session.Store`).

```bash
mix deps.get
mix test
```

## Start A Session

The smallest durable session is a store plus a session id.

```elixir
{:ok, pid} = Jidoka.Session.Store.InMemory.start_link()
store = {Jidoka.Session.Store.InMemory, pid: pid}

{:ok, session} =
  Jidoka.session(MyApp.SupportAgent, "support-123", store: store)

{:ok, session, text} =
  Jidoka.chat(session, "Say hi to Ada.", store: store)
```

That call ran through the same runtime as `Jidoka.turn/3`, then persisted the
updated session under id `"support-123"`. A later call can pass the returned
session struct, or `Jidoka.Session.chat/3` can load the session id from the
store.

The target determines the result shape:

| Call | Success shape | Caller duty |
| --- | --- | --- |
| `Jidoka.chat(agent, input)` | `{:ok, text}` | No session state to retain |
| `Jidoka.chat(session, input)` | `{:ok, updated_session, text}` | Keep the returned session when no store owns it |
| `Jidoka.Session.chat(session_id, input, store: store)` | `{:ok, updated_session, text}` | Pass the store on later id-based calls |
| `Jidoka.Session.run(session_or_id, input, opts)` | `{:ok, updated_session, %Jidoka.Turn.Result{}}` | Handle full result or hibernation data |
| `Jidoka.Session.run_sequence(session_or_id, requests, opts)` | `{:ok, %Jidoka.Session.Sequence.Result{}}` | Inspect ordered steps and terminal data |

## Concepts

A session is data. Apps usually call `Jidoka.Session`; stores persist the
session data between turns.

```diagram
╭──────────────────────╮
│   Jidoka.Session     │
│ start / run / chat   │
│ resume / fork        │
│ replay               │
╰──────────┬───────────╯
           │ reads and writes
           ▼
╭──────────────────────────╮
│ Durable session data     │
│ spec / requests          │
│ snapshots / result       │
│ pending_reviews          │
│ optional lineage         │
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
- [`Jidoka.Session.Data`](`Jidoka.Session.Data`) is the durable data
  struct. Its `schema_version/0` is `1`; older or newer payloads fail at
  normalization rather than silently loading a half-valid session.
- [`Jidoka.Session.Store`](`Jidoka.Session.Store`) is the persistence
  behaviour. Its base callbacks store and read session data. Lease-aware
  callbacks provide atomic claim, checkpoint, commit, renewal, and recovery.

A session status is one of `:new`, `:running`, `:hibernated`, `:waiting`,
`:finished`, `:cancelled`, or `:error`. Jidoka computes it from snapshots,
pending reviews, the latest result, and typed cancellation evidence.

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

Use `Jidoka.Session.run_sequence/3` when later turns must receive semantic
state from earlier turns in the same call. Jidoka carries the state and returns
operation results for each step separately.

```elixir
requests = [
  %{input: "Remember that the account is A1001.", request_id: "account-1"},
  %{input: "Which account did I mention?", request_id: "account-2"}
]

{:ok, sequence} =
  Jidoka.Session.run_sequence(session.session_id, requests,
    store: store
  )

sequence.status
#=> :completed

Enum.map(sequence.steps, & &1.result.content)
```

The sequence stops at the first error, hibernation, or cancellation. Its
`steps` field contains only completed turns. Its `terminal` field identifies
the stopped request and reason. A store-backed sequence claims and commits one
turn at a time; it does not persist turns that have not started.

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

Separate calls to `run/3` or `chat/3` record session history, but they do not
automatically put the prior semantic agent state into a later request. Use one
`run_sequence/3` call for ordered semantic continuation. Advanced callers can
still supply explicit state to a one-turn request when they own that policy.

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

### Step 4: Fork A Safe Snapshot

`Jidoka.Session.fork/2` creates a new runnable session from a snapshot that is
already in the source session. The source does not change.

```elixir
{:ok, branch} =
  Jidoka.Session.fork(session.session_id,
    store: store,
    session_id: "support-123-alternate"
  )

branch.status
#=> :hibernated

branch.lineage.parent_session_id
#=> "support-123"

{:ok, branch, result} =
  Jidoka.Session.resume(branch.session_id,
    store: store
  )
```

The default selector is `snapshot: :latest`. You can also pass a stored
snapshot id, the exact snapshot struct, or its signed serialized string. A
struct or signed string must exactly match a snapshot in the source session.
Jidoka rejects a changed snapshot, a running source session, a target id that
matches the source, and a target id that is already in the configured store.

Each fork gets a new snapshot id. Pass `fork_snapshot_id:` when an application
needs a fixed id. The copied turn state and effect journal do not change. If an
unsafe operation has a completed result in that journal, resume uses the result
and does not call the operation again.

Fork is a narrow continuation contract. It does not edit stored state, move a
cursor to an arbitrary phase, or re-execute effects. Replay remains a data-only
inspection contract.

### Step 5: List Pending Reviews

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

### Step 6: Use Durable Recovery

Lease-aware stores assign one worker to a running session. Jidoka renews the
lease while the worker runs. Before each capability call, Jidoka saves the
effect intent and a safe snapshot. After the call, Jidoka saves the result and
snapshot before it continues the turn.

If the worker or node stops, the lease expires. A recovery worker can list and
claim the session:

```elixir
{:ok, recoverable} =
  Jidoka.Session.recoverable(store)

{:ok, session, result} =
  Jidoka.Session.recover("support-123",
    store: store,
    owner_id: "worker-2",
    lease_ttl_ms: 30_000
  )
```

Recovery uses the latest durable snapshot:

- if the worker stopped before its first snapshot, Jidoka restarts the stored
  request because no effect intent exists yet;
- a recorded result is replayed without another capability call;
- an incomplete `:pure` or `:idempotent` effect can run again with the same
  idempotency key;
- an incomplete `:dedupe` or `:reconcile` effect returns a reconciliation
  error;
- an incomplete `:unsafe_once` effect returns
  `:unsafe_once_incomplete_effect` and does not run again.

A stale worker cannot renew, checkpoint, or commit after recovery replaces its
lease. Capability tasks are owned by the worker, so they stop when that worker
stops.

For disk persistence on one BEAM node, use the DETS adapter:

```elixir
{:ok, pid} =
  Jidoka.Session.Store.Dets.start_link(
    path: "/var/lib/my_app/jidoka_sessions.dets"
  )

store = {Jidoka.Session.Store.Dets, pid: pid}
```

The DETS adapter serializes transitions through one process and calls
`:dets.sync/1` before it acknowledges a write. It survives store process and
node restarts. It is a single-node adapter. Use a database-backed store with
the same lease callbacks for multi-node worker ownership.

Jidoka makes session state and a completed effect result durable in one store
transition before the turn accepts that result. It cannot make an arbitrary
external service call and the store write one distributed transaction. An
external service should honor the stable idempotency key. If it cannot, use
`:reconcile` or `:unsafe_once` and resolve an incomplete intent explicitly.

### Step 7: Implement A Custom Store

A store is a module implementing `Jidoka.Session.Store`. The required
callbacks are small.

```elixir
defmodule MyApp.PostgresSessionStore do
  @behaviour Jidoka.Session.Store

  alias Jidoka.Session.Data

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

`claim_session/3` remains optional for older stores. Its fallback uses
`get_session/2` followed by `put_session/2`, but that fallback is not a durable
lease protocol.

A crash-safe store implements these callbacks as atomic compare-and-set
transitions:

- `claim_session/3` for a new request;
- `claim_resume/2` for a normal hibernated resume;
- `recover_session/2` to replace an expired lease;
- `checkpoint_session/4` to save intent or result evidence;
- `renew_session/3` to extend ownership;
- `commit_session/4` to save final state and release ownership.

Use the helpers in `Jidoka.Session.Store` to apply the standard transition
rules. A backend transaction, row lock, compare-and-set, or single-owner
process must make each transition atomic.

Callers reference a store as either `Module` or `{Module, opts}`. The
in-memory store is `{Jidoka.Session.Store.InMemory, pid: pid}` so the same
shape works for stores that need configuration (database, namespace, region).

### Step 8: Inspect Sessions

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
  {:ok, pid} = Jidoka.Session.Store.InMemory.start_link()
  store = {Jidoka.Session.Store.InMemory, pid: pid}

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
- [`Jidoka.Session.Data`](`Jidoka.Session.Data`) - durable session
  struct with `schema_version/0 == 1`.
- [`Jidoka.Session.Store`](`Jidoka.Session.Store`) - persistence behaviour.
- [`Jidoka.Session.Store.InMemory`](`Jidoka.Session.Store.InMemory`) -
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
- [Runtime And Execution Layers](runtime-and-harness.md) - internals for sessions,
  stores, and replay.
