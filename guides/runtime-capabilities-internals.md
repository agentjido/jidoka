# Runtime Capabilities Internals

`Jidoka.Runtime.Capabilities` is the typed bundle that the turn runner consumes
when interpreting effects. Every other runtime adapter (ReqLLM, Jido actions,
local operations, controls, review, agent snapshots, signals) feeds data
through this bundle or the structures the bundle references. This guide walks
the capability normalization path, the adapter shapes, and the process-hosting
state that backs `Jido.AgentServer`. It is written for people maintaining the
adapters under `lib/jidoka/runtime/`, not for agent authors.

## When To Use This

- Use this guide when adding a new capability slot, a new effect kind, or a
  new adapter (memory store, vector store, MCP client) that participates in
  the effect shell.
- Use this guide when changing how
  [`Jidoka.Runtime.ReqLLM`](`Jidoka.Runtime.ReqLLM`) parses provider output or
  when adjusting the JSON decision protocol.
- Use this guide when touching the `:jidoka` slot inside the Jido agent
  state via [`Jidoka.Runtime.AgentServerState`](`Jidoka.Runtime.AgentServerState`).
- Do not use this guide as a tutorial on writing agents. Authors should read
  [Tools And Operations](tools-and-operations.md) and
  [Live LLM Tool Loop](live-llm-tool-loop.md).

## Prerequisites

- Elixir `~> 1.18` and a checkout of the `jidoka` package.
- A working mental model of `Jidoka.Effect.Intent`, `Jidoka.Effect.Journal`,
  and `Jidoka.Effect.LLMDecision`.
- Familiarity with how the runner consumes capabilities (see
  [Turn Runner And Effect Interpreter](turn-runner-and-effect-interpreter.md)).

```bash
mix deps.get
mix test test/jidoka/runtime/capabilities_test.exs
mix test test/jidoka/runtime/req_llm_test.exs
mix test test/jidoka/runtime/jido_actions_test.exs
mix test test/jidoka/runtime/local_operations_test.exs
```

## Quick Example

Capabilities are normalized from keyword options, never from raw maps with
unknown keys:

```elixir
alias Jidoka.Runtime.Capabilities
alias Jidoka.Runtime.{LocalOperations, ReqLLM}

llm = ReqLLM.llm(model: "openai:gpt-4o-mini", temperature: 0.0)

operations =
  LocalOperations.operations(%{
    "local_time" => fn %{"city" => city} -> {:ok, %{city: city, time: "09:30"}} end
  })

{:ok, %Capabilities{} = caps} = Capabilities.new(llm: llm, operations: operations)
```

The bundle is two-arity functions all the way down. Tests pass anonymous
functions directly; live runs pass the adapters in `Jidoka.Runtime.ReqLLM`
and `Jidoka.Runtime.JidoActions`. The runner does not care which.

## Concepts

Three ideas explain the capabilities layer.

1. **`Capabilities` is a small, validated struct.** Both fields are
   `(Effect.Intent.t(), Effect.Journal.t() -> {:ok, term()} | {:error, term()})`.
   The struct enforces that both slots are functions of arity 2.
2. **Adapters return values; the interpreter wraps them in `Effect.Result`.**
   Adapters do not construct `Effect.Result.ok/2` or
   `Effect.Result.error/2`; the interpreter does. That keeps the failure
   normalization in one place.
3. **Hosted runtimes see capability output through the same shape.**
   Whether a turn runs via `Jidoka.turn/3`, via a Jido `AgentServer`, or via
   a `Jidoka.Session`, the `Capabilities` struct is the boundary.

