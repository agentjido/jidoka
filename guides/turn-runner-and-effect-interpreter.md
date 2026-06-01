# Turn Runner And Effect Interpreter

The turn runner is the small effect shell that drives one `Jidoka.Turn.Plan`
through the Runic spine and turns declared effects into real IO. The effect
interpreter is the lower half of that shell: it records every intent into the
journal, calls a runtime capability, and folds the result back into turn
state. This guide walks the loop end to end so contributors can change a phase
or add a checkpoint without breaking hibernation, replay, or controls. It is
written for people maintaining `Jidoka.Runtime.TurnRunner` and
`Jidoka.Runtime.EffectInterpreter`, not for agent authors.

## When To Use This

- Use this guide before reordering, adding, or removing a phase in
  [`Jidoka.Runtime.TurnRunner`](`Jidoka.Runtime.TurnRunner`).
- Use this guide when changing how
  [`Jidoka.Runtime.EffectInterpreter`](`Jidoka.Runtime.EffectInterpreter`)
  records intents, replays results, or decides between calling a capability
  and surfacing a review interrupt.
- Use this guide when introducing a new checkpoint policy or a new failure
  mode that should produce a snapshot rather than an error.
- Do not use this guide as a tutorial on writing agents. Authors should read
  [Getting Started](getting-started.md) and [Runtime And Harness](runtime-and-harness.md).

## Prerequisites

- Elixir `~> 1.18` and a checkout of the `jidoka` package.
- Familiarity with the pure spine described in
  [Runic Spine Internals](runic-spine-internals.md).
- A mental model of `Jidoka.Effect.Intent`, `Jidoka.Effect.Journal`, and
  `Jidoka.Turn.State`.

```bash
mix deps.get
mix test test/jidoka/runtime/effect_interpreter_test.exs
mix test test/jidoka/workflow_test.exs
```

## Quick Example

The smallest interesting view of the runner is a deterministic two-call loop:
the LLM asks for an operation, the operation answers, the LLM produces a final
content. Both capabilities are pure functions injected into
`Jidoka.Runtime.Capabilities.new/1`.

```elixir
alias Jidoka.Runtime.{Capabilities, TurnRunner}
alias Jidoka.Turn

spec =
  Jidoka.agent!(
    id: "runner_demo",
    model: %{provider: :test, id: "m"},
    operations: [%{name: "echo", description: "echo args"}]
  )

{:ok, plan} = Jidoka.plan(spec)
{:ok, request} = Turn.Request.from_input("hello")

llm = fn _intent, journal ->
  case Enum.count(journal.results, fn {_id, result} -> result.kind == :llm end) do
    0 -> {:ok, %{type: :operation, name: "echo", arguments: %{"msg" => "hi"}}}
    1 -> {:ok, %{type: :final, content: "done"}}
  end
end

ops = fn %Jidoka.Effect.Intent{payload: %{"arguments" => args}}, _journal ->
  {:ok, %{echoed: args}}
end

{:ok, capabilities} = Capabilities.new(llm: llm, operations: ops)

{:ok, %Turn.Result{content: "done"}} = TurnRunner.run(plan, request, capabilities)
```

No provider key was needed and no process was started. The runner reused the
same `Jidoka.Runtime.EffectInterpreter` path that a live ReqLLM turn uses; only
the capabilities changed.

## Concepts

Three ideas explain the runner's shape.

1. **Phase ordering is a contract, not a comment.** Each loop iteration runs
   input controls (once), Runic planning, an optional checkpoint, operation
   controls, effect interpretation, result apply, optional output controls,
   and either loops or finishes.
2. **The journal is the source of truth for replay.**
   [`Jidoka.Effect.Journal`](`Jidoka.Effect.Journal`) holds every intent and
   every result keyed by intent id. The interpreter checks the journal before
   calling a capability so resumed turns never repeat side effects.
3. **Hibernation is a runner decision.** Steps are hibernate-agnostic. The
   runner decides whether the current point in the loop is a snapshot
   boundary, based on checkpoint policy, pending interrupts, and the current
   pending effect.

