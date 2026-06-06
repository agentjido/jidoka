# Tools And Operations

Tools are model-callable work. Jidoka gives the model one operation contract:
name, description, parameters, and metadata. Actions, Ash resources, browser
tools, MCP tools, workflows, and subagents all compile to that shape.

## Use This When

- authoring a new tool for an agent;
- debugging "the model called the wrong operation" or
  "the operation handler was not found".
- writing deterministic tests that need a known set of
  operations.
- skip this guide for memory writes; use [Memory](memory.md).

## Prerequisites

- A working Jidoka project (see [Getting Started](getting-started.md)).
- Familiarity with `Jido.Action` and Zoi schemas.
- A provider key in scope for live examples.

```bash
mix deps.get
mix test
```

## Define A Tool

The minimum example is one `Jidoka.Action` and one DSL agent that lists it.

```elixir
defmodule MyApp.Tools.LocalTime do
  use Jidoka.Action,
    name: "local_time",
    description: "Returns the local time for a city.",
    schema: Zoi.object(%{city: Zoi.string() |> Zoi.default("Chicago")})

  @impl true
  def run(params, _context) do
    city = Map.get(params, :city) || Map.get(params, "city") || "Chicago"
    {:ok, %{city: city, time: "09:30"}}
  end
end

defmodule MyApp.TimeAgent do
  use Jidoka.Agent

  agent :time_agent do
    model "openai:gpt-4o-mini"
    instructions "Call local_time when asked for the time."
  end

  tools do
    action MyApp.Tools.LocalTime
  end
end

{:ok, text} = MyApp.TimeAgent.chat("What time is it in Chicago?")
```

The model sees an operation named `"local_time"`. If it calls the operation,
Jidoka runs `MyApp.Tools.LocalTime`, sends the result back to the model, and
returns the final answer.

## Concepts

A Jidoka operation has two parts:

1. **Operation metadata** (`Jidoka.Agent.Spec.Operation`) is pure data the
   model sees: name, description, parameter schema (in `metadata`),
   idempotency policy, and a free-form `metadata` map that includes the
   originating `source` (action, ash_resource, browser, mcp, subagent,
   handoff, workflow, local) and a `kind` tag used for control
   matching.
2. **Runtime capability** is a 3-arity function Jidoka calls with the
   `Jidoka.Effect.Intent`, the current `Jidoka.Effect.Journal`, and a
   `%Jidoka.Context{}`. Its job is to resolve the call to `{:ok, output}` or
   `{:error, reason}`.

```diagram
╭───────────────╮     ╭──────────────────────╮     ╭────────────────╮
│  tools block  │────▶│ Agent.Spec.Operation │────▶│ Model decision │
│  (or source)  │     │  (name + metadata)   │     ╰────────┬───────╯
╰───────┬───────╯     ╰──────────────────────╯              │
        │                                                   │ {:operation, name, args}
        │                                                   │ or {:operations, [...]}
        ▼                                                   ▼
╭───────────────────────╮                       ╭────────────────────╮
│ Runtime capability fn │◀──────────────────────│ Operation request  │
│ (intent, journal)     │   Jidoka invokes      │                    │
╰───────────┬───────────╯                       ╰────────────────────╯
            │
            ▼
     {:ok, output} | {:error, reason}
```

The model asks for one operation or an ordered batch of independent operations.
Jidoka records each intent, executes allowed batch members through Runic with a
bounded concurrency limit, records each result in the turn journal, then asks
the model for the final answer.

### Operation Kinds And Matching

`Jidoka.Agent.Spec.Operation.kind/1` returns one of `:action`, `:operation`,
`:tool`, `:ash_resource`, `:browser`, `:skill`, `:mcp`, `:workflow`,
`:subagent`, `:handoff`. Operation controls in the `controls`
block match against `kind`, `name`, `source`, `idempotency`, and arbitrary
`metadata` keys:

```elixir
operation MyApp.RequireApproval,
  when: [kind: :handoff]

operation MyApp.LogTransfers,
  when: [name: :transfer_funds, idempotency: :unsafe_once]

operation MyApp.SourceGuard,
  when: [source: "mcp"]
```

The first matching control wins per intent. See [Controls](controls.md) for
the policy decisions a control can return.

When a batch contains an operation control that interrupts for review, Jidoka
hibernates before starting any operation capability in that batch. After
approval, the batch resumes from the pending intents.

### Idempotency Policies (Overview)

Every operation declares one of:

- `:pure` - safe to call repeatedly, no side effects.
- `:idempotent` - default; safe to retry, the runtime may de-duplicate by
  payload.
