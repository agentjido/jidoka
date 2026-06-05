# Turn And Effect Contracts

A Jidoka turn is a pure data pipeline. The runtime compiles a `Jidoka.Agent.Spec`
into a `Jidoka.Turn.Plan`, threads a `Jidoka.Turn.State` through Runic, and
mediates external work through `Jidoka.Effect.Intent`/`Jidoka.Effect.Result`
pairs. This guide documents every data contract on that path so that custom
harnesses, traces, and storage layers can interoperate with the runtime without
guessing.

## When To Use This

- Use this guide when you are building a custom harness, sidecar, or trace
  exporter and need the on-the-wire shape of turn state and effects.
- Use this guide when reading a snapshot or journal in tests and needing to
  decode each field.
- Do not use this guide as a runtime walkthrough. See
  [Runtime And Harness](runtime-and-harness.md) for the execution model.

## Prerequisites

- You have read [Agent Spec Contract](agent-spec-contract.md).
- You can build and run a Jidoka turn (see [Getting Started](getting-started.md)).

## Quick Example

A turn round-trip produces every contract this guide describes.

```elixir
alias Jidoka.{Agent, Turn, Effect}

spec = MyApp.TimeAgent.spec()
{:ok, plan} = Turn.Plan.new(spec)
{:ok, request} = Turn.Request.from_input("What time is it in Chicago?")

llm = fn _intent, _journal ->
  {:ok, %{type: :final, content: "Chicago time is 09:30."}}
end

{:ok, result} = MyApp.TimeAgent.run_turn(request.input, llm: llm)

result.content              #=> "Chicago time is 09:30."
result.journal              #=> %Jidoka.Effect.Journal{intents: %{...}, results: %{...}}
hd(result.events).type      #=> :turn_started (or similar)
```

`plan`, `request`, the in-flight `Turn.State`, the `Turn.Result`, and the
`Effect.Journal` are all addressable, inspectable values.

## Concepts

```diagram
╭──────────────╮     ╭───────────────╮     ╭──────────────╮
│  Agent.Spec  │────▶│   Turn.Plan   │────▶│  Turn.State  │
╰──────────────╯     ╰───────────────╯     ╰──────┬───────╯
                                                  │ pending_effects
                                                  ▼
                                          ╭───────────────╮
                                          │ Effect.Intent │
                                          ╰──────┬────────╯
                                                 │ capability
                                                 ▼
                                          ╭───────────────╮
                                          │ Effect.Result │
                                          ╰──────┬────────╯
                                                 │ journal
                                                 ▼
                                          ╭───────────────╮
                                          │ Turn.Result   │
                                          ╰───────────────╯
```

Three rules anchor the model:

1. The plan is derived from the spec; the state is derived from the plan plus a
   request.
2. The harness only ever produces effects through `Effect.Intent` and consumes
   them through `Effect.Result`. The journal records both.
3. The final `Turn.Result` is projected from the terminal `Turn.State`.

## Fields

### `Jidoka.Turn.Plan`

Compiled execution defaults for one turn.

| Field | Type | Default | Purpose |
| --- | --- | --- | --- |
| `spec` | `Agent.Spec.t()` | required | The immutable spec the plan was compiled from. |
| `workflow_profile` | `:chat \| :tool_loop \| :structured_result \| :controlled_tool_loop` | `:tool_loop` | Selects the Runic profile. |
| `max_model_turns` | positive integer | `spec.controls.max_turns` or `Jidoka.Config.default_max_model_turns/0` | Upper bound on model rounds. |
| `timeout_ms` | positive integer | `spec.controls.timeout_ms` or `Jidoka.Config.default_turn_timeout_ms/0` | Hard wall-clock limit. |
| `phases` | `[atom()]` | full phase list | Runic phase order for the turn. |
| `metadata` | map | `%{}` | Plan-level metadata. |

Built by [`Jidoka.Turn.Plan.new/1`](`Jidoka.Turn.Plan`) which also runs
`Spec.validate_operation_policies/1` before returning.

### `Jidoka.Turn.Request`

Input envelope for one turn.