```diagram
╭─────────────────────────────╮
│   TurnRunner.run/4          │ effect shell
│                             │
│  emit_turn_started          │
│  Controls.run_input_controls│ ◀── once per turn
│  enforce_timeout            │
╰─────────────┬───────────────╯
              │
              ▼
   ╭────────────────────╮
   │   run_loop         │ ◀── once per model turn
   │  (Runic workflow)  │
   ╰─────────┬──────────╯
             │
             ▼
   ╭────────────────────╮
   │ maybe_hibernate    │ ── checkpoint :after_prompt
   │ _after_prompt      │
   ╰─────────┬──────────╯
             ▼
   ╭────────────────────╮
   │ maybe_hibernate    │ ── checkpoint :before_each_effect
   │ _before_effect     │
   ╰─────────┬──────────╯
             ▼
   ╭────────────────────╮     ╭─────────────────────╮
   │ EffectInterpreter  │────▶│ run_operation       │ ── may interrupt
   │ .interpret_pending │     │ _controls           │
   ╰─────────┬──────────╯     ╰─────────────────────╯
             │
             ▼
   ╭────────────────────╮
   │ Turn.State.apply   │
   │ _effect_result     │
   ╰─────────┬──────────╯
             │
        ╭────┴────╮
        ▼         ▼
   :running   :finished
        │         │
        │         ▼
        │  output controls
        │  emit turn_finished
        ▼  Turn.Result.from_turn_state!
   loop_index + 1
```

Everything below grounds those three ideas in the actual functions in
[`Jidoka.Runtime.TurnRunner`](`Jidoka.Runtime.TurnRunner`) and
[`Jidoka.Runtime.EffectInterpreter`](`Jidoka.Runtime.EffectInterpreter`).

## How To

### Step 1: Read The Run Entrypoint

`TurnRunner.run/4` is the only sanctioned entrypoint for executing a plan:

```elixir
def run(%Turn.Plan{} = plan, %Turn.Request{} = request, %Capabilities{} = capabilities, opts \\ []) do
  result =
    with :ok <- Agent.Spec.validate_operation_policies(plan.spec),
         state <-
           Turn.State.new!(
             spec: plan.spec,
             plan: plan,
             request: request,
             agent_state: request.agent_state,
             memory: Keyword.get(opts, :memory),
             started_at_ms: clock_ms(opts)
           ),
         :ok <- emit_turn_started(state, opts),
         {:ok, state} <- run_and_emit(state, opts, &Controls.run_input_controls/1),
         :ok <- enforce_timeout(state, opts) do
      run_loop(state, capabilities, opts)
    end

  maybe_emit_turn_failed(result, plan, request, opts)
end
```

Three properties matter to contributors:

- **Operation policies are validated up front.** A spec with an
  `:unsafe_once` operation without an operation control fails before any IO.
- **Input controls run exactly once** at the start, not once per loop
  iteration.
- **`started_at_ms` is recorded once.** `enforce_timeout/2` compares against
  this anchor at every phase boundary.

### Step 2: Walk One Loop Iteration

`run_loop/3` enforces the timeout, checks `max_model_turns`, compiles the
Runic workflow for the plan, drives it through Runic to completion, then hands
the planned state to the hibernation gate:

```elixir
defp run_loop(%Turn.State{loop_index: loop_index, plan: plan} = state, capabilities, opts) do
  with :ok <- enforce_timeout(state, opts) do
    if loop_index >= plan.max_model_turns do
      {:error, {:max_model_turns_exceeded, plan.max_model_turns}}
    else
      workflow = Compiler.model_turn_workflow(plan)

      planned_state =
        workflow
        |> Workflow.react_until_satisfied(state)
        |> latest_state(:plan_model_effect)

      emit_new_events(state, planned_state, opts)
      maybe_hibernate_after_prompt(planned_state, capabilities, opts)
    end
  end
end
```

Three contracts matter:

- **The Runic graph is rebuilt per iteration.** It is cheap data, not a
  process. Reusing it across iterations would require careful state reset.
- **`react_until_satisfied/2` is treated as opaque.** The runner reads only
  the last `%Turn.State{}` produced by the named step `:plan_model_effect`.
- **Events emitted by steps are flushed immediately.** `emit_new_events/3`
  diffs the event list between the pre-Runic and post-Runic states so trace
  sinks see new events as they happen.

### Step 3: Decide Between Hibernate, Continue, And Error

The runner has two checkpoint gates after the workflow:

```elixir
defp maybe_hibernate_after_prompt(state, capabilities, opts) do
  case checkpoint_policy(opts) do
    :after_prompt -> hibernate(state, Turn.Cursor.after_prompt(), opts)
    :after_each_phase -> hibernate(state, Turn.Cursor.after_prompt(), opts)
    _policy -> maybe_hibernate_before_effect(state, capabilities, opts)
  end
end

defp maybe_hibernate_before_effect(%Turn.State{} = state, capabilities, opts) do
  with :ok <- enforce_timeout(state, opts) do
    case {Turn.State.current_pending_effect(state), checkpoint_policy(opts)} do
      {nil, _policy} ->
        continue_after_pending_effect(state, capabilities, opts)

      {%Effect.Intent{} = effect, policy} when policy in [:before_each_effect, :after_each_phase] ->
        hibernate(state, Turn.Cursor.before_effect(effect), opts)

      {%Effect.Intent{}, _policy} ->
        continue_after_pending_effect(state, capabilities, opts)
    end
  end
end
```

