# Runic Spine Internals

Jidoka owns the ReAct-style agent loop in its own Runic workflow rather than
delegating it to `Jido.AI.ReAct`. This guide explains why the spine lives in
Jidoka, how `Jidoka.Workflow.Compiler` and `Jidoka.Workflow.Steps` carve the
turn into pure phases, and what contributors must preserve when adding new
steps. It is written for people maintaining the Jidoka runtime, not for agent
authors.

## When To Use This

- Use this guide when you are about to add, reorder, or rewrite a workflow
  step in [`Jidoka.Workflow.Steps`](`Jidoka.Workflow.Steps`) or change how
  [`Jidoka.Workflow.Compiler`](`Jidoka.Workflow.Compiler`) wires steps together.
- Use this guide before introducing any new "framework" that wraps the turn
  loop; the answer is usually to add a narrowly scoped workflow step, not to
  replace the spine.
- Do not use this guide as a tutorial on writing agents. Authors should read
  [Getting Started](getting-started.md) and [Agent DSL](agent-dsl.md).

## Prerequisites

- Elixir `~> 1.18` and a checkout of the `jidoka` package.
- Familiarity with [Runic](https://hexdocs.pm/runic) `Workflow` and `step`.
- A mental model of the public turn API: `Jidoka.turn/3`,
  `Jidoka.Harness.run_turn/3`, and `Jidoka.Runtime.TurnRunner.run/4`.

```bash
mix deps.get
mix test test/jidoka/workflow_test.exs
```

## Quick Example

The smallest interesting view of the spine is the model-turn workflow itself.
Reading it is the fastest way to see that the Runic graph stays tiny on
purpose:

```elixir
alias Jidoka.Turn
alias Jidoka.Workflow.Compiler
alias Runic.Workflow

spec = Jidoka.agent!(id: "spine_demo", model: %{provider: :test, id: "m"})
{:ok, plan} = Jidoka.plan(spec)

workflow = Compiler.model_turn_workflow(plan)

state =
  Turn.State.new!(
    spec: plan.spec,
    plan: plan,
    request: Turn.Request.new!(input: "hi"),
    agent_state: Jidoka.Agent.State.new!()
  )

workflow
|> Workflow.react_until_satisfied(state)
|> Workflow.raw_productions(:plan_model_effect)
|> List.last()
|> Map.fetch!(:pending_effects)
#=> [%Jidoka.Effect.Intent{kind: :llm, ...}]
```

The compiled Runic workflow has exactly two steps:
`:assemble_prompt -> :plan_model_effect`. Both run as pure functions over
`Jidoka.Turn.State`. Nothing in the workflow calls a provider, opens a socket,
or touches a process.

## Concepts

Three ideas explain why the spine looks the way it does.

1. **Jidoka owns the loop, not `Jido.AI.ReAct`.** V1 leaned on `Jido.AI.ReAct`
   to drive turns. Jidoka deliberately reverses that by exposing a stable
   `Turn.Plan` contract and runs it with Runic so the loop is deterministic,
   inspectable, and free of provider-specific control flow.
2. **Functional core, effect shell.**
   [`Jidoka.Workflow.Steps`](`Jidoka.Workflow.Steps`) is pure. It returns the
   next `Turn.State` plus declared `Effect.Intent` values. The runtime shell
   ([`Jidoka.Runtime.TurnRunner`](`Jidoka.Runtime.TurnRunner`) and
   [`Jidoka.Runtime.EffectInterpreter`](`Jidoka.Runtime.EffectInterpreter`))
   is the only place that performs IO.
3. **Spec is immutable, Plan is data, Harness is the boundary.**
   `Jidoka.Agent.Spec` never changes after compilation. `Jidoka.Turn.Plan` is
   normalized executable data derived from a spec.
   [`Jidoka.Harness`](`Jidoka.Harness`) is the named seam where data meets
   capabilities.

```diagram
╭─────────────────────╮
│   Jidoka.Harness    │  effect shell (IO allowed)
│  (runtime/turn_*)   │
╰──────────┬──────────╯
           │ injects Turn.State
           ▼
╭─────────────────────╮
│ Runic workflow:     │  functional core (no IO)
│  assemble_prompt    │
│  plan_model_effect  │
╰──────────┬──────────╯
           │ returns Turn.State + Effect.Intent
           ▼
╭─────────────────────╮
│ EffectInterpreter   │  effect shell records and dispatches
╰─────────────────────╯
```

The split exists so the same Runic graph can run under tests with injected
capabilities, under live ReqLLM, under hibernation/resume, and under a Jido
`AgentServer` without any branch in the workflow itself.

## How To

### Step 1: Read The Current Spine

`Compiler.model_turn_workflow/1` is intentionally one screen of code:

```elixir
def model_turn_workflow(%Turn.Plan{} = _plan) do
  assemble_prompt = Runic.step(&Steps.assemble_prompt/1, name: :assemble_prompt)
  plan_model_effect = Runic.step(&Steps.plan_model_effect/1, name: :plan_model_effect)

  Workflow.new(name: :jidoka_v2_model_turn)
  |> Workflow.add(assemble_prompt)
  |> Workflow.add(plan_model_effect, to: :assemble_prompt)
end
```

Read both step functions in
[`Jidoka.Workflow.Steps`](`Jidoka.Workflow.Steps`) before you change anything.
The combination of `Turn.Transition.new!/1 -> event/3 -> commit/1` is the only
way new events should enter `Turn.State.events`.

### Step 2: Add A New Pure Step

Pure steps must take a single `Turn.State` argument and return a `Turn.State`.
They must not call providers, sockets, files, processes, or `:os.system_time`.

```elixir
defmodule MyExt.Steps do
  alias Jidoka.Turn

  @spec annotate_prompt(Turn.State.t()) :: Turn.State.t()
  def annotate_prompt(%Turn.State{} = state) do
    state
    |> Turn.Transition.new!()
    |> Turn.Transition.event(:prompt_assembled,
      agent_id: state.spec.id,
      request_id: state.request.request_id,
      loop_index: state.loop_index,
      data: %{annotated_by: :my_ext}
    )
    |> Turn.Transition.commit()
  end
end
```

Use existing event names from
[`Jidoka.Event`](`Jidoka.Event`) whenever the semantics match. New event names
should be added to `Jidoka.Event` so trace, replay, stream, and UI consumers
share the same vocabulary.

### Step 3: Compose The Step Through The Compiler

The compiler is the only allowed place to attach new pure steps to the spine.
Wire the step downstream of an existing named step so the data flow is
explicit:

```elixir
Workflow.new(name: :jidoka_v2_model_turn)
|> Workflow.add(assemble_prompt)
|> Workflow.add(MyExt.Steps.annotate_prompt(), to: :assemble_prompt)
|> Workflow.add(plan_model_effect, to: :annotate_prompt)
```

Never reach into `TurnRunner` to run a step out-of-band. Steps belong to the
workflow graph; the runner only consumes its productions.

### Step 4: Declare A New Effect (Not An IO Call)

When a step needs an external action, it must declare an `Effect.Intent` and
let the shell call the capability. The `plan_model_effect` step is the
canonical pattern:

```elixir
effect =
  Effect.Intent.new(:llm, payload,
    idempotency: :idempotent,
    idempotency_key: stable_key([state.spec.id, state.request.request_id,
                                 :llm, state.loop_index, state.prompt])
  )

%Turn.State{state | pending_effects: [effect]}
```

If you call a provider from inside a step, the rest of the runtime breaks:
hibernation, replay, deterministic tests, and the effect journal all depend on
intents being declared before any IO happens.

### Step 5: Verify Step Ordering

Phase ordering is not a comment, it is a contract.
[`Jidoka.Runtime.TurnRunner`](`Jidoka.Runtime.TurnRunner`) expects this order
per loop iteration:

1. `Controls.run_input_controls/1` (once, at the start of the turn).
2. The Runic workflow runs `:assemble_prompt` then `:plan_model_effect`.
3. Optional checkpoint hibernate at `Turn.Cursor.after_prompt/0`.
4. Operation controls evaluate the pending intent.
5. `EffectInterpreter.interpret_pending/3` invokes the capability.
6. `Turn.State.apply_effect_result/2` folds the result into state.
7. Either loop again (status `:running`) or run output controls and finish.

If a new step changes ordering, it must be reflected in the runner and in the
phase list on `Turn.Plan` (see `plan.phases` in
[`Jidoka.Projection`](`Jidoka.Projection`)).

## Common Patterns

- **Append events through `Turn.Transition`.** Mutating
  `state.events` directly bypasses the seq numbering and the event defaults.
- **Use `Jidoka.project/1` inside events.** Event `data:` should carry
  projections, not raw structs. That keeps trace sinks and snapshots
  serializable.
- **Keep the prompt assembly deterministic.** `assemble_prompt/1` already
  encodes operations, memory, and result contract into a stable map. New
  contributions should be merged into that map rather than threading new
  fields through state.
- **Reuse `stable_key/1` style hashing for idempotency.** Idempotency keys
  should be derived from inputs, not generated with random ids.

## Change Points

- **Workflow steps.** New runtime phases belong in
  `Jidoka.Workflow.Steps` and must keep the same single-argument
  `Turn.State -> Turn.State` shape used by built-in steps.
- **Event vocabulary.** New event names belong in `Jidoka.Event` so trace and
  replay consumers remain stable.
- **Spec changes.** New agent definition fields belong in
  `Jidoka.Agent.Spec` and must stay serializable data.

## Invariants

Contributors must preserve every rule below. They are the load-bearing
assumptions the rest of the runtime relies on.

1. **`Agent.Spec` is immutable.** Once produced from the DSL, an import, or
   `Jidoka.agent!/1`, the struct must not be patched in place. Build a new
   spec value when the definition changes.
2. **`Turn.Plan` is pure data.** It contains no pids, sockets, functions, or
   credentials. `Jidoka.Runtime.AgentSnapshot.serialize/1` enforces this
   property at the snapshot boundary; new plan fields must round-trip through
   `:erlang.term_to_binary/1`.
3. **Steps are pure.** No process dictionary writes, no `send/2`, no
   `:os.system_time`. Time comes through the runner's `:clock` option.
4. **Steps never call capabilities.** They only declare
   `Effect.Intent` values. Any IO from inside a step is a bug.
5. **The Runic workflow does not own checkpointing.** Hibernation is the
   runner's responsibility (`maybe_hibernate_after_prompt/3` and
   `maybe_hibernate_before_effect/3`). Steps must remain hibernate-agnostic.
