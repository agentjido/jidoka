# Memory Contracts

Jidoka memory is a small set of data contracts and a single `Jidoka.Memory.Store`
behaviour. The agent spec declares a memory policy; the runtime turns that
policy into recall and write requests; a pluggable store answers those
requests. This guide documents each struct and the store interface so that
custom stores (Postgres, Redis, vector DB, etc.) can interoperate without
guesswork.

## When To Use This

- Use this guide when you need the exact shape of a memory entry, recall, or
  write to build a store, replay tool, or audit query.
- Use this guide when wiring `Jidoka.Memory.Store.InMemory` into tests.
- Do not use this guide as a memory tutorial. The high-level workflow lives in
  [Runtime And Harness](runtime-and-harness.md).

## Prerequisites

- You have read [Agent Spec Contract](agent-spec-contract.md), in particular
  `Jidoka.Agent.Spec.Memory`.
- You can build and run a Jidoka turn.

## Quick Example

A complete memory round-trip uses the in-memory store and the three core
contracts: `WriteRequest`, `RecallRequest`, `RecallResult`.

```elixir
alias Jidoka.Memory.{Entry, RecallRequest, WriteRequest, Store}

{:ok, pid} = Jidoka.Memory.Store.InMemory.start_link([])
store = {Jidoka.Memory.Store.InMemory, pid: pid}

entry = Entry.new!(agent_id: "time_agent", content: "User prefers Chicago time")
{:ok, _write} = Store.write(store, WriteRequest.new!(entry: entry))

request =
  RecallRequest.new!(
    agent_id: "time_agent",
    scope: :agent,
    query: "preferred timezone",
    limit: 3
  )

{:ok, recall} = Store.recall(store, request)
length(recall.entries)
#=> 1
```

## Concepts

```diagram
╭──────────────────╮     ╭───────────────────╮     ╭──────────────────╮
│ Spec.Memory      │────▶│ Runtime           │────▶│ Memory.Store     │
│ (policy)         │     │ assembles recall  │     │ (behaviour)      │
╰──────────────────╯     ╰─────────┬─────────╯     ╰────────┬─────────╯
                                   ▼                        ▼
                          ╭──────────────────╮      ╭──────────────────╮
                          │ RecallRequest    │      │ RecallResult     │
                          │ WriteRequest     │      │ WriteResult      │
                          ╰──────────────────╯      ╰──────────────────╯
```

`Spec.Memory` is policy (definition data). Stores are supplied per run through
harness options. The runtime negotiates the conversation by emitting
`RecallRequest` and `WriteRequest` structs and reading `RecallResult` /
`WriteResult` back.

## Fields

### `Jidoka.Memory.Entry`

Durable memory entry available to prompt assembly.

| Field | Type | Default | Purpose |
| --- | --- | --- | --- |
| `id` | non-empty string | generated prefixed UUIDv7 (`"mem_…"`) | Stable id for upsert/dedupe. |
| `agent_id` | non-empty string | required | Owning agent (matches `Spec.id`). |
| `session_id` | non-empty string or `nil` | `nil` | Session scope when applicable. |
| `content` | non-empty string | required | Content injected into the prompt or context. |
| `metadata` | map | `%{}` | Arbitrary caller metadata. |

### `Jidoka.Memory.RecallRequest`

Request sent to a store before prompt assembly.

| Field | Type | Default | Purpose |
| --- | --- | --- | --- |
| `agent_id` | non-empty string | required | Whose memory to read. |
| `session_id` | non-empty string or `nil` | `nil` | Session scope for `:session` policies. |
| `scope` | `:agent \| :session` | `:agent` | Mirrors `Spec.Memory.scope`. |
| `query` | non-empty string | required | Query used by the store (free text, embedding key, etc.). |
| `limit` | positive integer | `5` | Maximum entries to return. |
| `metadata` | map | `%{}` | Caller metadata for tracing or routing. |

### `Jidoka.Memory.RecallResult`

Result returned by `Memory.Store.recall/2`.

| Field | Type | Default | Purpose |
| --- | --- | --- | --- |
| `request` | `RecallRequest.t()` | required | The original recall request (echoed for trace clarity). |
| `entries` | `[Entry.t()]` | `[]` | Recalled entries in store-defined order. |
| `metadata` | map | `%{}` | Store metadata (similarity scores, latency, etc.). |

### `Jidoka.Memory.WriteRequest`

Request to upsert one entry.

| Field | Type | Default | Purpose |
| --- | --- | --- | --- |
| `entry` | `Entry.t()` | required | Entry to persist. |
| `metadata` | map | `%{}` | Write-specific metadata. |