The decision tree is intentionally narrow:

```diagram
                checkpoint policy?
                       │
        ╭──────────────┼──────────────╮
        ▼              ▼              ▼
  :after_prompt   :before_each   :after_each_phase
        │         _effect              │
        │              │               │
        ▼              ▼               ▼
   hibernate      hibernate        hibernate
                       │
                       ▼
                  (call capability)
        │
        ▼
    :none         continue → interpret_pending
```

A new policy must be added in `checkpoint_policy/1` and both `maybe_hibernate_*`
clauses. Anything else is treated as `:none`.

### Step 4: Read The Effect Interpreter

`EffectInterpreter.interpret_pending/3` is the lower half of the shell. It
inspects the journal first, only calls the capability for unseen intents,
and routes operation controls through `interpret_after_controls/5`:

```elixir
def interpret_pending(%Turn.State{} = state, %Capabilities{} = capabilities, opts) do
  case Turn.State.current_pending_effect(state) do
    %Effect.Intent{} = intent -> interpret_intent(state, intent, capabilities, opts)
    nil -> {:error, Error.normalize(:missing_pending_effect, ...)}
  end
end

defp interpret_intent(state, %Effect.Intent{} = intent, capabilities, opts) do
  case Effect.Journal.result_for(state.journal, intent) do
    %Effect.Result{} = result ->
      {:ok, result, append_effect_trace(state, intent, :effect_replayed, [], opts)}

    nil ->
      with :ok <- validate_incomplete_effect_replay(state, intent) do
        journal = Effect.Journal.put_intent(state.journal, intent)
        state = %Turn.State{state | journal: journal}
        state = append_effect_trace(state, intent, :effect_started, [], opts)
        interpret_after_controls(state, intent, capabilities, journal, opts)
      end
  end
end
```

Three properties are load-bearing:

- **`Effect.Journal.result_for/2` is the replay gate.** If the journal already
  has a result for this intent, the capability is never called again, no
  matter what the policy is.
- **`validate_incomplete_effect_replay/2` is the `:unsafe_once` safety
  rail.** When an `:unsafe_once` intent was recorded but never completed (for
  example, the process crashed between `put_intent` and `put_result`), the
  interpreter refuses to resume unless the intent carries an
  `approved_interrupt_id` metadata key set by an approved review response.
- **The intent is written into the journal _before_ the capability is
  called.** That guarantees a crash mid-call still leaves a recoverable trace.

### Step 5: Walk The Operation Control Branch

Operation controls only run for `:operation` effects. They can interrupt the
turn, in which case the runner snapshots and returns to the caller:

```elixir
defp run_effect_controls(%Turn.State{} = state, %Effect.Intent{kind: :operation} = intent, opts) do
  event_count = length(state.events)

  case Controls.run_operation_controls(state, intent) do
    {:ok, %Turn.State{} = state} ->
      emit_events(Enum.drop(state.events, event_count), opts)
      {:ok, state}

    {:interrupt, %Interrupt{} = interrupt, %Turn.State{} = state} ->
      emit_events(Enum.drop(state.events, event_count), opts)
      {:interrupt, interrupt, state}

    {:error, reason} ->
      {:error, Error.normalize(reason, operation: effect_operation(intent), ...)}
  end
end
```

When the interpreter returns `{:interrupt, ...}`, the runner converts it to a
hibernation snapshot through `hibernate_for_interrupt/3`. The interrupt is
recorded on `Turn.State.pending_interrupt`, an `:approval_requested` event is
appended, and the snapshot uses `Turn.Cursor.review(interrupt)` as the cursor.

### Step 6: Resume A Hibernated Turn

`TurnRunner.resume/3` is the symmetric entrypoint. It loads `Turn.State` from
the snapshot and then branches on whether the state is awaiting approval:

```elixir
def resume(%AgentSnapshot{} = snapshot, %Capabilities{} = capabilities, opts \\ []) do
  with {:ok, state} <- Turn.State.from_snapshot(snapshot) do
    state
    |> ensure_started_at(opts)
    |> resume_from_snapshot(snapshot, capabilities, opts)
  end
end

defp resume_from_snapshot(%Turn.State{status: :waiting, pending_interrupt: %Interrupt{}} = state, snapshot, capabilities, opts) do
  case Review.approval_response(opts) do
    :missing -> {:hibernate, snapshot}
    {:ok, %Review.Response{} = response} -> resume_with_approval_response(state, ..., response, capabilities, opts)
    {:error, reason} -> {:error, reason}
  end
end
```