6. **`Turn.State.events` only grows.** Events are appended with monotonically
   increasing `seq`. No step should drop or reorder events.
7. **Phase ordering is stable.** The phase list in `Turn.Plan.phases` is part
   of the public projection. Reordering steps requires updating `phases` and
   the runner together.

## Testing

The two ways to test the spine without a provider are running the workflow
directly and running the harness with injected capabilities.

```elixir
test "spine produces an llm intent after one pass" do
  alias Jidoka.Turn
  alias Jidoka.Workflow.Compiler
  alias Runic.Workflow

  spec = Jidoka.agent!(id: "spine_test", model: %{provider: :test, id: "m"})
  {:ok, plan} = Jidoka.plan(spec)

  state =
    Turn.State.new!(
      spec: plan.spec,
      plan: plan,
      request: Turn.Request.new!(input: "hi"),
      agent_state: Jidoka.Agent.State.new!()
    )

  productions =
    Compiler.model_turn_workflow(plan)
    |> Workflow.react_until_satisfied(state)
    |> Workflow.raw_productions(:plan_model_effect)

  assert [%Turn.State{pending_effects: [intent]} | _] = Enum.reverse(productions)
  assert intent.kind == :llm
end
```

When a step adds new events, assert against
`Jidoka.Trace.timeline/1` rather than raw structs so the test stays
stable across event metadata churn.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| Step output is dropped between iterations | Step returned something other than `%Turn.State{}` | Always return `Turn.Transition.commit/1` or the original state. |
| Snapshot serialization fails with `:non_serializable_snapshot_value` | A step stuffed a function, pid, or socket into state | Move the value into a runtime capability and reference it by id. |
| New step never runs | Not wired through `Workflow.add(step, to: :predecessor)` | Add the step in `Jidoka.Workflow.Compiler.model_turn_workflow/1`. |
| Events appear out of order in traces | Direct `state.events` mutation | Use `Turn.Transition.event/3 -> commit/1`. |
| Tests pass locally but live LLM fails | A pure step assumed provider behavior | Move the assumption into the capability or the ReqLLM adapter. |