| Field | Type | Default | Purpose |
| --- | --- | --- | --- |
| `input` | non-empty string | required | User-facing input passed to prompt assembly. |
| `request_id` | non-empty string | generated `"turn_…"` | Stable id used by snapshots and logs. |
| `agent_state` | `Agent.State.t()` | empty agent state | Carries history across turns. |
| `context` | map | `%{}` | Per-turn context map (validated against `spec.context_schema`). |
| `metadata` | map | `%{}` | Caller metadata. |

`Turn.Request.from_input/2` accepts a string, map, or keyword list and fills in
defaults.

### `Jidoka.Turn.State`

Ephemeral value threaded through the workflow.

| Field | Type | Purpose |
| --- | --- | --- |
| `spec` / `plan` / `request` | spec, plan, request structs | Inputs to the loop. |
| `agent_state` | `Agent.State.t()` | Mutable accumulator (messages, operation results). |
| `memory` | `Memory.RecallResult.t() \| nil` | Most recent recall. |
| `prompt` | provider-neutral prompt or `nil` | Materialized prompt after assembly. |
| `llm_result` | `Effect.LLMDecision.t() \| nil` | Last decoded LLM decision. |
| `operation_plan` | `Effect.OperationRequest.t() \| nil` | First pending operation request, kept for inspection compatibility. |
| `pending_effects` | `[Effect.Intent.t()]` | Effects awaiting interpretation. Operation batches are stored here in model order. |
| `pending_interrupt` | `Review.Interrupt.t() \| nil` | Review boundary, if any. |
| `result` / `result_value` | string / term | Final assistant content and validated structured value. |
| `result_repair_count` | non-negative integer | Repair attempts so far. |
| `status` | `:running \| :waiting \| :finished` | Loop state. |
| `loop_index` | non-negative integer | Current model round. |
| `started_at_ms` | integer or `nil` | Wall-clock start. |
| `journal` | `Effect.Journal.t()` | Recorded intents and results. |
| `events` | `[Jidoka.Event.t()]` | Append-only event log. |
| `diagnostics` | list | Append-only diagnostic blobs. |

Mutations go through [`Jidoka.Turn.Transition`](`Jidoka.Turn.Transition`).

### `Jidoka.Turn.Transition`

A pure transition value: new state plus pending events and diagnostics.

| Field | Type | Purpose |
| --- | --- | --- |
| `state` | map | The next state. |
| `events` | `[Jidoka.Event.t()]` | Events to append on commit. |
| `diagnostics` | list | Diagnostics to append on commit. |

`Transition.event/3` builds a [`Jidoka.Event`](`Jidoka.Event`) with stable
sequence ordering. `Transition.commit/1` folds events and diagnostics back into
the state.

### `Jidoka.Turn.Cursor`

A pointer to the next safe resume boundary.

| Field | Type | Default | Purpose |
| --- | --- | --- | --- |
| `phase` | `:start \| :after_prompt \| :before_effect \| :review \| :wait` | `:start` | Logical phase boundary. |
| `loop_index` | non-negative integer | `0` | Loop round at hibernation time. |
| `metadata` | map | `%{}` | Boundary metadata (e.g. `effect_id`, `interrupt_id`). |

Constructors `after_prompt/0`, `before_effect/1`, `review/1` produce the
common cursor shapes.

### `Jidoka.Turn.Result`

Final app-facing value.

| Field | Type | Purpose |
| --- | --- | --- |
| `content` | string | Final assistant text. |
| `value` | term or `nil` | Validated structured value when `spec.result` is set. |
| `agent_state` | `Agent.State.t()` | Conversation state after the turn. |
| `journal` | `Effect.Journal.t()` | Effects observed during the turn. |
| `events` | `[Jidoka.Event.t()]` | Ordered event log. |
| `usage` | map | Aggregated LLM token and cost usage for the turn. |
| `metadata` | map | Caller metadata. |

Produced by [`Jidoka.Turn.Result.from_turn_state!/1`](`Jidoka.Turn.Result`)
once `status` reaches `:finished`.

When the LLM capability is backed by ReqLLM, `usage` contains normalized token
and cost fields when the provider returns them:

```elixir
result.usage
#=> %{
#=>   llm_calls: 2,
#=>   input_tokens: 800,
#=>   output_tokens: 240,
#=>   total_tokens: 1040,
#=>   reasoning_tokens: 0,
#=>   total_cost: 0.00048
#=> }
```

Per-call usage remains available in the journal:

```elixir
result.journal.results[effect_id].metadata.usage
```

### `Jidoka.Effect.Intent`

Data description of an external effect.

| Field | Type | Purpose |
| --- | --- | --- |
| `id` | non-empty string | Stable id (`"<kind>:<idempotency_key>"`). |
| `kind` | `:llm \| :operation` | What the capability must do. |
| `payload` | map | Payload (normalized to an `Effect.OperationRequest` for `:operation`). |
| `idempotency_key` | non-empty string | Stable key (sha256 of `{kind, payload}` by default). |
| `idempotency` | `:pure \| :idempotent \| :dedupe \| :reconcile \| :unsafe_once` | Replay safety class. |
| `metadata` | map | Caller metadata. |

Build with `Effect.Intent.new/3` (kind + payload + opts) or `Intent.new/1` (full
map).

### `Jidoka.Effect.Result`

Normalized result of one interpreted effect.

| Field | Type | Purpose |
| --- | --- | --- |
| `intent_id` | non-empty string | The intent this result answers. |
| `kind` | `:llm \| :operation` | Mirrors the intent. |
| `status` | `:ok \| :error` | Interpreter outcome. |
| `output` | term | Decoded payload (LLM decision map for `:llm`; raw operation output for `:operation`). |
| `metadata` | map | Capability metadata. |

`Effect.Result.ok/2`, `Effect.Result.ok/3`, `Effect.Result.error/2`, and
`Effect.Result.error/3` are the convenience constructors. The third argument
accepts `metadata:` for capability-owned metadata such as LLM usage.

### `Jidoka.Effect.Journal`

Replay log keyed by intent id.

| Field | Type | Purpose |
| --- | --- | --- |
| `intents` | `%{String.t() => Effect.Intent.t()}` | Recorded intents. |
| `results` | `%{String.t() => Effect.Result.t()}` | Recorded results. |

Use `Journal.put_intent/2` and `Journal.put_result/2` to extend. Use
`Journal.result_for/2` to ask "has this intent already been satisfied?" - the
basis of replay safety.

### `Jidoka.Effect.OperationRequest` And `Jidoka.Effect.OperationResult`

Typed payload/observation pair for operation effects.

| `OperationRequest` field | Type | Purpose |
| --- | --- | --- |
| `name` | non-empty string | Operation name from `Spec.Operation`. |
| `arguments` | map | Arguments decoded from the LLM decision. |
| `request_id` | string or `nil` | Source turn request id. |
| `loop_index` | non-negative integer | Loop round at planning time. |
| `metadata` | map | Caller metadata. |

| `OperationResult` field | Type | Purpose |
| --- | --- | --- |
| `operation` | non-empty string | Operation name. |
| `arguments` | map | Arguments used. |
| `output` | term | Raw observation. |
| `content` | string or `nil` | Pre-rendered message content. |
| `request_id` | string or `nil` | Turn request id. |
| `loop_index` | non-negative integer | Loop round. |
| `effect_id` | string or `nil` | Originating `Effect.Intent.id`. |
| `metadata` | map | Caller metadata. |

`OperationResult.from_effect/2` is the canonical bridge from an `Intent` +
capability output to a durable observation.

### `Jidoka.Effect.LLMDecision`

Constrained JSON decision protocol returned by every LLM capability.

| Field | Type | Purpose |
| --- | --- | --- |
| `type` | `:final \| :operation \| :operations` | Branch of the decision protocol. |
| `content` | string or `nil` | Required for `:final`. Optional metadata text for operation decisions. |
| `result` | term or `nil` | Structured result for `:final` when `spec.result` is set. |
| `name` | non-empty string or `nil` | Required for `:operation`. |
| `arguments` | map | Operation arguments. Required for `:operation`. |
| `operations` | list of `OperationRequest` | Ordered operation requests for `:operations`. |
| `metadata` | map | Provider metadata. |

