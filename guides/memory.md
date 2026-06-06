# Memory

Memory lets an agent recall facts across turns. Declare memory on the agent,
pass a memory store at runtime, and Jidoka injects matching entries into the
prompt.

## Use This When

- adding short-term conversation memory to an agent;
- integrating a custom memory store (Postgres, Redis,
  Jido.Memory, etc.).
- debugging "the agent does not remember what I told it".

## Prerequisites

- A working Jidoka agent module (see [Getting Started](getting-started.md)).
- Familiarity with the operation contract from
  [Tools And Operations](tools-and-operations.md).
- A provider key in scope for live examples.

```bash
mix deps.get
mix test
```

## Add Session Memory

Start the bundled in-memory store, declare `memory` on the agent, and pass
`memory_store:` when running the turn.

```elixir
defmodule MyApp.MemoryAgent do
  use Jidoka.Agent

  agent :memory_agent do
    model "openai:gpt-4o-mini"
    instructions "Greet the user and use any remembered facts."
    memory scope: :session, capture: :conversation, max_entries: 5
  end
end

{:ok, store_pid} = Jidoka.Memory.Store.InMemory.start_link([])
store = {Jidoka.Memory.Store.InMemory, pid: store_pid}

{:ok, _write} =
  Jidoka.Memory.write(
    MyApp.MemoryAgent.spec(),
    "User prefers the name Alex.",
    memory_store: store,
    session_id: "conv-1"
  )

{:ok, result} =
  Jidoka.turn(MyApp.MemoryAgent, "hello",
    memory_store: store,
    session_id: "conv-1"
  )

result.content
```

The recall happened before the prompt was assembled. The entry was injected
into the agent's instructions section (the default for
`inject: :instructions`).

## Concepts

Memory in Jidoka is three pieces of data and one boundary.

1. **`Jidoka.Agent.Spec.Memory`** is the policy declared on the spec. It is
   the only memory data that lives on the spec itself: `enabled`, `scope`
   (`:agent` or `:session`), `namespace`, `capture`
   (`:manual | :conversation | :off`), `inject` (`:instructions | :context`),
   `max_entries`, and free-form `metadata`.
2. **`Jidoka.Memory.Store`** is the behaviour each store implements:
   `recall/2`, `write/2`, `list_entries/1`. Stores are runtime data, not
   spec data; callers supply them per turn through the `memory_store:`
   option.
3. **Request/result data** is a small set of structs:
   `Jidoka.Memory.RecallRequest`, `Jidoka.Memory.RecallResult`,
   `Jidoka.Memory.WriteRequest`, `Jidoka.Memory.WriteResult`, and
   `Jidoka.Memory.Entry`.

```diagram
╭──────────────╮     ╭───────────────────╮     ╭──────────────────╮
│  Turn input  │────▶│ Memory.Runtime    │────▶│ Memory.Store     │
│   (request)  │     │ .recall(spec, req)│     │ .recall(req)     │
╰──────────────╯     ╰─────────┬─────────╯     ╰────────┬─────────╯
                               │                        │
                               ▼                        ▼
                     ╭──────────────────╮     ╭──────────────────╮
                     │ RecallResult     │◀────│ matching entries │
                     ╰────────┬─────────╯     ╰──────────────────╯
                              │
                              ▼
                     ╭───────────────────╮     ╭──────────────────╮
                     │ Steps.assemble    │────▶│ Prompt with      │
                     │   _prompt/1       │     │ memory injected  │
                     ╰────────┬──────────╯     ╰──────────────────╯
                              │
                              ▼
                     ╭───────────────────╮     ╭──────────────────╮
                     │ LLM + tools loop  │────▶│ Memory.Runtime   │
                     ╰───────────────────╯     │ .capture_turn/4  │
                                               ╰─────────┬────────╯
                                                         │
                                                         ▼
                                               ╭──────────────────╮
                                               │ WriteResult      │
                                               ╰──────────────────╯
```

`Jidoka.Memory` is the public helper that knows how to translate
between the spec policy, the per-turn options, and the store. Applications
talk to the store through `Jidoka.Memory.Store` directly (or through the
runtime helper used in tests).

### Scope And Session

- `scope: :agent` returns any entry tagged with the agent id, ignoring
  session.
- `scope: :session` returns only entries whose `session_id` matches the
  current `session_id:` option. Pass the option through both write and
  recall.

The InMemory store enforces these rules in `matches_request?/2`. Session
filtering is exact-match; there is no fuzzy fallback.

### Capture Modes

- `capture: :manual` (default) - memory only changes through explicit
  `Jidoka.Memory.write/3` calls.