## Reference

- [`Jidoka.Workflow.Compiler`](`Jidoka.Workflow.Compiler`) - builds the Runic
  workflow used by the runner.
- [`Jidoka.Workflow.Steps`](`Jidoka.Workflow.Steps`) - pure phase functions
  (`assemble_prompt/1`, `plan_model_effect/1`).
- [`Jidoka.Runtime.TurnRunner`](`Jidoka.Runtime.TurnRunner`) - effect shell
  that runs the workflow and interprets intents.
- [`Jidoka.Turn.Plan`](`Jidoka.Turn.Plan`) - executable data compiled from a
  spec; carries `phases`, `max_model_turns`, `timeout_ms`.
- [`Jidoka.Turn.State`](`Jidoka.Turn.State`) - mutable-per-turn accumulator
  used by steps.
- [`Jidoka.Turn.Transition`](`Jidoka.Turn.Transition`) - the only sanctioned
  way to append events from a step.
- [`Jidoka.Effect.Intent`](`Jidoka.Effect.Intent`) - the declared effect
  contract steps use to ask the shell for IO.

## Related Guides

- [Turn Runner And Effect Interpreter](turn-runner-and-effect-interpreter.md) -
  the shell that drives this spine.
- [Runtime Capabilities Internals](runtime-capabilities-internals.md) - how
  intents become provider and operation calls.
- [Projection Internals](projection-internals.md) - stable shapes that depend
  on the spine's event vocabulary.
