# Operation Source Contracts

`Jidoka.Operation.Source` is the single seam between the runtime and any
external operation surface (Jido actions, Ash resources, browsers, MCP
servers, sub-agents, workflows). Every source compiles to the same two
outputs: a list of `Jidoka.Agent.Spec.Operation` data and one runtime
capability function. This guide documents that contract and shows how the
built-in sources adopt it.

## When To Use This

- Use this guide when authoring a new operation source (custom backend,
  internal tool registry, third-party SDK adapter).
- Use this guide when wiring multiple sources together into one agent.
- Do not use this guide for authoring individual operations or actions; for
  that see [Agent DSL](agent-dsl.md) and `Jidoka.Action`.

## Prerequisites

- You have read [Agent Spec Contract](agent-spec-contract.md) and
  [Turn And Effect Contracts](turn-and-effect-contracts.md).
- You can build and run a Jidoka turn.

## Quick Example

`Source.Local` is the simplest source. It compiles a list of in-process
handlers into the same shape every other source returns.

```elixir
alias Jidoka.Operation.Source

{:ok, source} =
  Source.Local.new(
    operations: [
      %{
        name: "local_time",
        description: "Returns local time for a city.",
        handler: fn args ->
          {:ok, %{city: Map.get(args, "city", "Chicago"), time: "09:30"}}
        end
      }
    ]
  )

{:ok, compiled} = Source.compile(source)

compiled.operations
#=> [%Jidoka.Agent.Spec.Operation{name: "local_time", ...}]

compiled.capability
#=> #Function<...>   (operation_capability/2)
```

`compiled.operations` is what the spec stores. `compiled.capability` is what
the harness invokes when an LLM decides to call an operation.

## Concepts

```diagram
╭───────────────╮     ╭──────────────────╮     ╭─────────────────────╮
│ Source struct │────▶│ Source.compile/1 │────▶│ %{operations,       │
│ (Local,       │     │                  │     │   capability}       │
│  Ash, MCP,    │     ╰──────────────────╯     ╰──────────┬──────────╯
│  Browser, …)  │                                         ▼
╰───────────────╯                              ╭──────────────────────╮
                                               │  Turn.State pending   │
                                               │  Effect.Intent        │
                                               │  └─ capability.(…)    │
                                               ╰──────────────────────╯
```

A source is a struct that implements the `Jidoka.Operation.Source` behaviour.
Two callbacks - `operations/2` and `capability/2` - return the data and the
function the runtime needs. `Source.compile/1` validates name uniqueness
across multiple sources and produces a single routed capability.

## Fields

### `compile/1` Output

`Jidoka.Operation.Source.compile/2` returns `{:ok, compiled()}` where:

| Field | Type | Purpose |
| --- | --- | --- |
| `operations` | `[Jidoka.Agent.Spec.Operation.t()]` | Flat list across all sources, suitable for `Agent.Spec.operations`. |
| `capability` | `t:Jidoka.Runtime.Capabilities.operation_capability/0` | Routed function: looks up the source by operation name and forwards the intent. |

Duplicate operation names across sources fail with
`{:error, {:duplicate_operation_source_name, name}}`.

### `operation_capability/2` Signature

The capability is a two-arity function that mirrors the LLM capability shape:

```elixir
@type operation_capability ::
        (Jidoka.Effect.Intent.t(), Jidoka.Effect.Journal.t() ->
           {:ok, term()} | {:error, term()})
```

| Argument | Purpose |
| --- | --- |
| `Effect.Intent` (kind `:operation`) | Carries the normalized `Effect.OperationRequest` payload, idempotency key, and id. |
| `Effect.Journal` | Read-only view of recorded intents/results, used for replay-safety checks. |

The capability returns the raw operation output on success. The runtime wraps
that output into an `Effect.Result` and an `Effect.OperationResult` for you;
sources should not build those structs themselves.

### `Jidoka.Operation.Source` Behaviour

Two callbacks form the contract:

| Callback | Purpose |
| --- | --- |
| `operations(source, opts) :: {:ok, [Spec.Operation.t()]} \| {:error, term()}` | Return the operation data the spec will store. |
| `capability(source, opts) :: {:ok, operation_capability()} \| {:error, term()}` | Return the executor function. |

Sources are plain structs. The first positional argument to each callback is a
`%__MODULE__{}`; the second is an opts keyword forwarded from
`Source.compile/2`.

