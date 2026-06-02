# Projection Internals

`Jidoka.Projection` is the single dispatch surface that converts every Jidoka
data contract into a stable, compact map. Projections are deliberately smaller
than raw structs: they omit Zoi schemas, full `LLMDB.Model` structs, Spark
module metadata, and other implementation-private values. They are the
contract shared by `Jidoka.inspect/2`, golden tests, trace sinks, replay
scaffolding, and UI consumers like `Jidoka.AgentView`. This guide walks the
dispatch table, explains why projections look the way they do, and gives
contributors the rules for adding or changing a projection without breaking
external consumers. It is written for people maintaining
`Jidoka.Projection`, `Jidoka.Inspection`, and `Jidoka.AgentView`, not for
agent authors.

## When To Use This

- Use this guide before adding or modifying a `project/1` clause.
- Use this guide when introducing a new Jidoka data struct that should be
  inspectable (it needs a `project/1` clause, often a matching
  `Jidoka.Inspection.inspect/2` clause, and golden coverage).
- Use this guide when removing a field from a struct, because consumers may
  depend on the projection key being present.
- Do not use this guide as a tutorial on debugging an agent. Authors should
  read [Inspection And Preflight](inspection-and-preflight.md) for the
  user-facing surface.

## Prerequisites

- Elixir `~> 1.18` and a checkout of the `jidoka` package.
- Familiarity with the structs in `lib/jidoka/agent.ex`, `lib/jidoka/turn/`,
  and `lib/jidoka/effect/`.
- Awareness that golden tests in `test/jidoka/golden/` snapshot projection
  output verbatim.

```bash
mix deps.get
mix test test/jidoka/projection_test.exs
mix test test/jidoka/golden/
mix test test/jidoka/inspection_test.exs
```

## Quick Example

Projection is invoked through `Jidoka.project/1`. The result is a map (or a
list of maps) suitable for assertions, JSON encoding, and UI rendering:

```elixir
spec = Jidoka.agent!(id: "demo", model: %{provider: :test, id: "m"})

Jidoka.project(spec)
#=> %{
#     id: "demo",
#     model: "test:m",
#     instructions: "...",
#     context_schema?: false,
#     result: nil,
#     memory: nil,
#     operations: [],
#     controls: %{max_turns: nil, timeout_ms: nil, inputs: [], outputs: [], operations: [], metadata: %{}},
#     runtime_defaults: %{},
#     metadata: %{...}
#   }
```

Compare that with `Jidoka.inspect(spec)`, which adds derived views (kind,
module name when known, the plan, the timeline, the journal):

```elixir
Jidoka.inspect(spec)
#=> %{kind: :agent, module: nil, spec: %{...}, plan: %{...}}
```

Both functions are pure; both are golden-tested.

## Concepts

Three ideas explain the projection contract.

1. **`project/1` is the machine-readable form.** It is what tests assert on,
   what trace sinks serialize, and what UIs render. Output must be plain
   Elixir data (maps, lists, strings, atoms, numbers, booleans, nil).
2. **`Jidoka.Inspection.inspect/2` is the human-readable form.** It composes
   projections into named "views" (`:agent`, `:turn`, `:turn_state`,
   `:snapshot`, `:session`, `:replay`, `:effect_journal`, `:effect_intent`,
   `:effect_result`, `:review_*`, `:memory_*`, `:eval_run`). Views always
   include a `:kind` key so consumers can dispatch.
3. **Projections shrink struct payloads on purpose.** Removing Zoi schemas,
   `LLMDB.Model` internals, Spark metadata, and unstable nested structures is
   what makes the contract stable across implementation churn.

```diagram
                  Jidoka data structs
                          │
            ╭─────────────┴────────────────╮
            ▼                              ▼
     Jidoka.project/1            Jidoka.Inspection.inspect/2
            │                              │
            ▼                              ▼
   plain data maps                    named view maps
   (lists of maps)                    (with :kind key)
            │                              │
   ╭────────┴───────╮            ╭─────────┼───────────╮
   ▼                ▼            ▼         ▼           ▼
golden tests   trace sinks   debug logs UI/CLI   Kino/Livebook
                replay         eval     widgets    cells
                consumers      runs
```

## How To

### Step 1: Read The Dispatch Table

[`Jidoka.Projection`](`Jidoka.Projection`) is one screen per supported struct.
The pattern is always the same:

```elixir
def project(%Agent.Spec{} = spec) do
  %{
    id: spec.id,
    instructions: spec.instructions,
    model: Jidoka.Config.model_ref(spec.model),
    generation: project(spec.generation),
    context_schema?: not is_nil(spec.context_schema),
    result: project(spec.result),
    memory: project(spec.memory),
    operations: Enum.map(spec.operations, &project/1),
    controls: project(spec.controls),
    runtime_defaults: project_value(spec.runtime_defaults),
    metadata: project_agent_metadata(spec.metadata)
  }
end
```

Three rules apply to every clause:

- **Composition over flattening.** A struct's nested struct fields go through
  `project/1` again; lists of structs go through `Enum.map(&project/1)`.
- **`project_value/1` is the catch-all.** Any value that does not have a
  clause is funneled through `project_value/1`, which strips known unstable
  values (Zoi schemas, `LLMDB.Model`, exceptions) and walks maps/lists
  recursively.
- **Booleans answer "is there one?"** Fields like `context_schema` and
  `result.schema` are reduced to `context_schema?` and `schema?` booleans,
  because the schema itself is opaque.

### Step 2: Strip Unstable Values With `project_value/1`

`project_value/1` is the only place where struct-aware stripping happens:

```elixir
defp project_value(%_{} = exception) when is_exception(exception), do: Error.to_map(exception)

defp project_value(%LLMDB.Model{} = model), do: Jidoka.Config.model_ref(model)

defp project_value(%module{} = struct) do
  if zoi_schema?(module) do
    %{schema?: true}
  else
    struct
    |> Map.from_struct()
    |> project_value()
  end
end

defp project_value(%{} = map) do
  Map.new(map, fn {key, value} -> {key, project_value(value)} end)
end

defp project_value(list) when is_list(list), do: Enum.map(list, &project_value/1)
defp project_value(value), do: value
```

Three behaviors to remember:

- **Exceptions become maps.** `Error.to_map/1` sanitizes credential-shaped
  values and returns a flat representation.
- **Zoi schemas become `%{schema?: true}`.** Schemas are huge nested structs
  that change shape with Zoi version bumps. The boolean is the stable form.
- **Foreign structs are deep-mapped.** A struct without a dedicated
  `project/1` clause is flattened to a plain map first, then projected
  recursively. Use this sparingly; named clauses are better.

### Step 3: Strip Author Metadata From Specs

`project_agent_metadata/1` and `project_operation_metadata/1` are
spec-specific cleaners:

```elixir
defp project_agent_metadata(metadata) when is_map(metadata) do
  metadata
  |> Map.drop(["dsl_module", :dsl_module])
  |> project_value()
end

defp project_operation_metadata(metadata) when is_map(metadata) do
  has_parameters_schema? =
    is_map(Map.get(metadata, "parameters_schema") || Map.get(metadata, :parameters_schema))

  metadata
  |> Map.drop(["parameters_schema", :parameters_schema])
  |> project_value()
  |> Map.put("parameters_schema?", has_parameters_schema?)
end
```

Two rules:

- **DSL module references are dropped.** They are runtime-bound; including
  them in golden tests pins the test to a specific module name.
- **Parameter schemas become booleans.** The full schema map is meaningful
  for Jido but noisy for golden tests; the `"parameters_schema?"` flag is
  stable.

### Step 4: Build A Named View

[`Jidoka.Inspection`](`Jidoka.Inspection`) is the second layer. It composes
projections into named views:

```elixir
defp turn_result_view(%Turn.Result{} = result) do
  %{
    kind: :turn,
    status: :finished,
    content: result.content,
    timeline: timeline(result.events),
    journal: Jidoka.project(result.journal),
    result: Jidoka.project(result)
  }
end
```

Three conventions:

- **Every view has a `:kind` key.** It is the dispatch field for consumers
  that see a mix of view types (for example, a UI widget that toggles
  between turn results and snapshots).
- **The `:timeline` field uses `Jidoka.Trace.timeline/1`.** That
  function shrinks raw events into trace-shaped maps; UIs and tests should
  prefer it over raw events.
- **The original projection is always included.** Views are additive; they
  never drop fields from `project/1`.

### Step 5: Read The Preflight Struct

[`Jidoka.Inspection.Preflight`](`Jidoka.Inspection.Preflight`) is the struct
returned by `Jidoka.preflight/3`. It is itself defined as a Zoi-backed
struct so that preflight output is also data:

```elixir
@schema Zoi.struct(
          __MODULE__,
          %{
            agent: Zoi.map(),
            plan: Zoi.map(),
            request: Zoi.map(),
            prompt: Zoi.map(),
            events: Zoi.array(Zoi.map()) |> Zoi.default([]),
            timeline: Zoi.array(Zoi.map()) |> Zoi.default([]),
            diagnostics: Zoi.array(Zoi.any()) |> Zoi.default([])
          },
          coerce: true
        )
```

Preflight is produced by `Jidoka.Inspection.preflight/3`, which resolves a
plan, normalizes a request, runs the pure
`Jidoka.Runtime.Spine.Steps.assemble_prompt/1`, and projects the resulting state.
No capability is called. The struct is the contract for "what would a turn
see?" debugging without spending a token.

### Step 6: Use The AgentView Projection

[`Jidoka.AgentView`](`Jidoka.AgentView`) is a Zoi-backed struct intended for
UI consumers. It is projection-only: no pid, no provider client, no
persistence. The struct carries `visible_messages`, `streaming_message`,
`events`, `status`, `outcome`, and a `metadata` slot that can hold an
`agent_state` reference and the last `result` projection.

`AgentView.after_turn/2` is the main reduction:

```elixir
def after_turn(%__MODULE__{} = view, {:ok, %Turn.Result{} = result}) do
  %{
    view
    | visible_messages: commit_pending(view.visible_messages) ++ [assistant_message(result.content)],
      streaming_message: nil,
      events: append_operation_events(view.events, result),
      status: :idle,
      outcome: {:ok, result},
      metadata:
        view.metadata
        |> Map.put(:agent_state, result.agent_state)
        |> Map.put(:last_result, Jidoka.project(result))
  }
end
```

Two rules contributors must keep:

- **Anything UI consumers see is a projection or a plain map.** Never expose
  a raw `Turn.Result` field directly through `AgentView`.
- **Streaming deltas update `streaming_message`; non-delta events go into
  `events`.** That separation is what lets LiveView widgets render
  incrementally without keeping the full event log in DOM.

### Step 7: Maintain Golden Coverage

Golden tests live under `test/jidoka/golden/` and pin the projection output
verbatim. The pattern is:

```elixir
assert Jidoka.project(MinimalAgent.spec()) == %{
         id: "golden_minimal_agent",
         instructions: Jidoka.Agent.default_instructions(),
         model: "test:golden-minimal-model",
         generation: %{params: %{...}, provider_options: %{}, extra: %{}},
         context_schema?: false,
         result: nil,
         memory: nil,
         operations: [],
         controls: %{...},
         runtime_defaults: %{},
         metadata: %{...}
       }
```

Any change to the projection of a struct must update the matching golden
expectations in the same commit. Skipping that step makes the test fail and
hides the real change in noise.

## Common Patterns

- **Add a `project/1` clause whenever you add a Zoi-backed struct that
  carries durable data.** Skipping the clause forces consumers into the
  catch-all `project_value/1`, which is unstable.
- **Use `Enum.reject/2` to drop nil-valued keys on small structs.** The
  pattern shows up in `OperationResult` and `RecallResult`: nil keys
  produce noisy golden output.
- **Prefer named views over ad-hoc maps.** If a struct has more than one
  consumer, add it to `Jidoka.Inspection.inspect/2` so the `:kind` dispatch
  works.
- **Always include the original projection inside a view.** A view that
  omits the underlying projection forces consumers to call `Jidoka.project/1`
  again separately.

## Change Points

- **New `project/1` clauses.** The struct must be a Zoi-backed struct or a
  plain Elixir map; functions, pids, and refs are rejected.
- **New named views.** Add a clause to `Jidoka.Inspection.inspect/2` and a
  matching private helper that returns a map with `:kind`.
- **Custom unstable value handling.** Add a clause to `project_value/1`
  before the generic `%module{} = struct` clause. Keep the new clause tight
  (one struct, one rewrite).
- **`AgentView` derivations.** UI-specific reductions belong inside
  `AgentView`. Avoid adding UI-only fields to a projected struct.

## Invariants

1. **Projections are plain Elixir data.** No structs in the output except
   inside `result.value` (which is application-defined and projected through
   `project_value/1`).