```diagram
              opts (keyword/map)
                     │
                     ▼
       ╭─────────────────────────────╮
       │   Capabilities.new/1        │
       │   - validates llm: arity 2  │
       │   - defaults operations to  │
       │     missing_operations_     │
       │     capability/2            │
       ╰─────────────┬───────────────╯
                     │
                     ▼
           %Capabilities{llm, operations}
                     │
        ╭────────────┴────────────────╮
        ▼                             ▼
   Effect.Intent             Effect.Intent
   kind: :llm                kind: :operation
        │                             │
        ▼                             ▼
  Capabilities.llm.(intent,    Capabilities.operations.(intent,
                    journal)                     journal)
        │                             │
        ▼                             ▼
  {:ok, %LLMDecision{}}        {:ok, %{...}} or {:error, ...}
        │                             │
        ╰─────────────┬───────────────╯
                      ▼
             EffectInterpreter
             wraps as Effect.Result
```

The rest of this guide grounds those three ideas in each adapter.

## How To

### Step 1: Read The Capability Struct

[`Jidoka.Runtime.Capabilities`](`Jidoka.Runtime.Capabilities`) is intentionally
tiny:

```elixir
@schema Zoi.struct(
          __MODULE__,
          %{
            llm: Zoi.function(arity: 2),
            operations: Zoi.function(arity: 2)
          },
          coerce: true
        )

def new(opts) do
  opts
  |> Schema.normalize_attrs()
  |> Schema.put_default(:operations, &missing_operations_capability/2)
  |> then(&Schema.parse(@schema, &1))
end

defp missing_operations_capability(_intent, _journal),
  do: {:error, :missing_operations_capability}
```

Two properties are load-bearing:

- **`llm` has no default.** A turn that interprets an `:llm` intent without a
  user-supplied LLM capability fails closed at `Capabilities.new/1`, not
  inside the interpreter.
- **`operations` defaults to a closed adapter.** An agent without operations
  still gets a function in the struct; calling it returns
  `{:error, :missing_operations_capability}` which the interpreter normalizes
  into a structured error.

### Step 2: Implement An LLM Capability (ReqLLM Adapter Shape)

The reference LLM adapter is [`Jidoka.Runtime.ReqLLM`](`Jidoka.Runtime.ReqLLM`).
Its public entrypoint is `llm/1`, which returns the two-arity function the
runner expects:

```elixir
def llm(opts \\ []) when is_list(opts) do
  fn %Effect.Intent{} = intent, %Effect.Journal{} = journal ->
    generate(intent, journal, opts)
  end
end
```

`generate/3` is the workhorse:

1. Reads `payload.prompt` and `payload.generation` from the intent.
2. Resolves the model spec through `Jidoka.Config.normalize_model_spec/1`.
3. Calls `ReqLLM.Generation.generate_text/3` (or `stream_text/3`).
4. Extracts the text and pipes it through
   [`Jidoka.Runtime.ReqLLM.Decision.parse_text/1`](`Jidoka.Runtime.ReqLLM.Decision`).
5. Returns `{:ok, %Effect.LLMDecision{}}` or `{:error, term}`.

`Decision.parse_text/1` is the JSON parsing surface. It accepts:

- A JSON object with `"type": "final"` and `"content"`.
- A JSON object with `"type": "operation"`, `"tool_call"`, `"function_call"`,
  or shorthand fields like `"name"` + `"arguments"`.
- Markdown-fenced JSON (`` ```json ... ``` ``).
- Plain text, which is treated as `LLMDecision.final/1` content.

That parsing surface is the contract a custom LLM adapter must satisfy if it
wants to share Jidoka's runtime system prompt. A native function-calling
adapter could skip parsing and return `Effect.LLMDecision.operation/2`
directly.

### Step 3: Implement An Operation Capability (JidoActions And LocalOperations)

[`Jidoka.Runtime.JidoActions`](`Jidoka.Runtime.JidoActions`) is the canonical
operation adapter. It converts a list of `Jido.Action` modules into a function
that dispatches by operation name:

```elixir
def operations(actions, opts \\ []) when is_list(actions) do
  context = Keyword.get(opts, :context, %{})

  tools = Map.new(actions, fn action ->
    tool = action.to_tool()
    {tool.name, tool}
  end)

  fn
    %Effect.Intent{kind: :operation, payload: payload}, %Effect.Journal{} ->
      with {:ok, request} <- Effect.OperationRequest.from_input(payload),
           {:ok, tool} <- fetch_tool(tools, request.name) do
        call_tool(tool, request.arguments, context)
      end

    %Effect.Intent{kind: kind}, _journal ->
      {:error, {:unsupported_effect_kind, kind}}
  end
end
```

[`Jidoka.Runtime.LocalOperations`](`Jidoka.Runtime.LocalOperations`) is the
deterministic-test counterpart. It accepts a map of `name -> handler` where
the handler is either arity-1 (called with `request.arguments`) or arity-2
(called with the full `Effect.Intent` and `Effect.Journal`):

```elixir
operations =
  Jidoka.Runtime.LocalOperations.operations(%{
    "local_time" => fn %{"city" => city} -> {:ok, %{city: city, time: "09:30"}} end
  })
```

Both adapters share three contracts:

- **Unknown operation kinds return `{:error, {:unsupported_effect_kind, kind}}`.**
- **Missing operations return `{:error, {:missing_jido_action, name}}` or
  `{:error, {:missing_operation_handler, name}}`.**
- **Successful results are unwrapped values, not `Effect.Result` structs.** The
  interpreter does the wrapping.

`Jidoka.Operation.Source.Local` is the higher-level integration that uses
`LocalOperations` under the hood. It is what application code calls when
declaring local operations on a DSL agent.

### Step 4: Wire Controls Into The Capability Path

[`Jidoka.Runtime.Controls`](`Jidoka.Runtime.Controls`) is a separate module,
not a capability. The interpreter calls it explicitly for operation intents
and uses its decisions to either proceed, interrupt, or fail:

```elixir
def run_operation_controls(%Turn.State{} = state, %Effect.Intent{} = intent) do
  Operation.run(state, intent)
end
```

Each control implementation receives an `OperationContext` map built by
`Controls.context/3`:

```elixir
%{
  type: :control,
  boundary: boundary,
  control: control.control,
  control_name: control_name(control.control),
  metadata: control.metadata,
  request_metadata: state.request.metadata,
  spec: state.spec,
  plan: state.plan,
  request: state.request,
  input: state.request.input,
  result: state.result,
  result_value: state.result_value,
  context: state.request.context,
  agent_state: state.agent_state
}
```

A new boundary (for example, a `:before_prompt` control) would extend
`Controls` with a new `run_*` function and an extra clause in the runner.
Operation controls are the only ones that may produce `:interrupt`.

### Step 5: Apply A Review Response On Resume

[`Jidoka.Runtime.Review`](`Jidoka.Runtime.Review`) bridges operation controls
and the snapshot. Three functions matter:

- `Review.approval_response/1` reads either `:approval` or
  `:approval_response` from `opts` and normalizes the value through
  `Jidoka.Review.Response.from_input/1`.
- `Review.validate_response/2` checks that `interrupt_id` matches, that the
  response is not expired against `expires_at_ms`, and that the decision is
  `:approved`. Denied or expired decisions return `{:error, ...}`.
- `Review.apply_response/3` patches the current pending intent with
  `metadata["approved_interrupt_id"]` so the interpreter's
  `validate_incomplete_effect_replay/2` lets the call proceed.

```elixir
case Review.approval_response(opts) do
  :missing -> {:hibernate, snapshot}
  {:ok, %Review.Response{} = response} -> resume_with_approval_response(...)
  {:error, reason} -> {:error, reason}
end
```

`Review.put_pending_metadata/2` is the helper that puts a `pending_review`
projection into snapshot metadata. External review UIs read that metadata to
build approval interfaces.

### Step 6: Serialize And Restore Agent Snapshots

[`Jidoka.Runtime.AgentSnapshot`](`Jidoka.Runtime.AgentSnapshot`) is the
durable form of `Turn.State` plus a cursor. Three details matter to
contributors:

- **Schema version is part of the snapshot.**
  `Jidoka.Runtime.AgentSnapshot.schema_version/0` returns `1`. Bumping it
  requires migration logic in `from_input/1`.
- **Serialize is opaque.** `serialize/1` produces a string with the prefix
  `"jidoka:snapshot:v1:"` followed by base64-encoded `:erlang.term_to_binary`.
  Callers must treat it as opaque.
- **`validate_portable/1` rejects functions, pids, ports, and references.**
  Adding any of those to `Turn.State` or `Agent.Spec` will fail
  `serialize/1` with `{:non_serializable_snapshot_value, path, type}`.

```elixir
{:ok, serialized} = Jidoka.Runtime.AgentSnapshot.serialize(snapshot)
{:ok, ^snapshot} = Jidoka.Runtime.AgentSnapshot.deserialize(serialized)
```

A new field that needs to round-trip must be plain Elixir data, a Zoi-backed
struct that flattens to plain data, or a binary.

### Step 7: Live Inside The Jido Agent Process

When a turn runs through `Jido.AgentServer`, the snapshot/result lives under
the `:jidoka` key of Jido state. [`Jidoka.Runtime.AgentServerState`](`Jidoka.Runtime.AgentServerState`)
is the typed wrapper.

```elixir
@schema Zoi.struct(__MODULE__, %{
  status: Zoi.enum([:idle, :running, :completed, :hibernated, :failed]),
  request_id: Schema.non_empty_string() |> Zoi.nullish(),
  agent_state: Zoi.lazy({Agent.State, :schema, []}),
  result: Zoi.lazy({Turn.Result, :schema, []}) |> Zoi.nullish(),
  snapshot: Zoi.lazy({AgentSnapshot, :schema, []}) |> Zoi.nullish(),
  error: Zoi.any() |> Zoi.nullish(),
  metadata: Zoi.map() |> Zoi.default(%{})
})
```

`AgentServerState.to_jido_state/1` flattens this struct into a Jido state map
that keeps the conventional top-level fields (`:status`, `:last_request_id`,
`:last_answer`, `:error`) and stores the typed payload under
`@state_key = :jidoka`. The Jido-side status mapping is intentional:

| Jidoka status | Jido status |
| --- | --- |
| `:idle` | `:idle` |
| `:running` | `:working` |
| `:completed` | `:completed` |
| `:hibernated` | `:waiting` |
| `:failed` | `:failed` |

`AgentServerState.to_run_result/1` is the inverse projection used by
`Jidoka.turn/3` when a process call returns:

- `:completed -> {:ok, result}`
- `:hibernated -> {:hibernate, snapshot}`
- `:failed -> {:error, normalized}`

### Step 8: Route Signals Into The Runtime

[`Jidoka.Runtime.Signals`](`Jidoka.Runtime.Signals`) defines the single
turn-run signal:

```elixir
@turn_run_type "jidoka.turn.run"

def turn_run(input, opts \\ []) when is_binary(input) and is_list(opts) do
  data =
    %{input: input, runtime_opts: Keyword.get(opts, :runtime_opts, [])}
    |> maybe_put(:request_id, Keyword.get(opts, :request_id))
    |> maybe_put(:context, Keyword.get(opts, :context))
    |> maybe_put(:metadata, Keyword.get(opts, :metadata))

  Jido.Signal.new!(@turn_run_type, data, source: "/jidoka")
end
```

`Jidoka.turn/3` builds this signal and sends it via
`Jido.AgentServer.call/3`. The signal is routed to
[`Jidoka.Runtime.Actions.RunTurn`](`Jidoka.Runtime.Actions.RunTurn`), which
unwraps the data, calls `agent_module.run_turn/2`, and writes the outcome back
through `AgentServerState`.

Adding a new signal type (for example, `"jidoka.session.resume"`) requires:

1. A constructor in `Jidoka.Runtime.Signals`.
2. A new action under `lib/jidoka/runtime/actions/`.
3. A route registration so the agent dispatches the signal to the action.

## Common Patterns

- **Always normalize through `Capabilities.new/1`.** Hand-building the struct
  bypasses the arity check and the default operations slot.
- **Return raw values from adapters; let the interpreter wrap.** Adapters
  that return `Effect.Result` directly will be wrapped again, producing
  `Effect.Result.ok(intent, %Effect.Result{...})`.
- **Use `Jidoka.Schema.get_key/2` for payload access.** Payloads sometimes
  have string keys (from ReqLLM JSON) and sometimes atom keys (from DSL). The
  helper accepts both.
- **Treat `Effect.Intent.metadata` as the only safe place to record runtime
  decisions.** The `approved_interrupt_id` mechanism is the canonical example;
  re-use that pattern for any "we already validated this intent" signal.

## Change Points

- **New capability kinds.** Adding a field to `Capabilities` requires updating
  the Zoi schema, adding a default for tests, and adding a
  `call_capability/3` clause in `Jidoka.Runtime.EffectInterpreter`. Steps that
  produce the new effect kind belong in
  [`Jidoka.Workflow.Steps`](`Jidoka.Workflow.Steps`).
- **New LLM adapters.** Implement the
  `(Effect.Intent.t(), Effect.Journal.t() -> {:ok, %Effect.LLMDecision{}} | {:error, term})`
  contract. Return `Effect.LLMDecision.final/2` or
  `Effect.LLMDecision.operation/2` directly when no JSON parsing is needed.
- **New operation sources.** Implement `Jidoka.Operation.Source` and reuse
  `Jidoka.Runtime.LocalOperations` for arity-1/arity-2 dispatch.
- **Approval providers.** Wrap `Jidoka.Runtime.Review.approval_response/1` by
  pre-populating `opts` with a fresh response from your queue before calling
  `Jidoka.resume/2`.

## Invariants

1. **Capabilities are two-arity functions.** Anything else fails
   `Capabilities.new/1`.
2. **Adapters never call other adapters directly.** The interpreter is the
   only orchestrator; one adapter calling another bypasses the journal.
3. **`Effect.LLMDecision` is the only sanctioned LLM output type.** Returning
   a raw map from an adapter is allowed (the interpreter accepts maps that
   match the `LLMDecision` shape) but adapters should prefer the typed
   struct.
4. **`AgentSnapshot.schema_version` is the public migration boundary.** Code
   that reads old snapshots must check `schema_version` and migrate, not
   silently coerce.
5. **`AgentServerState` keeps Jido top-level fields stable.** Renaming
   `:last_answer`, `:status`, or `:error` breaks existing Jido tooling. Add
   new fields under `:jidoka` instead.
6. **Signals carry strings, not atoms.** `runtime_opts` may include atom
   keys, but the signal `data` map itself must round-trip through JSON.
7. **Operation control context is read-only.** Controls receive a snapshot of
   `Turn.State`; they must not mutate it. Mutation happens via control
   decisions, not field assignment.

## Testing

The two ingredients of a deterministic capabilities test are an injected LLM
and an injected operations function. The helpers in
`test/support/test_support.ex` already include the common patterns:

```elixir
import TestSupport

test "operation loop completes in two LLM passes" do
  llm = operation_then_final_llm("local_time", %{"city" => "Chicago"}, "9:30 in Chicago")

  operations =
    Jidoka.Runtime.LocalOperations.operations(%{
      "local_time" => fn %{"city" => city} -> {:ok, %{city: city, time: "09:30"}} end
    })

  assert {:ok, %Jidoka.Turn.Result{content: "9:30 in Chicago"}} =
           Jidoka.turn(MyApp.TimeAgent, "What time is it in Chicago?",
             llm: llm,
             operations: operations
           )
end
```