### `Jidoka.Memory.WriteResult`

Acknowledgement returned by `Memory.Store.write/2`.

| Field | Type | Default | Purpose |
| --- | --- | --- | --- |
| `request` | `WriteRequest.t()` | required | The original write request. |
| `entry` | `Entry.t()` | required | The (possibly normalized) entry as stored. |
| `status` | `:ok` | `:ok` | Reserved for future statuses; today always `:ok`. |
| `metadata` | map | `%{}` | Store metadata. |

### `Jidoka.Memory.Store` Behaviour

Three callbacks define the store contract. A store is a module or
`{module, opts}` tuple.

| Callback | Purpose |
| --- | --- |
| `recall(RecallRequest.t(), opts) :: {:ok, RecallResult.t()} \| {:error, term()}` | Read entries matching the request. |
| `write(WriteRequest.t(), opts) :: {:ok, WriteResult.t()} \| {:error, term()}` | Upsert one entry. |
| `list_entries(opts) :: {:ok, [Entry.t()]} \| {:error, term()}` | Diagnostic listing for tests and inspectors. |

Top-level helpers `Memory.Store.recall/2`, `Memory.Store.write/2`, and
`Memory.Store.list_entries/1` normalize the `{module, opts}` shape before
dispatching.

## Common Patterns

- **Reuse `Entry.new!/1` to generate ids.** The default prefixed UUIDv7 `"mem_…"` id is enough
  for most stores; supply your own only when integrating with an external
  primary key.
- **Carry routing data in `metadata`.** Stores should ignore unknown keys, so
  feel free to thread tenant ids, embedding model names, or trace ids through
  any of the request/result maps.
- **Use scope to gate session-only memory.** `RecallRequest.scope: :session`
  with a `session_id` lets a store filter cross-session data without app code.
- **Keep stores small.** Implementing the three callbacks is enough; the
  runtime handles policy, capture, and injection.

## Testing

The in-memory store is the canonical test fixture. It exercises the full
contract without touching disk or network.

```elixir
setup do
  {:ok, pid} = Jidoka.Memory.Store.InMemory.start_link([])
  {:ok, store: {Jidoka.Memory.Store.InMemory, pid: pid}}
end

test "writes and recalls a single entry", %{store: store} do
  entry = Jidoka.Memory.Entry.new!(agent_id: "demo", content: "hello")

  assert {:ok, _} =
           Jidoka.Memory.Store.write(store,
             Jidoka.Memory.WriteRequest.new!(entry: entry)
           )

  request =
    Jidoka.Memory.RecallRequest.new!(
      agent_id: "demo",
      query: "hello",
      limit: 5
    )

  assert {:ok, recall} = Jidoka.Memory.Store.recall(store, request)
  assert [%{content: "hello"}] = recall.entries
end
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `ArgumentError: invalid memory entry: ...` | `agent_id` or `content` was empty. | Both are required non-empty strings. |
| `Recall returns no entries` despite writes | Scope/session_id mismatch. | Use `scope: :agent` for shared memory; provide a matching `session_id` for session scope. |
| `in-memory memory store requires :pid` | Used `Memory.Store.InMemory` without the `pid:` opt. | Pass `{Jidoka.Memory.Store.InMemory, pid: pid}` as the store value. |
| `Recall ignores limit` | A custom store did not honor `RecallRequest.limit`. | Truncate inside the store; the runtime trusts the result. |

## Reference

- [`Jidoka.Memory`](`Jidoka.Memory`) - public type aliases.
- [`Jidoka.Memory.Entry`](`Jidoka.Memory.Entry`)
- [`Jidoka.Memory.RecallRequest`](`Jidoka.Memory.RecallRequest`)
- [`Jidoka.Memory.RecallResult`](`Jidoka.Memory.RecallResult`)
- [`Jidoka.Memory.WriteRequest`](`Jidoka.Memory.WriteRequest`)
- [`Jidoka.Memory.WriteResult`](`Jidoka.Memory.WriteResult`)
- [`Jidoka.Memory.Store`](`Jidoka.Memory.Store`) - behaviour.
- [`Jidoka.Memory.Store.InMemory`](`Jidoka.Memory.Store.InMemory`) -
  reference store.
- [`Jidoka.Agent.Spec.Memory`](`Jidoka.Agent.Spec.Memory`) - policy that
  drives recall.

## Related Guides

- [Agent Spec Contract](agent-spec-contract.md) - memory policy lives on the
  spec.
- [Runtime And Harness](runtime-and-harness.md) - how memory is wired into a
  turn.
- [Turn And Effect Contracts](turn-and-effect-contracts.md) - where recall
  results land on `Turn.State`.