### `Source.Local`

In-process operation source for tests and lightweight tools.

| Field | Type | Purpose |
| --- | --- | --- |
| `:operations` | `[operation_def()]` | List of `%{name, handler, description?, idempotency?, kind?, metadata?}` entries. |

Handlers must be 1- or 2-arity functions returning `{:ok, term()}` or
`{:error, term()}`. See [`Jidoka.Operation.Source.Local`](`Jidoka.Operation.Source.Local`).

### Other Built-In Sources

All adopt the same `Source` behaviour:

- [`Jidoka.Operation.Source.MCP`](`Jidoka.Operation.Source.MCP`) - MCP server
  tools.
- [`Jidoka.Operation.Source.Subagent`](`Jidoka.Operation.Source.Subagent`) -
  nested Jidoka agent as a callable operation.
- [`Jidoka.Operation.Source.Handoff`](`Jidoka.Operation.Source.Handoff`) -
  hand-off operations.
- [`Jidoka.Operation.Source.Workflow`](`Jidoka.Operation.Source.Workflow`) -
  workflow-backed operations.

External integrations such as Ash/Jido and the browser source ship in their
own packages but compile to the same `%{operations, capability}` output.

## Common Patterns

- **Compile once, reuse everywhere.** Build the source struct at boot or in a
  module attribute; call `Source.compile/1` only when materializing a spec.
- **Combine sources by listing them.** `Source.compile([local, mcp])`
  returns one routed capability the harness can call directly.
- **Keep capability functions pure-ish.** Capabilities should be deterministic
  given the intent and journal; record any external state through the
  operation's output so the journal stays authoritative.
- **Use `Effect.OperationRequest.from_input/1`** inside capabilities to decode
  the payload safely instead of pattern-matching the raw map.

## Testing

A source test only needs the compile output and an `Effect.Intent`. No harness
is required.

```elixir
test "local source executes its handler" do
  {:ok, source} =
    Jidoka.Operation.Source.Local.new(
      operations: [
        %{name: "echo", handler: fn args -> {:ok, args} end}
      ]
    )

  {:ok, compiled} = Jidoka.Operation.Source.compile(source)

  intent =
    Jidoka.Effect.Intent.new(:operation,
      %{name: "echo", arguments: %{"value" => 42}},
      idempotency: :pure
    )

  assert {:ok, %{"value" => 42}} =
           compiled.capability.(intent, Jidoka.Effect.Journal.new!())
end
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, {:duplicate_operation_source_name, name}}` | Two sources publish the same operation. | Rename one operation or drop the duplicate source. |
| `{:error, {:missing_operation_handler, name}}` | The compiled capability cannot route the operation. | Ensure the operation is published by a source compiled into the same plan. |
| `{:error, {:unsupported_effect_kind, kind}}` | Capability was called with an `:llm` intent. | Operation capabilities only handle `:operation` intents; route LLM intents through `Runtime.Capabilities.llm`. |
| Local source raises `invalid_operation_handler` | Handler is not 1- or 2-arity. | Use `fn args -> ... end` or `fn args, context -> ... end`. |

## Reference

- [`Jidoka.Operation.Source`](`Jidoka.Operation.Source`) - behaviour and
  `compile/2`.
- [`Jidoka.Operation.Source.Local`](`Jidoka.Operation.Source.Local`) -
  in-process source.
- [`Jidoka.Operation.Source.MCP`](`Jidoka.Operation.Source.MCP`),
  [`Jidoka.Operation.Source.Subagent`](`Jidoka.Operation.Source.Subagent`),
  [`Jidoka.Operation.Source.Handoff`](`Jidoka.Operation.Source.Handoff`),
  [`Jidoka.Operation.Source.Workflow`](`Jidoka.Operation.Source.Workflow`).
- [`Jidoka.Runtime.Capabilities`](`Jidoka.Runtime.Capabilities`) - capability
  bundle consumed by the harness.
- [`Jidoka.Effect.OperationRequest`](`Jidoka.Effect.OperationRequest`).

## Related Guides

- [Agent Spec Contract](agent-spec-contract.md) - where compiled operations
  live.
- [Turn And Effect Contracts](turn-and-effect-contracts.md) - the
  `Effect.Intent` shape capabilities consume.
- [Runtime And Harness](runtime-and-harness.md) - how the routed capability
  is invoked at run time.
