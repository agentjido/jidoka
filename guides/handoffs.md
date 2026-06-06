# Handoffs

A handoff transfers future conversation ownership to another agent. Jidoka
records the owner in `Jidoka.Handoff.OwnerStore`; your application reads that
data to route the next turn. A handoff is different from a subagent call:
handoffs change who owns the next turn, while subagents handle one bounded task
inside the current turn and return a result.

For a side-by-side choice between subagents and handoffs, start with
[Agent Orchestration](agent-orchestration.md). This guide focuses on the
handoff storage and routing contract.

## When To Use This

- Use this guide when one agent should permanently (until reset) take over
  a conversation, such as routing from a triage bot to a support specialist.
- Use this guide when integrating handoff routing into your own application
  dispatcher.
- Do not use this guide for one-shot delegation that returns a value to the
  caller; use the subagent source for that.
- Do not use this guide for short-term tool calls; those are operations
  (see [Tools And Operations](tools-and-operations.md)).

## Prerequisites

- A working Jidoka agent module (see [Getting Started](getting-started.md)).
- Familiarity with the operation contract from
  [Tools And Operations](tools-and-operations.md).
- No provider keys are required for the deterministic examples below.

```bash
mix deps.get
mix test
```

## Quick Example

A handoff source lives in the `tools` block and exposes one operation per
target agent. When the model calls that operation, the handoff is recorded
in the owner store and returned to the current turn as data.

```elixir
defmodule MyApp.SpecialistAgent do
  use Jidoka.Agent

  agent :specialist_agent do
    model "openai:gpt-4o-mini"
    instructions "You are a billing specialist."
  end
end

defmodule MyApp.TriageAgent do
  use Jidoka.Agent

  agent :triage_agent do
    model "openai:gpt-4o-mini"
    instructions "Hand off to specialist_agent for billing questions."
  end

  tools do
    handoff MyApp.SpecialistAgent, as: :specialist_agent
  end
end

llm = fn _intent, journal, _ctx ->
  case map_size(journal.results) do
    0 ->
      {:ok,
       %{
         type: :operation,
         name: "specialist_agent",
         arguments: %{
           "message" => "User has a billing question.",
           "conversation_id" => "conv-1"
         }
       }}

    _ ->
      {:ok, %{type: :final, content: "Connecting you to a specialist."}}
  end
end

{:ok, _result} = MyApp.TriageAgent.run_turn("Why is my bill higher?", llm: llm)

Jidoka.handoff("conv-1")
#=> %{agent: MyApp.SpecialistAgent, agent_id: "conv-1:specialist_agent", handoff: %Jidoka.Handoff{...}, updated_at_ms: 1_234}
```

After the turn, the application can read `Jidoka.handoff("conv-1")` to see
who owns future turns. Routing the next user message to that agent is the
application's responsibility.

## Concepts

A handoff is three pieces of data and one storage boundary.

1. **`Jidoka.Handoff`** is the validated record of a single transfer:
   `id`, `conversation_id`, `from_agent`, `to_agent`, `to_agent_id`,
   `name`, `message`, optional `summary`/`reason`, forwarded `context`,
   and `metadata`.
2. **`Jidoka.Operation.Source.Handoff`** is the operation source that
   compiles a DSL `handoff` entry into one `Agent.Spec.Operation` whose
   `idempotency` is `:unsafe_once` and `kind` is `:handoff`.
3. **`Jidoka.Handoff.OwnerStore`** is the storage behaviour:
   `owner/1`, `put_owner/2`, `reset/1`. The default store is
   `Jidoka.Handoff.OwnerStore.InMemory`, an ETS-backed table good for tests
   and single-node demos. Applications can configure another module through
   `:jidoka, :handoff_owner_store`.

```diagram
╭──────────────╮     ╭───────────────────────╮     ╭───────────────────╮
│ tools block  │────▶│ Operation.Source      │────▶│ Agent.Spec        │
│  handoff X   │     │   .Handoff (compile)  │     │   .Operation      │
╰──────────────╯     ╰───────────────────────╯     ╰─────────┬─────────╯
                                                              │
                                                              ▼
                                                   ╭──────────────────╮
                                                   │ Model decision   │
                                                   │ {:op, name, args}│
                                                   ╰─────────┬────────╯
                                                              │
                                                              ▼
                                          ╭─────────────────────────────╮
                                          │ Handoff source capability   │
                                          │  - validate arguments       │
                                          │  - build Jidoka.Handoff     │
                                          │  - put_owner/2              │
                                          │  - return data to the turn  │
                                          ╰─────────────┬───────────────╯
                                                        │
                                                        ▼
                          ╭─────────────────────────────────────────╮
                          │ OwnerStore (ETS or app-supplied module) │
                          ╰─────────────────────┬───────────────────╯
                                                │
                                                ▼
                                ╭───────────────────────────────╮
                                │ Jidoka.handoff(conversation)  │
                                │ -> %{agent, agent_id, ...}    │
                                ╰───────────────────────────────╯
```

