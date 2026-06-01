# Agent Spec Contract

`Jidoka.Agent.Spec` is the immutable definition of a Jidoka agent. Every
authoring path (Spark DSL, JSON/YAML import, `Jidoka.agent/1`) compiles into
the same struct, and every downstream layer (`Turn.Plan`, harness, snapshots)
consumes that struct as its single source of truth. This guide enumerates each
field and the constructors that produce a valid spec.

## When To Use This

- Use this guide when you need to know the **exact shape** of an agent
  definition, for example when building a custom authoring path, an importer,
  or a snapshot inspector.
- Use this guide when you want to confirm what is and is not stored on a spec
  (clients, processes, and credentials are not).
- Do not use this guide as an introduction to authoring agents. Start with
  [Getting Started](getting-started.md) and [Agent DSL](agent-dsl.md).

## Prerequisites

- You can compile and run the `:jidoka` test suite.
- You have read the spec section of [Getting Started](getting-started.md).

```bash
mix deps.get
mix test
```

## Quick Example

`Jidoka.Agent.Spec.new!/1` is the canonical constructor. The DSL and the
importer both end up calling it (directly or through `from_input/1`).

```elixir
alias Jidoka.Agent.Spec

spec =
  Spec.new!(
    id: "time_agent",
    instructions: "Call local_time when asked for the time.",
    model: "openai:gpt-4o-mini",
    generation: %{temperature: 0.0, max_tokens: 500},
    operations: [
      %{name: "local_time", description: "Returns local time for a city."}
    ]
  )

spec.id           #=> "time_agent"
spec.controls     #=> %Jidoka.Agent.Spec.Controls{max_turns: nil, ...}
spec.result       #=> nil (no structured result declared)
```

A spec is plain data. It contains no processes, no provider clients, and no
credentials. It can be inspected, diffed, serialized, and shipped across
versions without leaking anything runtime-specific.

## Concepts

A spec is a closed contract between authoring and runtime. The runtime never
reads anything the spec does not expose.

```diagram
╭──────────────╮     ╭──────────────╮     ╭──────────────╮
│   DSL /      │────▶│  Spec.new!   │────▶│  Agent.Spec  │
│   Import     │     │  Spec.new    │     │  (immutable) │
╰──────────────╯     ╰──────────────╯     ╰──────┬───────╯
                                                 │
                                                 ▼
                                         ╭───────────────╮
                                         │  Turn.Plan    │
                                         ╰───────────────╯
```

The fields below are the entire surface. Anything else (capabilities, stores,
keys) is supplied at run time through harness options.

## Fields

| Field | Type | Default | Purpose |
| --- | --- | --- | --- |
| `id` | non-empty string | required | Stable identifier used by snapshots, sessions, and traces. |
| `instructions` | non-empty string | required | System-style instructions injected into prompt assembly. |
| `model` | `%LLMDB.Model{}` | `Jidoka.Config.default_model/0` | Normalized model spec. Strings such as `"openai:gpt-4o-mini"` are normalized through ReqLLM. |
| `generation` | `Jidoka.Agent.Spec.Generation.t()` | `Jidoka.Config.default_generation/0` | Provider-neutral generation defaults (`params`, `provider_options`, `extra`). |
| `context_schema` | Zoi schema or `nil` | `nil` | Optional schema used by `Spec.validate_context/2` against the per-turn context map. |
| `result` | `Jidoka.Agent.Spec.Result.t()` or `nil` | `nil` | Optional structured result contract (Zoi schema plus `max_repairs`). |
| `memory` | `Jidoka.Agent.Spec.Memory.t()` or `nil` | `nil` | Optional conversation memory policy. Runtime stores are injected separately. |
| `operations` | `[Jidoka.Agent.Spec.Operation.t()]` | `[]` | Model-callable operation definitions (data only; the operation source supplies the capability). |
| `controls` | `Jidoka.Agent.Spec.Controls.t()` | `Controls.new!()` | Policy controls (input/operation/output, `max_turns`, `timeout_ms`). |
| `runtime_defaults` | map | `%{}` | Default knobs consumed by `Turn.Plan.new/1` (`:workflow_profile`, `:max_model_turns`, `:timeout_ms`). |
| `metadata` | map | `%{}` | Caller-defined metadata; opaque to Jidoka. |

### `id` And `instructions`

Both are required non-empty strings. `id` is the spec identity used everywhere
durable (sessions, snapshots, traces). `instructions` is the system-style
prompt body assembled into each turn.

### `model`

Stored as a normalized `%LLMDB.Model{}` struct. `Spec.new/1` accepts any
ReqLLM-supported model input and runs it through
[`Jidoka.Config.normalize_model_spec/2`](`Jidoka.Config`). Use
[`Jidoka.Config.model_ref/1`](`Jidoka.Config`) to read it back as a
`"provider:id"` string.

### `generation`

A [`Jidoka.Agent.Spec.Generation`](`Jidoka.Agent.Spec.Generation`) struct with
three maps:

- `params` - known, provider-neutral keys (`:temperature`, `:max_tokens`,
  `:top_p`, `:tool_choice`, etc.).
- `provider_options` - opaque provider-specific knobs forwarded to ReqLLM.
- `extra` - escape hatch for caller metadata.

### `context_schema` And Per-Turn Context

`context_schema` is a Zoi schema (or `nil`). The runtime validates the per-turn
context map through `Spec.validate_context/2`. A missing schema accepts any
map.