2. **`project/1` is total.** Every struct that escapes a Jidoka API call
   must have either a dedicated clause or a stable `project_value/1`
   reduction.
3. **Zoi schemas never leak.** They are reduced to `%{schema?: true}` or to
   booleans like `context_schema?`.
4. **`LLMDB.Model` becomes a string.** `Jidoka.Config.model_ref/1` produces
   `"provider:id"`. Embedding the full model struct in a projection is a
   bug.
5. **Spark DSL module references are stripped from spec metadata.** The
   `dsl_module` key is dropped so golden tests do not pin a module name.
6. **Inspection views always include `:kind`.** Consumers depend on it to
   dispatch.
7. **`Preflight` is effect-free.** Adding a clause that calls a capability
   from inside `Inspection.preflight/3` breaks the contract.
8. **`AgentView` carries no live values.** Pids, sockets, provider clients,
   and supervisor references are never assigned to AgentView fields.

## Testing

The two key surfaces are `test/jidoka/projection_test.exs` for clause
behavior and `test/jidoka/golden/` for pinned output. Golden tests are the
guardrail; project tests assert smaller properties.

```elixir
test "operation projection drops parameters_schema struct but keeps boolean" do
  operation =
    Jidoka.Agent.Spec.Operation.new!(
      name: "demo",
      description: "demo",
      idempotency: :idempotent,
      metadata: %{"parameters_schema" => %{type: "object"}}
    )

  projected = Jidoka.project(operation)

  refute Map.has_key?(projected.metadata, "parameters_schema")
  assert projected.metadata["parameters_schema?"] == true
end
```

For inspection, prefer asserting the `:kind` plus a small projection:

```elixir
test "inspect/2 of a turn result has kind :turn and content" do
  result = build_turn_result()
  view = Jidoka.inspect(result)
  assert view.kind == :turn
  assert view.content == result.content
  assert is_list(view.timeline)
end
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| Golden test fails after adding a struct field | Projection grew or shrank | Update the matching golden assertion in the same commit. |
| Projection contains `%Zoi.Types.Object{...}` | A Zoi schema escaped `project_value/1` | Add an explicit clause that reduces it to `%{schema?: true}` or a boolean. |
| Projection contains a function or pid | A runtime value leaked into struct fields | Move the value into a capability and remove it from the struct, or store an opaque id instead. |
| `Jidoka.inspect(my_struct)` returns the raw struct map | No matching clause in `Jidoka.Inspection.inspect/2` | Add a named view clause and a helper that returns `%{kind: :my_struct, ...}`. |
| `Jidoka.preflight/3` errors with `:invalid_agent_module` | Module passed is not a `Jidoka.Agent` DSL module | Pass a `Jidoka.Agent.Spec`, a `Jidoka.Turn.Plan`, or a module that exports `spec/0`. |
| AgentView shows wrong content after a turn | `after_turn/2` did not update `streaming_message` to nil | Always reset `streaming_message: nil` in `after_turn/2` clauses. |
| Trace timeline empty for a known turn | Events list passed to `Trace.timeline/1` was empty (turn errored before any event) | Use `Turn.Result.events` from a successful turn; failed turns still emit `:turn_failed`. |

## Reference

- [`Jidoka.Projection`](`Jidoka.Projection`) - dispatch table over every
  Jidoka data contract.
- [`Jidoka.Inspection`](`Jidoka.Inspection`) - named views that compose
  projections.
- [`Jidoka.Inspection.Preflight`](`Jidoka.Inspection.Preflight`) - struct
  returned by `Jidoka.preflight/3`.
- [`Jidoka.AgentView`](`Jidoka.AgentView`) - UI projection contract for
  LiveView, CLI, channels, and tests.
- [`Jidoka.Event`](`Jidoka.Event`) - source events that
  `Trace.timeline/1` projects.
- [`Jidoka.Trace`](`Jidoka.Trace`) - timeline projection
  used by inspection views.

## Related Guides

- [Inspection And Preflight](inspection-and-preflight.md) - author-facing
  surface for `Jidoka.inspect/2` and `Jidoka.preflight/3`.
- [Tracing And Events](tracing-and-events.md) - the event vocabulary
  projections rely on.
- [Runic Spine Internals](runic-spine-internals.md) - where the `Turn.State`
  fields originate.
- [Turn Runner And Effect Interpreter](turn-runner-and-effect-interpreter.md) -
  produces the events and snapshots that projections summarize.