- `capture: :conversation` - after every successful turn, Jidoka writes
  `"User: ...\nAssistant: ..."` to the store.
- `capture: :off` - the runtime never writes; useful when memory is
  populated by another system.

## How To

### Step 1: Declare The Memory Policy

The DSL accepts a keyword/map equivalent of `Jidoka.Agent.Spec.Memory`:

```elixir
agent :support_agent do
  model "openai:gpt-4o-mini"
  instructions "Answer support questions tersely."
  memory scope: :session, capture: :conversation, max_entries: 8
end
```

`memory true` enables defaults. `memory false` disables memory. Anything
else is parsed as a memory policy map.

### Step 2: Start An InMemory Store For Tests

`Jidoka.Memory.Store.InMemory` is an `Agent` process keyed by `:pid`. The
test process keeps its lifetime bounded.

```elixir
{:ok, pid} = Jidoka.Memory.Store.InMemory.start_link([])
store = {Jidoka.Memory.Store.InMemory, pid: pid}
```

The two-tuple form `{module, opts}` is the standard store input; pass it
wherever a `Jidoka.Memory.Store.store()` is required.

### Step 3: Write An Entry Manually

`Jidoka.Memory.write/3` builds the `Memory.Entry`, applies the spec
policy (scope, namespace), and forwards to the store.

```elixir
{:ok, %Jidoka.Memory.WriteResult{entry: entry}} =
  Jidoka.Memory.write(
    MyApp.MemoryAgent.spec(),
    "User prefers the name Alex.",
    memory_store: store,
    session_id: "conv-1",
    metadata: %{"kind" => :preference}
  )

entry.agent_id
#=> "memory_agent"

entry.session_id
#=> "conv-1"
```

The store you supplied receives a `Jidoka.Memory.WriteRequest` whose
`:entry` is the validated `Memory.Entry` struct.

### Step 4: Recall Through The Store Directly

You can also bypass the runtime helper and talk to `Jidoka.Memory.Store`:

```elixir
request =
  Jidoka.Memory.RecallRequest.new!(
    agent_id: "memory_agent",
    session_id: "conv-1",
    scope: :session,
    query: "hello",
    limit: 5
  )

{:ok, %Jidoka.Memory.RecallResult{entries: entries}} =
  Jidoka.Memory.Store.recall(store, request)

Enum.map(entries, & &1.content)
#=> ["User prefers the name Alex."]
```

This is what `Jidoka.Memory.recall/3` does when Jidoka assembles the prompt
for a turn.

### Step 5: Inspect Memory Injection With Preflight

Before running a live turn, confirm the recalled entries are landing in the
prompt:

```elixir
{:ok, preflight} =
  Jidoka.preflight(MyApp.MemoryAgent, "hello",
    memory_store: store,
    session_id: "conv-1"
  )

preflight.prompt.messages
```

With `inject: :instructions` (the default) the recalled content is appended
to the system message. With `inject: :context` it is added as structured
context the prompt assembler renders separately.

### Step 6: Implement A Custom Store

A custom store is one module that implements `Jidoka.Memory.Store`:

```elixir
defmodule MyApp.MapStore do
  @behaviour Jidoka.Memory.Store

  alias Jidoka.Memory.Entry
  alias Jidoka.Memory.RecallRequest
  alias Jidoka.Memory.RecallResult
  alias Jidoka.Memory.WriteRequest
  alias Jidoka.Memory.WriteResult

  def start_link(_opts), do: Agent.start_link(fn -> [] end)

  @impl true
  def recall(%RecallRequest{} = request, opts) do
    pid = Keyword.fetch!(opts, :pid)
    entries = pid |> Agent.get(& &1) |> Enum.take(request.limit)
    RecallResult.new(request: request, entries: entries)
  end

  @impl true
  def write(%WriteRequest{entry: %Entry{} = entry} = request, opts) do
    pid = Keyword.fetch!(opts, :pid)
    Agent.update(pid, &[entry | &1])
    WriteResult.new(request: request, entry: entry)
  end

  @impl true
  def list_entries(opts) do
    pid = Keyword.fetch!(opts, :pid)
    {:ok, pid |> Agent.get(& &1) |> Enum.reverse()}
  end
end
```

Pass it as `{MyApp.MapStore, pid: pid}` to `memory_store:`. Stores must
return `{:ok, result}` or `{:error, reason}` and must never raise on missing
entries; an empty `RecallResult` is the normal "nothing matched" answer.

## Common Patterns

- **Default to `scope: :session` for chat experiences.** It keeps unrelated
  conversations from leaking facts into each other.
- **Set `max_entries` deliberately.** The recall limit caps tokens; the
  default of `5` is small.