### `result`

A [`Jidoka.Agent.Spec.Result`](`Jidoka.Agent.Spec.Result`) struct describing
the structured app-facing return value. The Zoi schema and a bounded
`max_repairs` count drive the structured-result repair loop in
`Turn.State`. When `result` is `nil`, the turn returns plain assistant text.

### `memory`

A [`Jidoka.Agent.Spec.Memory`](`Jidoka.Agent.Spec.Memory`) policy describing
`scope` (`:agent` or `:session`), `capture` (`:manual`, `:conversation`,
`:off`), `inject` (`:instructions` or `:context`), `max_entries`, and an
optional `namespace`. The policy is definition data; the actual
`Jidoka.Memory.Store` is supplied per run.

### `operations`

A list of [`Jidoka.Agent.Spec.Operation`](`Jidoka.Agent.Spec.Operation`)
structs. Each operation carries a `name`, optional `description`, an
`idempotency` value (`:pure`, `:idempotent`, `:dedupe`, `:reconcile`,
`:unsafe_once`), and `metadata`. Operations are data; the executable capability
comes from a `Jidoka.Operation.Source`.

### `controls`

A [`Jidoka.Agent.Spec.Controls`](`Jidoka.Agent.Spec.Controls`) struct with
`max_turns`, `timeout_ms`, and three control lists (`inputs`, `operations`,
`outputs`). Used by the runtime for policy enforcement; see
[Controls](controls.md).

### `runtime_defaults` And `metadata`

Plain maps. `runtime_defaults` feeds defaults into
[`Jidoka.Turn.Plan.new/1`](`Jidoka.Turn.Plan`). `metadata` is opaque caller
data.

## Common Patterns

- **Build specs from maps, not strings.** Strings cross the import boundary;
  in-process code should call `Spec.new!/1` with a map or keyword list.
- **Treat the spec as a value.** Pass it by reference, snapshot it, diff it.
  Never mutate it.
- **Reuse `Spec.from_input/1`** when a caller may already hold a `%Spec{}`. It
  delegates to `Spec.new/1` and accepts both.
- **Keep adapter metadata in `Operation.metadata`.** Source kinds (`:action`,
  `:ash_resource`, `:browser`, `:mcp`, etc.) are discovered through
  `Jidoka.Agent.Spec.Operation.kind/1`.

## Testing

A spec test is the cheapest unit test in the system: build it, assert on its
fields, optionally compile a plan.

```elixir
test "compiles a tool_loop plan from a minimal spec" do
  spec =
    Spec.new!(
      id: "echo",
      instructions: "Echo the user input.",
      model: "openai:gpt-4o-mini"
    )

  assert {:ok, plan} = Jidoka.Turn.Plan.new(spec)
  assert plan.workflow_profile == :tool_loop
  assert plan.max_model_turns == Jidoka.Config.default_max_model_turns()
end
```

For coverage of the DSL/import to spec contract, see
`test/jidoka/golden/dsl_to_spec_test.exs`.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `ArgumentError: invalid agent spec: ...` | A required field is missing or a value failed Zoi parsing. | Inspect the inner reason; common fixes are non-empty `id`/`instructions` and a valid `model` string. |
| `{:error, {:invalid_context_schema, _}}` | `context_schema` is not a Zoi schema. | Pass a `Zoi.*` value or `nil`. |
| `{:error, {:unsafe_once_requires_control, name, kind}}` | An `:unsafe_once` operation has no matching operation control. | Add a control entry under `controls.operations` for that operation. See [Controls](controls.md). |
| `{:error, {:invalid_result_schema, _}}` | `result` was given a non-Zoi value. | Wrap the schema with `Zoi.*` constructors before passing it. |
| Spec inspection shows live processes or keys | You injected a runtime value into a spec field. | Move runtime values to harness options (`llm:`, `operations:`, `memory_store:`). |

## Reference

- [`Jidoka.Agent.Spec`](`Jidoka.Agent.Spec`) - canonical struct, `new/1`,
  `new!/1`, `from_input/1`, `validate_context/2`, `validate_result/2`,
  `validate_operation_policies/1`.
- [`Jidoka.Agent.Spec.Controls`](`Jidoka.Agent.Spec.Controls`) - control
  policy struct.
- [`Jidoka.Agent.Spec.Generation`](`Jidoka.Agent.Spec.Generation`) - generation
  defaults.
- [`Jidoka.Agent.Spec.Memory`](`Jidoka.Agent.Spec.Memory`) - memory policy.
- [`Jidoka.Agent.Spec.Operation`](`Jidoka.Agent.Spec.Operation`) - operation
  definition + `idempotency`, `kind/1`, `requires_control?/1`.
- [`Jidoka.Agent.Spec.Result`](`Jidoka.Agent.Spec.Result`) - structured result
  contract.
- [`Jidoka.Config`](`Jidoka.Config`) - default model, generation, max turns,
  turn timeout.

## Related Guides

- [Agent DSL](agent-dsl.md) - DSL surface that compiles into this spec.
- [Controls](controls.md) - `Spec.Controls` policy semantics.
- [Structured Results](structured-results.md) - `Spec.Result` and the repair
  loop.
- [Turn And Effect Contracts](turn-and-effect-contracts.md) - the next layer
  down.
- [Errors And Config Reference](errors-and-config-reference.md) - defaults
  used by `Spec.new/1`.