The turn that invokes the handoff still completes normally. The current
agent receives the handoff payload (id, message, projected handoff data) as
the operation result and produces its final assistant content. The
ownership change only affects future turns the application chooses to route.

### Handoff Vs Subagent

| Aspect | Handoff | Subagent |
| --- | --- | --- |
| Scope | Future turns of a conversation. | One nested task during the current turn. |
| Result to caller | A small data payload (`handoff`, `owner`). | The subagent's structured output. |
| Idempotency | `:unsafe_once`. Recommended to gate with approval or a control. | `:idempotent` by default. |
| Routing | Application dispatcher reads `Jidoka.handoff/1`. | Jidoka runs the subagent call inside the turn. |
| Reset | `Jidoka.reset_handoff/1`. | N/A. |

Pick handoff when the persona for the next message should change. Pick
subagent when the current persona needs a focused helper to answer one
question.

## How To

### Step 1: Declare A Handoff In The DSL

The handoff source needs the target agent module (which must define
`spec/0`) and an operation name. `as:` controls the operation name and is
required when registering multiple handoffs for the same target.

```elixir
tools do
  handoff MyApp.SpecialistAgent,
    as: :specialist_agent,
    description: "Hand off billing questions to the specialist."
end
```

The compiled operation has:

- `name: "specialist_agent"`,
- `idempotency: :unsafe_once`,
- `metadata["source"] = "handoff"`, `metadata["kind"] = "handoff"`,
- a JSON-schema describing the expected arguments (`message`, optional
  `summary`, `reason`, `conversation_id`, `context`).

### Step 2: Run A Turn That Invokes The Handoff

Make sure the operation arguments include a `message` and, when you want
the owner to be tied to a conversation, a `conversation_id`. In production
the LLM produces those arguments; in tests, pin them in a fake LLM.

```elixir
llm = fn _intent, journal, _ctx ->
  case map_size(journal.results) do
    0 ->
      {:ok,
       %{
         type: :operation,
         name: "specialist_agent",
         arguments: %{
           "message" => "User has a billing question.",
           "conversation_id" => "conv-1",
           "reason" => "out of scope"
         }
       }}

    _ ->
      {:ok, %{type: :final, content: "Transferring you to a billing specialist."}}
  end
end

{:ok, result} = MyApp.TriageAgent.run_turn("Why is my bill higher?", llm: llm)
```

`result.content` carries the assistant's final message; the operation
result inside `result.agent_state.operation_results` carries the handoff
payload.

If the handoff should forward values from the turn request context, pass the
request context into the source boundary:

```elixir
request =
  Jidoka.Turn.Request.new!(
    input: "Why is my bill higher?",
    context: %{session_id: "conv-1", tenant: "acme"}
  )

{:ok, result} =
  MyApp.TriageAgent.run_turn(request, llm: llm)
```

### Step 3: Read Ownership From The Store

After the turn, the owner store has the new owner recorded under the
conversation id.

```elixir
case Jidoka.handoff("conv-1") do
  %{agent: agent_module, agent_id: agent_id, handoff: handoff} ->
    {agent_module, agent_id, handoff.message}

  nil ->
    :no_owner
end
#=> {MyApp.SpecialistAgent, "conv-1:specialist_agent", "User has a billing question."}
```

`agent_id` is derived from the handoff target. With `target: :auto`
(default) it becomes `"<conversation_id>:<operation_name>"`. With
`target: {:peer, peer_id}` or `{:peer, {:context, :key}}` the application
fully controls the id.

### Step 4: Route Future Turns

Routing belongs to the application. A typical dispatcher checks the store
first, then falls back to the original agent.

```elixir
def dispatch(conversation_id, input, opts \\ []) do
  case Jidoka.handoff(conversation_id) do
    %{agent: agent_module, handoff: handoff} ->
      agent_module.chat(input,
        context: Map.merge(handoff.context, %{handoff_summary: handoff.summary})
      )

    nil ->
      MyApp.TriageAgent.chat(input, opts)
  end
end
```

The harness never silently routes for you. This is intentional: the same
data drives logging, audit, and UI presentation.

### Step 5: Reset Ownership

When an interaction is over, or when the application wants its default
selection back, clear the owner.

```elixir
:ok = Jidoka.reset_handoff("conv-1")
Jidoka.handoff("conv-1")
#=> nil
```

`reset_handoff/1` is also useful in test teardown to keep the ETS table
clean between examples.

### Step 6: Gate Handoffs With A Control

Because handoff operations are `:unsafe_once`, declaring an explicit
operation control is the recommended pattern. The control matches on
`kind: :handoff` and can block, interrupt, or log:

```elixir
defmodule MyApp.ConfirmHandoff do
  use Jidoka.Control, name: "confirm_handoff"

  @impl true
  def call(%Jidoka.Runtime.Controls.OperationContext{} = op) do
    if op.metadata["agent"] == inspect(MyApp.SpecialistAgent) do
      {:interrupt, :handoff_requires_approval}
    else
      :cont
    end
  end
end

controls do
  operation MyApp.ConfirmHandoff, when: [kind: :handoff]
end
```

See [Controls](controls.md) for the full approval lifecycle.

## Common Patterns

- **Always include a `conversation_id`.** Without one the owner key falls
  back to the operation name, which is rarely what you want.
- **Use `target: {:peer, {:context, :session_id}}`** when you already track
  sessions in your application; the owner id then matches your existing
  identifier.
- **Forward only the public context.** The default `forward_context: :public`
  copies the parent's public context map. Tighten it with
  `forward_context: {:only, [...]}` when secrets might leak.
- **Reset after terminal events.** Clearing the owner after "ticket closed"
  or "session ended" stops stale handoffs from steering future traffic.
- **Pair handoffs with the InMemory owner store in tests.** Reset between
  examples to keep ETS entries from leaking across cases.

## Testing

Handoff tests focus on the data the source emits and the side effect on
the owner store. No provider call is needed.

```elixir
defmodule MyApp.TriageHandoffTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Jidoka.reset_handoff("conv-1")
    on_exit(fn -> Jidoka.reset_handoff("conv-1") end)
    :ok
  end

  test "records the specialist as the new owner" do
    request =
      Jidoka.Turn.Request.new!(
        input: "Why is my bill higher?",
        context: %{session_id: "conv-1", tenant: "acme"}
      )

    llm = fn _intent, journal, _ctx ->
      case map_size(journal.results) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "specialist_agent",
             arguments: %{
               "message" => "Billing question.",
               "conversation_id" => "conv-1"
             }
           }}

        _ ->
          {:ok, %{type: :final, content: "Transferring you."}}
      end
    end

    assert {:ok, _result} =
             MyApp.TriageAgent.run_turn(request, llm: llm)

    assert %{
             agent: MyApp.SpecialistAgent,
             agent_id: "conv-1:specialist_agent",
             handoff: %Jidoka.Handoff{message: "Billing question."}
           } = Jidoka.handoff("conv-1")
  end
end
```

For applications using a custom store, replace
`Jidoka.Handoff.OwnerStore.InMemory` through application configuration; the
public `Jidoka.handoff/1` and `Jidoka.reset_handoff/1` calls do not change.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, {:invalid_handoff_module, ...}}` at compile time | The target module does not define `spec/0`. | Make sure the target uses `Jidoka.Agent` (or otherwise exposes `spec/0`). |
| `{:error, {:invalid_handoff_payload, :message}}` at runtime | The LLM called the operation without a non-empty `message` argument. | Tighten the prompt or supply a richer description; the schema requires `message`. |
| `Jidoka.handoff(id)` returns `nil` after a turn | The arguments did not include a `conversation_id` and the context did not provide one either. | Either pass a `conversation_id` argument, set it in the turn `context:`, or use a `target: {:peer, ...}` mapping. |
| `{:error, {:missing_handoff_peer_context, key}}` | A `{:peer, {:context, key}}` target needed a context value that was not present. | Add the key to `context:` for the turn (`context: %{tenant_id: ...}`). |
| ETS owner store leaks across tests | The default InMemory store is process-wide. | Call `Jidoka.reset_handoff/1` in `setup`/`on_exit`, or configure a per-test store module. |

## Reference

- [`Jidoka.Handoff`](`Jidoka.Handoff`) - the handoff data contract:
  `new/2`, `new!/2`, `from_input/2`, struct fields.
- [`Jidoka.Operation.Source.Handoff`](`Jidoka.Operation.Source.Handoff`) -
  operation source that compiles a `tools do handoff ... end` entry.
- [`Jidoka.Handoff.OwnerStore`](`Jidoka.Handoff.OwnerStore`) - storage
  behaviour and delegator: `owner/1`, `put_owner/2`, `reset/1`.
- [`Jidoka.Handoff.OwnerStore.InMemory`](`Jidoka.Handoff.OwnerStore.InMemory`) -
  default ETS-backed store.
- [`Jidoka`](`Jidoka`) - public facade: `Jidoka.handoff/1`,
  `Jidoka.reset_handoff/1`.

## Related Guides

- [Tools And Operations](tools-and-operations.md) - the operation contract
  the handoff source rides on.
- [Controls](controls.md) - input/operation/output policy, including the
  approval flow recommended for `:unsafe_once` handoffs.
- [Agent DSL](agent-dsl.md) - the `tools` block and how `handoff` is
  authored.
- [Runtime And Harness](runtime-and-harness.md) - sessions, snapshots, and
  how an application dispatcher reads ownership between turns.