The hibernate-vs-error decision tree at resume:

```diagram
        Turn.State status?
                │
        ╭───────┼─────────────╮
        ▼                     ▼
    :waiting              other status
   pending_interrupt          │
        │                     ▼
        ▼              continue_after_pending_effect
  approval response?          (re-interpret current intent)
        │
   ╭────┼──────────┬────────────╮
   ▼    ▼          ▼            ▼
:missing  invalid  denied/      approved
   │      response expired      │
   ▼      ▼        ▼            ▼
hibernate {:error} {:error}  apply response,
(noop)                       continue loop
```

`:missing` is the no-op path: a caller that resumes without supplying an
`:approval` option gets the same snapshot back. That is how external review
UIs poll without consuming the snapshot.

### Step 7: Handle Failures Without Losing Trace Events

Every error path passes through `maybe_emit_turn_failed/4` so a `:turn_failed`
event with `data.reason` is emitted before the caller sees the error tuple:

```elixir
defp maybe_emit_turn_failed({:error, reason} = result, %Turn.Plan{} = plan, request, opts) do
  Event.build(:turn_failed, [],
    agent_id: plan.spec.id,
    request_id: request.request_id,
    data: %{reason: inspect(reason)}
  )
  |> EventStream.emit(opts)

  result
end
```

This is the only place that emits `:turn_failed`. Any new error branch must
flow through this helper, or trace consumers will not see the failure.

## Common Patterns

- **Always use `Turn.State.apply_effect_result/2` to fold capability output.**
  It updates `pending_effects`, `agent_state`, `result`, and `status` together.
  Mutating one field in isolation is a bug.
- **Emit events incrementally.** Use `run_and_emit/3` or compare event counts
  before and after a step; never re-emit the full `state.events` list.
- **Keep all clock reads in `clock_ms/1`.** Tests inject `:clock` to make
  `started_at_ms`, `responded_at_ms`, and `expires_at_ms` deterministic.
- **Treat the Runic workflow as the only producer of `pending_effects`.**
  Hand-crafting an intent in the runner outside of `:plan_model_effect`
  breaks deterministic test runs and the spine guarantees.

## Change Points

- **Checkpoint policies.** The runner reads `:checkpoint` from `opts`. New
  policies must be added in `checkpoint_policy/1` and both `maybe_hibernate_*`
  functions. Snapshot identity is supplied through `snapshot_opts/1`.
- **Capability normalization.** The runner accepts whatever
  `Jidoka.Runtime.Capabilities.new/1` produces. New effect kinds (a third
  capability slot) require adding a clause in
  `EffectInterpreter.call_capability/3` and a field in `Capabilities`.
- **Approval providers.** `Jidoka.Runtime.Review.approval_response/1` controls
  how an approval is sourced from `opts`. Wrapping it with a custom adapter
  (for example, a database-backed approval queue) is the supported way to
  integrate review UIs.
- **Operation controls.** New control behaviour returning
  `{:interrupt, %Interrupt{}, state}` participates automatically; no runner
  change is required.

## Invariants

Contributors must preserve every rule below. The rest of the runtime relies
on them.

1. **Intent before IO.** `Effect.Journal.put_intent/2` must run before
   `call_capability/3`. Reversing the order makes crash recovery unsafe.
2. **Replay is content-addressed by intent id.** The journal lookup in
   `Effect.Journal.result_for/2` is the only authority on "have we seen this
   effect?". No phase may compare intents structurally.
3. **`:unsafe_once` requires explicit consent on replay.**
   `validate_incomplete_effect_replay/2` must reject replays of incomplete
   unsafe intents unless an approval response patched the intent metadata.
4. **`pending_interrupt` is set only by the runner.** Steps and capabilities
   must not write to that field directly; they signal an interrupt by returning
   from a control.
5. **`:turn_failed` is emitted exactly once per failed turn.**
   `maybe_emit_turn_failed/4` is the only producer.
6. **`Turn.Result.from_turn_state!/1` is the only constructor for a finished
   result.** The runner must not synthesize a `Turn.Result` from partial state.
7. **Resume never bypasses controls.** Approved intents continue through
   `interpret_after_controls/5` so operation controls still see the (now
   approved) intent.
8. **Snapshots are taken from a committed state.** `hibernate/3` appends
   `:turn_hibernated` to the state before serializing, so the snapshot already
   contains the hibernation event.

## Testing