- **Pair `capture: :conversation` with `Jidoka.Session`.** Manual writes are
  fine for direct `turn/3` callers, but multi-turn applications benefit from
  automatic capture once a session id is in scope.
- **Namespace memory per tenant.** Use `namespace: {:context, :tenant_id}`
  and supply `context: %{tenant_id: "..."}` per turn; the runtime resolves
  the namespace before talking to the store.
- **Treat the store as data.** A `{module, opts}` tuple is the same kind of
  capability as the LLM function or operations function. Inject it; do not
  hard-code it in the agent.

## Testing

A complete memory test exercises write -> recall -> prompt assembly without
calling a provider. The InMemory store and a fake LLM are all that is
needed.

```elixir
defmodule MyApp.MemoryAgentTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, pid} = Jidoka.Memory.Store.InMemory.start_link([])
    {:ok, store: {Jidoka.Memory.Store.InMemory, pid: pid}}
  end

  test "recalls a remembered preference", %{store: store} do
    {:ok, _write} =
      Jidoka.Memory.write(
        MyApp.MemoryAgent.spec(),
        "User prefers the name Alex.",
        memory_store: store,
        session_id: "conv-1"
      )

    {:ok, preflight} =
      Jidoka.preflight(MyApp.MemoryAgent, "hello",
        memory_store: store,
        session_id: "conv-1"
      )

    system_message = Enum.find(preflight.prompt.messages, &(&1.role == :system))
    assert system_message.content =~ "prefers the name Alex"

    llm = fn _intent, _journal, _ctx ->
      {:ok, %{type: :final, content: "Welcome back, Alex."}}
    end

    assert {:ok, result} =
             Jidoka.turn(MyApp.MemoryAgent, "hello",
               llm: llm,
               memory_store: store,
               session_id: "conv-1"
             )

    assert result.content =~ "Alex"
  end
end
```

To assert the conversation capture path, run the turn with
`capture: :conversation` and read `Jidoka.Memory.Store.list_entries/1`
afterwards. The latest entry should contain both the user input and the
assistant content.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `Jidoka.Memory.recall/3` returns `{:ok, nil}` | The spec has no memory policy or it is disabled. | Add `memory ...` to the DSL, or pass a non-`false` memory policy when building the spec from data. |
| Memory entries are written but never returned | Mismatched `scope` or `session_id`. | Use the same `session_id` on both write and recall; for `scope: :agent`, pass no session id. |
| `in-memory memory store requires :pid` | The InMemory store was started but the `:pid` opt was not threaded through. | Pass `{Jidoka.Memory.Store.InMemory, pid: pid}` to `memory_store:`. |
| `{:error, :missing_memory_store}` from manual writes | `Jidoka.Memory.write/3` was called without `memory_store:`. | Supply the store explicitly; the runtime does not pull from application config. |
| Entries land in the prompt twice | A manual `write/3` plus `capture: :conversation` recorded the same content. | Pick one capture mode per agent or filter on `metadata["source"]`. |

## Reference

- [`Jidoka.Agent.Spec.Memory`](`Jidoka.Agent.Spec.Memory`) - memory policy
  fields, scopes, captures, injects.
- [`Jidoka.Memory`](`Jidoka.Memory`) - type aliases for the request/result
  structs.
- [`Jidoka.Memory.Store`](`Jidoka.Memory.Store`) - behaviour and
  `recall/2 | write/2 | list_entries/1` delegators.
- [`Jidoka.Memory.Store.InMemory`](`Jidoka.Memory.Store.InMemory`) -
  deterministic test store.
- [`Jidoka.Memory.RecallRequest`](`Jidoka.Memory.RecallRequest`) and
  [`Jidoka.Memory.RecallResult`](`Jidoka.Memory.RecallResult`) - recall data
  contract.
- [`Jidoka.Memory.WriteRequest`](`Jidoka.Memory.WriteRequest`) and
  [`Jidoka.Memory.WriteResult`](`Jidoka.Memory.WriteResult`) - write data
  contract.
- [`Jidoka.Memory.Entry`](`Jidoka.Memory.Entry`) - the entry struct stored
  per memory.
- [`Jidoka.Memory`](`Jidoka.Memory`) - public recall,
  write, and `capture_turn/4` helpers used by the runtime.

## Related Guides

- [Agent DSL](agent-dsl.md) - the `memory` block syntax and validation.
- [Tools And Operations](tools-and-operations.md) - operation contract used
  by tools that also write memory.
- [Inspection And Preflight](inspection-and-preflight.md) - how to see
  exactly what memory contributes to the assembled prompt.
- [Runtime And Harness](runtime-and-harness.md) - sessions, snapshots, and
  how capture interacts with hibernation.