`LLMDecision.final/2`, `LLMDecision.operation/3`, and
`LLMDecision.operations/2` are the builder helpers. Capabilities may return
either an `LLMDecision` struct or a map that `LLMDecision.from_input/1`
accepts.

## Common Patterns

- **Treat `Effect.Intent.id` as the only identity that matters.** The journal,
  cursor metadata, and `Effect.Result.intent_id` all key off it.
- **Decide once, observe once.** An LLM decision returns either one final
  answer, one operation intent, or one ordered operation batch. Each resulting
  intent is recorded and observed once.
- **Use the cursor for resume boundaries, not the state.** A cursor is small,
  serializable, and stable across versions; the state can carry rich data.
- **Prefer `LLMDecision` structs in fake LLMs.** Returning a map works (the
  runtime calls `LLMDecision.from_input/1`), but a struct catches typos sooner.

## Testing

A deterministic test asserts on the journal, not on the prompt.

```elixir
test "operation effect is recorded once" do
  llm = fn _intent, journal ->
    case map_size(journal.results) do
      0 -> {:ok, Jidoka.Effect.LLMDecision.operation("local_time", %{"city" => "Chicago"})}
      _ -> {:ok, Jidoka.Effect.LLMDecision.final("Chicago time is 09:30.")}
    end
  end

  {:ok, result} = MyApp.TimeAgent.run_turn("What time is it in Chicago?", llm: llm)

  operation_results =
    result.journal.results
    |> Map.values()
    |> Enum.filter(&(&1.kind == :operation))

  assert length(operation_results) == 1
end
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, {:effect_result_mismatch, _, _}}` | A capability returned a result whose `intent_id` does not match the current pending intent. | Ensure capabilities pass through the `Intent` they were given and only call `Effect.Result.ok/error` against it. |
| `{:error, {:invalid_llm_decision_type, _}}` | LLM output is missing or has a non-`:final`/`:operation`/`:operations` type. | Tighten the prompt or use the deterministic LLM path. |
| `{:error, {:unknown_operation, name}}` | Decision named an operation that is not in `spec.operations`. | Add the operation or change the model's allowed tools. |
| `Turn.State.status` stays `:waiting` forever | A `pending_interrupt` was not resolved. | Resume the snapshot through the review API before continuing. |
| `Turn.Result.events` is empty | The state was committed without any `Transition.event/3` calls. | Use `Turn.Transition` instead of mutating state directly. |

## Reference

- [`Jidoka.Turn.Plan`](`Jidoka.Turn.Plan`)
- [`Jidoka.Turn.Request`](`Jidoka.Turn.Request`)
- [`Jidoka.Turn.State`](`Jidoka.Turn.State`)
- [`Jidoka.Turn.Transition`](`Jidoka.Turn.Transition`)
- [`Jidoka.Turn.Cursor`](`Jidoka.Turn.Cursor`)
- [`Jidoka.Turn.Result`](`Jidoka.Turn.Result`)
- [`Jidoka.Effect.Intent`](`Jidoka.Effect.Intent`)
- [`Jidoka.Effect.Result`](`Jidoka.Effect.Result`)
- [`Jidoka.Effect.Journal`](`Jidoka.Effect.Journal`)
- [`Jidoka.Effect.OperationRequest`](`Jidoka.Effect.OperationRequest`)
- [`Jidoka.Effect.OperationResult`](`Jidoka.Effect.OperationResult`)
- [`Jidoka.Effect.LLMDecision`](`Jidoka.Effect.LLMDecision`)
- [`Jidoka.Runtime.Capabilities`](`Jidoka.Runtime.Capabilities`)

## Related Guides

- [Agent Spec Contract](agent-spec-contract.md) - the input to the plan.
- [Operation Source Contracts](operation-source-contracts.md) - where
  operation capabilities come from.
- [Runtime And Harness](runtime-and-harness.md) - the executor of these
  contracts.
- [Import And Snapshot Contracts](import-and-snapshot-contracts.md) - durable
  shapes built on top of `Turn.State` and `Turn.Cursor`.