Two patterns cover most contributor changes to the runner and interpreter:
deterministic loop tests and journal-replay tests.

```elixir
test "interpreter records intent and replays journal on second call" do
  alias Jidoka.Effect
  alias Jidoka.Runtime.{Capabilities, EffectInterpreter}
  alias Jidoka.Turn

  spec = Jidoka.agent!(id: "interp", model: %{provider: :test, id: "m"})
  {:ok, plan} = Jidoka.plan(spec)
  {:ok, request} = Turn.Request.from_input("hi")

  state =
    Turn.State.new!(
      spec: plan.spec,
      plan: plan,
      request: request,
      agent_state: request.agent_state,
      pending_effects: [Effect.Intent.new(:llm, %{prompt: %{}})]
    )

  llm = fn _intent, _journal -> {:ok, %{type: :final, content: "ok"}} end
  {:ok, capabilities} = Capabilities.new(llm: llm, operations: fn _i, _j -> {:error, :unused} end)

  {:ok, %Effect.Result{status: :ok}, state} =
    EffectInterpreter.interpret_pending(state, capabilities)

  # second call replays from journal; capability is never called again.
  {:ok, %Effect.Result{status: :ok}, _state} =
    EffectInterpreter.interpret_pending(state, capabilities)
end
```

For runner-level tests, prefer `Jidoka.Runtime.TurnRunner.run/4` with the
the helpers in `test/support/test_support.ex`. Use
`Jidoka.Trace.timeline/1` over raw events so trace ordering changes
do not break unrelated assertions.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, :missing_pending_effect}` from the interpreter | A step did not append an `Effect.Intent` to `pending_effects` | Ensure the Runic graph ends at `:plan_model_effect` and returns a state with a pending intent. |
| `{:error, {:max_model_turns_exceeded, n}}` | The loop ran past `plan.max_model_turns` without producing `:final` | Tighten the prompt or raise `max_turns` in the agent's `controls`. |
| `{:error, {:turn_timeout_exceeded, ms, elapsed}}` | A capability blocked past `plan.timeout_ms` | Lower capability latency or raise `timeout_ms` in `controls`. |
| Capability is called twice for the same intent | Code path bypassed `Effect.Journal.result_for/2` | Route the new path through `EffectInterpreter.interpret_pending/3`. |
| Resume immediately returns the same snapshot | `:approval` not supplied to `Jidoka.resume/2` | Pass `approval: %Jidoka.Review.Response{...}` (or `approval_response:`). |
| `:turn_failed` event missing in trace | Error returned outside `maybe_emit_turn_failed/4` | Route the error tuple through the helper before returning it. |
| Snapshot deserialization fails after a code change | A new field on `Turn.State` is not portable | Use `Jidoka.Runtime.AgentSnapshot.serialize/1` in tests; the portable validator will name the offending key. |
| Approval response rejected with `:approval_interrupt_mismatch` | Wrong `interrupt_id` on the response | Look up the latest `Interrupt.id` from `Turn.State.pending_interrupt` or the `pending_review` metadata on the snapshot. |

## Reference

- [`Jidoka.Runtime.TurnRunner`](`Jidoka.Runtime.TurnRunner`) - phase loop,
  checkpoints, timeout enforcement, resume.
- [`Jidoka.Runtime.EffectInterpreter`](`Jidoka.Runtime.EffectInterpreter`) -
  journal-aware capability dispatch.
- [`Jidoka.Runtime.Capabilities`](`Jidoka.Runtime.Capabilities`) - typed
  capability bundle the runner consumes.
- [`Jidoka.Runtime.Controls`](`Jidoka.Runtime.Controls`) - control runtime
  used at input, operation, and output boundaries.
- [`Jidoka.Runtime.Review`](`Jidoka.Runtime.Review`) - approval validation and
  application during resume.
- [`Jidoka.Effect.Journal`](`Jidoka.Effect.Journal`) - append-only intent/result
  store keyed by intent id.
- [`Jidoka.Turn.State`](`Jidoka.Turn.State`) - per-turn accumulator the runner
  threads through every phase.
- [`Jidoka.Turn.Cursor`](`Jidoka.Turn.Cursor`) - cursor values used at
  hibernation points.

## Related Guides

- [Runic Spine Internals](runic-spine-internals.md) - pure workflow steps the
  runner drives.
- [Runtime Capabilities Internals](runtime-capabilities-internals.md) - how
  `Capabilities`, ReqLLM, and operation adapters fit together.
- [Projection Internals](projection-internals.md) - the stable shapes the
  runner's events and snapshots expose to consumers.
- [Troubleshooting](troubleshooting.md) - error categories that map back to
  the runner and interpreter.