For ReqLLM-specific tests, prefer `test/jidoka/runtime/req_llm_test.exs`
which exercises `Decision.parse_text/1` against the full set of provider
shapes (markdown-fenced JSON, OpenAI `tool_calls`, plain text fallback).

For process-hosted tests, see
`test/jidoka/jido_agent_server_test.exs`
for the round-trip through `Jidoka.Runtime.Signals.turn_run/2` and
`AgentServerState.to_run_result/1`.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, %Splode.Error{}}` mentioning `missing_operations_capability` | Agent declares operations but no `operations:` was passed to `turn/3` | Pass `operations: Jidoka.Runtime.LocalOperations.operations(...)` or `Jidoka.Runtime.JidoActions.operations(...)`. |
| `{:error, {:invalid_capability_result, other}}` | Adapter returned something other than `{:ok, _}` or `{:error, _}` | Wrap raw values in `{:ok, value}`; never return bare maps. |
| LLM call returns `{:error, :empty_llm_response}` | Provider returned empty text and no JSON | Check provider key/network; lower temperature; consider stricter prompt. |
| `{:error, {:invalid_llm_decision_type, type}}` | Model returned `"type": "something_unknown"` | Update prompt to use the runtime decision shape, or extend `Decision.parse_object/1` clauses. |
| Snapshot serialization fails with `{:non_serializable_snapshot_value, path, :function}` | A function leaked into `Turn.State` (often via metadata) | Move the function out of state into a runtime capability and reference it by id. |
| `Jido.AgentServer.call` returns `{:error, :timeout}` | Capability blocked past the `:timeout` option | Lower latency or raise `timeout:` on `Jidoka.turn/3`. |
| `to_run_result/1` returns `{:error, {:unexpected_jidoka_agent_state, _}}` | A new status was added to `AgentServerState` without a `to_run_result/1` clause | Add the corresponding clause and a `jido_status/1` mapping. |
| Operation control runs but is never observed in trace | Control event emitted before `emit_events/2` was called | Use `Controls.run_operation_controls/2` through the interpreter; do not call controls directly. |

## Reference

- [`Jidoka.Runtime.Capabilities`](`Jidoka.Runtime.Capabilities`) - typed
  capability bundle.
- [`Jidoka.Runtime.ReqLLM`](`Jidoka.Runtime.ReqLLM`) - ReqLLM-based LLM
  adapter with streaming and decision parsing.
- [`Jidoka.Runtime.ReqLLM.Decision`](`Jidoka.Runtime.ReqLLM.Decision`) - JSON
  decision parser used by the ReqLLM adapter.
- [`Jidoka.Runtime.JidoActions`](`Jidoka.Runtime.JidoActions`) - operation
  adapter for Jido actions.
- [`Jidoka.Runtime.LocalOperations`](`Jidoka.Runtime.LocalOperations`) -
  function-backed operation adapter for tests and examples.
- [`Jidoka.Runtime.Controls`](`Jidoka.Runtime.Controls`) - control runtime
  with input, operation, and output boundaries.
- [`Jidoka.Runtime.Review`](`Jidoka.Runtime.Review`) - approval normalization,
  validation, and application.
- [`Jidoka.Runtime.AgentSnapshot`](`Jidoka.Runtime.AgentSnapshot`) -
  versioned serializable snapshot.
- [`Jidoka.Runtime.AgentServerState`](`Jidoka.Runtime.AgentServerState`) -
  `:jidoka` slot inside Jido state.
- [`Jidoka.Runtime.Signals`](`Jidoka.Runtime.Signals`) - constructors for
  signals routed into the runtime.

## Related Guides

- [Turn Runner And Effect Interpreter](turn-runner-and-effect-interpreter.md) -
  the consumer of the `Capabilities` bundle.
- [Runic Spine Internals](runic-spine-internals.md) - where intents
  originate.
- [Projection Internals](projection-internals.md) - the stable shapes
  capability output ends up in.
- [Troubleshooting](troubleshooting.md) - cross-cutting failure modes that
  surface inside the capabilities path.