- `:dedupe` - the operation expects the runtime to skip duplicate intents
  inside a turn.
- `:reconcile` - the runtime should re-derive the result from authoritative
  state on replay.
- `:unsafe_once` - the operation must run at most once; replay requires a
  recorded result. Add `approval: true` or a matching operation control before
  compiling the plan.

This guide covers the authoring path. Full idempotency, pause/resume, and replay
behavior live in [Runtime And Harness](runtime-and-harness.md).

## How To

### Step 1: Author A Tool With Jidoka.Action

`Jidoka.Action` wraps `Jido.Action`. The `:name` and
`:schema` are what the model sees; everything else feeds into the
`Agent.Spec.Operation` metadata.

```elixir
defmodule MyApp.Tools.Echo do
  use Jidoka.Action,
    name: "echo",
    description: "Echoes a phrase back.",
    schema: Zoi.object(%{phrase: Zoi.string()})

  @impl true
  def run(%{phrase: phrase}, _context), do: {:ok, %{echoed: phrase}}
end
```

Add it to the agent:

```elixir
tools do
  action MyApp.Tools.Echo
end
```

The compiled spec now includes:

```elixir
%Jidoka.Agent.Spec.Operation{
  name: "echo",
  description: "Echoes a phrase back.",
  idempotency: :idempotent,
  metadata: %{"source" => "jido_action", "kind" => "action", ...}
}
```

For risky actions, attach approval at the same declaration:

```elixir
tools do
  action MyApp.Tools.DeleteRecord,
    idempotency: :unsafe_once,
    approval: [
      reason: :delete_requires_review,
      message: "Review the delete before execution."
    ]
end
```

When the model calls the operation, Jidoka hibernates before execution and
exposes a `Jidoka.Review.Request`. See [Human In The Loop](human-in-the-loop.md).

### Step 2: Match Operations With Controls

Operation controls run before the runtime executes the capability. They
gate, log, or interrupt model-chosen calls.

```elixir
defmodule MyApp.NoExternalBrowser do
  use Jidoka.Control, name: "no_external_browser"

  @impl true
  def call(%Jidoka.Runtime.Controls.OperationContext{} = op) do
    if op.metadata["source"] == "browser", do: {:block, :browser_blocked}, else: :cont
  end
end

controls do
  operation MyApp.NoExternalBrowser, when: [kind: :browser]
end
```

The `when` map can mix `:kind`, `:name`, `:source`, `:idempotency`, and any
key inside `metadata`. Matching is exact string/atom comparison.

### Step 3: Expose Local Capabilities In Tests

The fastest way to provide operations without writing modules is
`Jidoka.Operation.Source.Local`. It compiles a list of `{name, handler}`
entries into both the operation metadata and a runtime capability.

```elixir
{:ok, %{operations: operations, capability: capability}} =
  Jidoka.Operation.Source.compile(
    Jidoka.Operation.Source.Local.new!(
      operations: [
        %{name: "local_time", handler: fn _args -> {:ok, %{time: "09:30"}} end},
        %{name: "echo", handler: fn %{"phrase" => phrase} -> {:ok, %{echoed: phrase}} end}
      ]
    )
  )

spec =
  Jidoka.agent!(
    id: "ops_demo",
    model: "openai:gpt-4o-mini",
    instructions: "Use the available operations.",
    operations: operations
  )

llm = fn _intent, journal, _ctx ->
  case map_size(journal.results) do
    0 -> {:ok, %{type: :operation, name: "echo", arguments: %{"phrase" => "hi"}}}
    _ -> {:ok, %{type: :final, content: "done"}}
  end
end

{:ok, result} = Jidoka.turn(spec, "ping", llm: llm, operations: capability)
result.content
#=> "done"
```

Local handlers may be `(args -> term)` or `(intent, journal -> term)`. A bare
term return value is wrapped in `{:ok, value}`.

### Step 4: Use Source-Backed Tools

The DSL exposes higher-level sources that all compile to operations:

```elixir
tools do
  action MyApp.Tools.LocalTime
  ash_resource MyApp.Accounts.User, actions: [:read]
  browser :docs, allow: ["docs.example.com"]
end
```

Each entry contributes one or more `Agent.Spec.Operation` entries with
distinct names. Duplicate operation names are a compile error.

### Step 5: Inspect The Resulting Operations

Before you spend a token, check the compiled operations and metadata:

```elixir
Jidoka.inspect(MyApp.TimeAgent).spec.operations
#=> [%{name: "local_time", idempotency: :idempotent, metadata: %{"kind" => "action", ...}}]

{:ok, preflight} = Jidoka.preflight(MyApp.TimeAgent, "What time is it?")
preflight.prompt.tool_definitions
```

`preflight` shows exactly what the prompt assembler will hand the model, so
you can confirm names, descriptions, and parameter schemas line up with what
the LLM expects.

## Common Patterns

- **One operation per side effect.** Smaller operations match better and
  control rules read more clearly.
- **Use `Jidoka.Action` for production tools.** It gives schema validation,
  consistent error shapes, and Jido instrumentation for free.
- **Use `Jidoka.Operation.Source.Local` for tests and one-off demos.** It
  removes module ceremony and keeps the LLM/operation contract obvious.
- **Tag your operations.** A short `metadata: %{"kind" => :transfer}` makes
  control matching `when: [kind: :transfer]` work without surprise.
- **Default to `:idempotent`.** Reserve `:unsafe_once` for genuinely
  irreversible side effects so Jidoka can require approval before running
  them.

## Testing

A deterministic operation test pins both the LLM decision and the operation
result. The runtime never reaches a provider.

```elixir
defmodule MyApp.TimeAgentTest do
  use ExUnit.Case, async: true

  test "uses the local_time operation" do
    operations =
      Jidoka.Runtime.LocalOperations.operations(%{
        "local_time" => fn %{"city" => city} -> {:ok, %{city: city, time: "09:30"}} end
      })

    llm = fn _intent, journal, _ctx ->
      case map_size(journal.results) do
        0 -> {:ok, %{type: :operation, name: "local_time", arguments: %{"city" => "Chicago"}}}
        _ -> {:ok, %{type: :final, content: "Chicago time is 09:30."}}
      end
    end

    assert {:ok, result} =
             Jidoka.turn(MyApp.TimeAgent, "What time is it?",
               llm: llm,
               operations: operations
             )

    assert result.content =~ "09:30"

    [operation_result] =
      result.agent_state.operation_results

    assert operation_result.operation == "local_time"
  end
end
```

`Jidoka.Runtime.LocalOperations.operations/1` is the test helper for
building an operation capability from a map of handlers. The same helper
backs `Jidoka.Operation.Source.Local`.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, {:missing_operation_handler, name}}` | The LLM chose an operation no capability resolves. | Add the handler to the registered capability, or restrict the prompt so the model cannot pick it. |
| `{:error, {:unsupported_effect_kind, kind}}` | A capability was handed an intent it does not understand. | Make sure the capability matches the intent kind (`:operation`); chain capabilities with a router if you serve multiple kinds. |
| `tool :name is defined more than once` at compile time | Two DSL entries produced the same operation name. | Rename one entry (`as: :other_name` on subagent/handoff, or pick a different action). |
| Operation control never fires | `when:` did not match `kind/name/source/metadata`. | Inspect `Jidoka.inspect(agent).spec.operations` to see the exact metadata, then mirror the keys in `when:`. |
| Live model picks invalid `arguments` | Schema in the action does not match the LLM-facing description. | Tighten the schema or update the description; preflight shows the JSON-schema the model receives. |

## Reference

- [`Jidoka.Agent.Spec.Operation`](`Jidoka.Agent.Spec.Operation`) - operation
  data, `kind/1`, `requires_control?/1`, `replay_safe?/1`.
- [`Jidoka.Operation.Source`](`Jidoka.Operation.Source`) - behaviour for
  sources that compile to operations plus a capability.
- [`Jidoka.Operation.Source.Local`](`Jidoka.Operation.Source.Local`) - the
  function-backed source used by tests and examples.
- [`Jidoka.Runtime.LocalOperations`](`Jidoka.Runtime.LocalOperations`) -
  capability builder for raw handler maps.
- [`Jidoka.Action`](`Jidoka.Action`) - the Jido action wrapper used in
  production tools.
- Tool-source compiler - internal compiler
  from DSL entries to operations and capabilities.

## Related Guides

- [Agent DSL](agent-dsl.md) - the DSL that owns the `tools`
  block.
- [Workflows](workflows.md) - deterministic multi-step work exposed as one
  operation.
- [Controls](controls.md) - input/operation/output policy and approvals.
- [Handoffs](handoffs.md) - the handoff source and conversation ownership.
- [Testing And Evals](testing-and-evals.md) - golden DSL-to-spec tests and
  the `Jidoka.Eval` runner.
- [Inspection And Preflight](inspection-and-preflight.md) - debugging the
  compiled operations and prompt before running a turn.
