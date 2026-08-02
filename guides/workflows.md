# Workflows

Use `Jidoka.Workflow` when the model should choose one business operation,
but your application owns the deterministic steps behind it. A workflow is
exposed to the agent as one tool. Inside the workflow, you can run functions,
Jidoka/Jido actions, or a bounded agent step.

## When To Use This

- Use a workflow for multi-step application logic that should look like one
  model-callable operation.
- Use a workflow when you need a typed input contract, deterministic data
  wiring, context forwarding, and a stable output shape.
- Do not use a workflow for one simple tool. Use `Jidoka.Action`.
- Do not use a workflow for open-ended orchestration. The static graph remains
  acyclic. Use an explicit bounded loop for repeated or runtime-created work.
  Use the background runner and scheduler when work must outlive the caller.

## Quick Example

Define the workflow in a module:

```elixir
defmodule MyApp.Workflows.RefundReview do
  use Jidoka.Workflow

  workflow do
    id :refund_review
    description "Reviews whether a refund can be queued."

    input Zoi.object(%{
            order_id: Zoi.string(),
            amount: Zoi.float()
          })
  end

  steps do
    function :check_policy, {__MODULE__, :check_policy, 2},
      input: %{
        order_id: input(:order_id),
        amount: input(:amount),
        tenant: context(:tenant)
      }
  end

  output from(:check_policy)

  def check_policy(%{order_id: order_id, amount: amount, tenant: tenant}, _context) do
    {:ok,
     %{
       order_id: order_id,
       tenant: tenant,
       approved: amount <= 100.0,
       summary: "Refund #{order_id} checked for #{tenant}."
     }}
  end
end
```

Expose it to an agent:

```elixir
defmodule MyApp.SupportAgent do
  use Jidoka.Agent

  agent :support_agent do
    instructions "Use refund tools before answering refund questions."
  end

  tools do
    workflow MyApp.Workflows.RefundReview,
      as: :review_refund,
      timeout: 30_000,
      async: true,
      max_concurrency: 4,
      forward_context: {:only, [:tenant]},
      result: :structured
  end
end
```

Run it directly in a test:

```elixir
{:ok, output} =
  Jidoka.Workflow.run(
    MyApp.Workflows.RefundReview,
    %{"order_id" => "A1001", "amount" => 42.50},
    context: %{tenant: "acme"},
    async: true,
    max_concurrency: 4
  )

output.approved
#=> true
```

## Concepts

There are two workflow forms.

| Form | Use it for | Runtime shape |
| --- | --- | --- |
| Callback | Existing opaque operation modules. | `use Jidoka.Workflow, id: ...` plus `run/2`. |
| DSL | Validated deterministic step graphs. | `workflow do`, `steps do`, `output`. |

Both forms compile to `Jidoka.Workflow.Spec`. Agents expose either form
through the same `tools do workflow ... end` entry.

```diagram
╭──────────────────────────────╮
│ Workflow module              │
│ workflow / steps / output    │
╰──────────────┬───────────────╯
               │ compile
               ▼
╭──────────────────────────────╮
│ Jidoka.Workflow.Spec         │
│ id, input schema, steps      │
╰──────────────┬───────────────╯
               │ tools.workflow
               ▼
╭──────────────────────────────╮
│ one Agent.Spec.Operation     │
│ metadata.source = workflow   │
╰──────────────┬───────────────╯
               │ model chooses operation
               ▼
╭──────────────────────────────╮
│ workflow runtime resolves    │
│ input/context/from refs      │
╰──────────────────────────────╯
```

The model never sees the internal step graph. It sees one operation with the
workflow input schema as tool parameters.

## Module DSL

### `workflow do`

`workflow do` defines the public contract.

```elixir
workflow do
  id :refund_review
  description "Reviews whether a refund can be queued."
  input Zoi.object(%{order_id: Zoi.string(), amount: Zoi.float()})
  metadata %{owner: :support}
end
```

Rules:

- `id` is required and must be lower snake case.
- `input` is required and must be a Zoi map/object schema.
- `description` is optional but recommended because it becomes the tool
  description unless overridden in `tools.workflow`.
- `metadata` is optional workflow-local data.

### `steps do`

`steps do` declares deterministic steps. Step names must be unique lower
snake case atoms. Steps run in stable dependency order inferred from
`from/1`, `from/2`, and `after:`.

```elixir
steps do
  function :check_policy, {MyApp.Refunds, :check_policy, 2},
    input: %{order_id: input(:order_id)}

  action :queue_refund, MyApp.Actions.QueueRefund,
    input: %{policy: from(:check_policy)}

  agent :draft_reply, MyApp.SupportWriter,
    prompt: from(:queue_refund, :summary),
    context: %{order_id: input(:order_id)}
end
```

Supported step kinds:

| Step | Target | Return handling |
| --- | --- | --- |
| `function` | `{module, function, 2}` | Calls `function.(input, workflow_context)`. Accepts raw return, `{:ok, value}`, or `{:error, reason}`. |
| `action` | Jidoka/Jido action module exposing `to_tool/0` | Runs the action through the same action tool boundary used by agents. |
| `agent` | Jidoka-compatible agent module exposing `run_turn/2` | Runs a bounded child turn and stores `Turn.Result.content`. |
| `gate` | Boolean ref or value | Stores `true` or `false` for conditional steps. |
| `map` | Function or action target | Runs a bounded fanout over a resolved list and returns ordered results. |
| `reduce` | `{module, function, 2}` | Runs one deterministic reducer over a resolved list. |
| `loop` | `{module, function, 2}` | Runs explicit state transitions under an exact iteration bound and returns a `Loop.Result`. |

Agent steps are useful for small bounded drafting or classification tasks.
They are not subagents. If you want the parent model to decide when to
delegate, use `tools do subagent ... end` instead.

Independent roots and joins form a DAG. Jidoka evaluates the graph serially by
default. Pass `async: true` to `Jidoka.Workflow.run/3` or to the agent
`tools.workflow` entry when independent steps should execute concurrently
through Runic. `max_concurrency:` caps how many workflow steps can run at once.

### Gates And Conditional Steps

Use a `gate` when later steps should run only for one path. `when:` runs a
step only when the resolved value is `true`. `unless:` skips a step when the
resolved value is `true`.

```elixir
steps do
  function :check_policy, {MyApp.Refunds, :check_policy, 2},
    input: %{order_id: input(:order_id)}

  gate :needs_review,
    condition: from(:check_policy, :requires_review)

  action :auto_refund, MyApp.Actions.AutoRefund,
    unless: from(:needs_review),
    input: %{order_id: input(:order_id)}

  action :request_review, MyApp.Actions.RequestReview,
    when: from(:needs_review),
    input: %{order_id: input(:order_id)}
end

output coalesce([maybe_from(:auto_refund), maybe_from(:request_review)])
```

Skipped steps do not write a normal output. `from(:step)` fails if the step was
skipped. Use `maybe_from(:step)` for branch outputs that may not exist.

### Map And Reduce

Use `map` for bounded fanout over a list. `item()` and `index()` are valid only
inside map input.

```elixir
steps do
  map :score_leads,
    over: input(:leads),
    function: {MyApp.Leads, :score, 2},
    input: %{lead: item(), index: index()},
    max_concurrency: 8

  reduce :rank_leads,
    over: from(:score_leads),
    using: {MyApp.Leads, :rank, 2},
    input: %{scores: items(), threshold: input(:threshold)}
end

output from(:rank_leads)
```

`map` supports `function:` and `action:` targets. Results preserve input order,
including when item work runs concurrently. A map step defaults to 8 concurrent
items. A step-level `max_concurrency:` can raise or lower that value; a workflow
runtime `max_concurrency:` option acts as a global cap when supplied.

`reduce` is one deterministic function call over the resolved list; it is not a
streaming accumulator.

### Bounded Loops And Dynamic Work

Use `loop` when the amount of work changes at runtime. The static workflow
graph stays acyclic. The loop owns a serializable state and an exact callback
limit.

```elixir
steps do
  loop(:drain_queue,
    initial: %{pending: input(:items), completed: value([])},
    using: {MyApp.Queue, :next, 2},
    input: %{state: loop_state(), iteration: iteration()},
    max_iterations: 100
  )
end

output from(:drain_queue)
```

The callback receives the resolved input map and workflow context. It returns
one of these decisions:

```elixir
{:cont, next_state}
{:cont, next_state, created_work}
{:halt, final_value}
{:suspend, next_state}
{:suspend, next_state, created_work}
{:error, reason}
```

`created_work` is a list of work records that the callback added to its own
state or queue. Jidoka records this list as evidence. The loop callback still
owns the rule that inserts and later processes each item.

A completed loop returns `%Jidoka.Workflow.Loop.Result{}`. Its `value` is the
final value. Its `iterations` and `created_work` fields make every decision
inspectable. The runtime fails with `:loop_limit_exceeded` before callback
execution can exceed `max_iterations`.

A suspended loop returns `{:hibernate, snapshot}` from `Workflow.run/3`.
Serialize the snapshot or resume it directly:

```elixir
{:hibernate, snapshot} =
  Jidoka.Workflow.run(MyApp.QueueWorkflow, %{items: [1, 2]})

{:ok, binary} = Jidoka.Workflow.Snapshot.serialize(snapshot)
{:ok, result} = Jidoka.Workflow.resume(binary, context: %{tenant: "acme"})
```

The snapshot stores public context data, completed step outcomes, the loop
cursor, iteration history, and created work. It does not store runtime-only
capabilities. Resume validates the workflow identity, schema version, loop
step, and original safety bound. Earlier completed steps do not run again. The
workflow snapshot binary is not signed, so keep it in trusted application
storage.

### Retry

Add `retry:` to retry target execution. Ref resolution, schema parsing, skipped
steps, and hibernated agent steps are not retried.

```elixir
function :fetch_status, {MyApp.Status, :fetch, 2},
  input: %{id: input(:id)},
  retry: [max_attempts: 3, backoff: [type: :exponential, min: 25, max: 250]]
```

The total workflow timeout still wins over retry backoff.

### `output`

`output` selects the workflow return value.

```elixir
output from(:queue_refund)
```

It can also build a map from step refs:

```elixir
output %{
  refund_id: from(:queue_refund, :refund_id),
  message: from(:draft_reply)
}
```

Rules:

- `output` is required.
- `output` must reference at least one step.
- Static outputs like `output value("ok")` are rejected because they do not
  prove the workflow did any work.

## Data Refs

Refs keep the workflow data-driven. The compiler validates refs when it can;
the runtime validates actual values.

| Ref | Reads from | Example |
| --- | --- | --- |
| `input(:key)` | Workflow input parsed through the Zoi input schema. | `%{order_id: input(:order_id)}` |
| `context(:key)` | Runtime workflow context. | `%{tenant: context(:tenant)}` |
| `from(:step)` | Prior step output. | `input: from(:lookup_order)` |
| `from(:step, :field)` | Field/path inside prior output. | `prompt: from(:policy, :summary)` |
| `maybe_from(:step)` | Prior step output, or `nil` if missing/skipped. | `coalesce([maybe_from(:auto), maybe_from(:review)])` |
| `coalesce([refs])` | First resolved non-nil value. | `output coalesce([maybe_from(:left), maybe_from(:right)])` |
| `item()` | Current map item. | `input: %{lead: item()}` |
| `index()` | Current map item index. | `input: %{index: index()}` |
| `items()` | Current reduce item list. | `input: %{scores: items()}` |
| `loop_state()` | Current loop state. | `input: %{state: loop_state()}` |
| `iteration()` | Zero-based loop callback index. | `input: %{attempt: iteration()}` |
| `value(term)` | Explicit static value. | `%{limit: value(100)}` |

Atom and string map keys are treated as equivalent for inputs, context, and
step output refs. Jidoka does not convert user strings to atoms.

Nested paths use a list:

```elixir
from(:lookup_order, [:customer, "tier"])
```

If a nested field is missing, the workflow fails with details that include
the workflow id, step name, step kind, target, and cause.

## Expose A Workflow As A Tool

Register a workflow in the agent `tools` block:

```elixir
tools do
  workflow MyApp.Workflows.RefundReview,
    as: :review_refund,
    description: "Review whether a refund can be queued.",
    timeout: 30_000,
    async: true,
    max_concurrency: 4,
    forward_context: {:only, [:tenant, :actor]},
    result: :structured,
    idempotency: :idempotent
end
```

Options:

| Option | Default | Purpose |
| --- | --- | --- |
| `as:` | workflow id | Operation name the model sees. Must be lower snake case. |
| `description:` | workflow description | Tool description. |
| `timeout:` | `30_000` | Total wall-clock timeout in milliseconds. |
| `async:` | `false` | Run independent workflow steps concurrently through Runic. |
| `max_concurrency:` | scheduler default | Maximum concurrent workflow steps when `async: true`. |
| `forward_context:` | `:public` | Context visible to the workflow: `:public`, `:none`, `{:only, keys}`, or `{:except, keys}`. |
| `result:` | `:output` | `:output` returns raw workflow output; `:structured` wraps workflow metadata. |
| `idempotency:` | `:idempotent` | Operation idempotency. Use `:unsafe_once` only with approval or an operation control. |
| `approval:` | omitted | Pause before the workflow operation executes. |
| `metadata:` | `%{}` | Extra operation metadata. |

`result: :structured` returns this shape to the parent turn:

```elixir
%{
  workflow: "refund_review",
  operation: "review_refund",
  output: %{approved: true},
  module: "MyApp.Workflows.RefundReview"
}
```

Use `:structured` when the parent turn, tests, or UI need to inspect where
the value came from. Use `:output` when the workflow result is already the
exact value you want the model to observe.

## Callback Compatibility

Callback workflows remain supported:

```elixir
defmodule MyApp.LegacyWorkflow do
  use Jidoka.Workflow,
    id: :legacy_refund,
    description: "Queues a refund through the legacy runtime.",
    parameters_schema: %{
      "type" => "object",
      "properties" => %{"order_id" => %{"type" => "string"}},
      "required" => ["order_id"]
    }

  @impl true
  def run(input, context) do
    {:ok, %{order_id: input["order_id"], tenant: Jidoka.Context.get(context, :tenant)}}
  end
end
```

Do not mix forms. `use Jidoka.Workflow, id: ...` cannot also declare
`workflow do` or `steps do`.

## Runtime Behavior

- Workflow input is parsed through the Zoi input schema before any step runs.
- Context refs must exist before execution starts.
- Step refs are resolved as each step runs.
- A skipped conditional step writes an outcome but not a normal step output.
- A step returning `{:error, reason}`, raising, throwing, or producing an
  invalid action/agent result fails the workflow with step metadata attached.
- Step retry applies only around target execution.
- With `async: true`, Runic executes currently runnable independent steps in
  parallel and applies their results back into the deterministic workflow graph.
- Direct `Jidoka.Workflow.run/3` and tool execution both enforce total
  wall-clock timeout.
- A `loop` step can hibernate the workflow with a serializable continuation.
- A workflow tool returns a typed `:workflow_hibernated` operation error when
  its loop suspends. Resume that snapshot through the application workflow
  boundary; parent agent continuation stays a separate contract.
- An agent step that hibernates is still a workflow error. Human review for an
  agent tool should live at the parent operation boundary.

## Background Runs

`Jidoka.Workflow.Background` runs a declarative workflow under supervision and
stores lifecycle events after every execution cycle. Submission returns a
stable run ID. Later callers need only the runner name and run ID.

Add the runner to an application supervisor:

```elixir
children = [
  {Jidoka.Workflow.Background, name: MyApp.WorkflowRunner}
]
```

Then submit, reconnect, and read event evidence:

```elixir
{:ok, run_id} =
  Jidoka.Workflow.Background.submit(
    MyApp.WorkflowRunner,
    MyApp.Workflows.RefundReview,
    %{"order_id" => "A1001", "amount" => 42.50}
  )

{:ok, run} = Jidoka.Workflow.Background.get(MyApp.WorkflowRunner, run_id)
{:ok, run} = Jidoka.Workflow.Background.await(MyApp.WorkflowRunner, run_id)
{:ok, events} = Jidoka.Workflow.Background.events(MyApp.WorkflowRunner, run_id)
```

The default ETS store keeps progress through worker and runner restarts in one
VM. Supervise the Mnesia store separately when the event stream must survive a
VM restart:

```elixir
children = [
  {Runic.Runner.Store.Mnesia, runner_name: MyApp.WorkflowRunner},
  {Jidoka.Workflow.Background,
   name: MyApp.WorkflowRunner,
   store: Runic.Runner.Store.Mnesia,
   store_opts: []}
]
```

After a stopped or crashed worker, `get/2` returns `:recoverable`. Call
`recover/3` to rebuild the graph from events. Supply fresh context when runtime
capabilities from the old VM are no longer valid:

```elixir
{:ok, _worker} =
  Jidoka.Workflow.Background.recover(
    MyApp.WorkflowRunner,
    run_id,
    context: %{tenant: "acme"}
  )
```

Completed steps do not run again. An in-flight step starts again, so its
external effects must follow the normal idempotency rules. The background API
supports DSL workflows. Callback compatibility workflows stay synchronous.

## Scheduled Runs

`Jidoka.Workflow.Scheduler` owns one-time and cron schedule definitions,
timers, trigger history, and explicit policy. Each accepted trigger submits a
normal background run.

```elixir
children = [
  {Jidoka.Workflow.Background, name: MyApp.WorkflowRunner},
  {Jidoka.Workflow.Scheduler,
   name: MyApp.WorkflowScheduler,
   runner: MyApp.WorkflowRunner}
]

{:ok, schedule} =
  Jidoka.Workflow.Scheduler.add(MyApp.WorkflowScheduler, %{
    id: "weekday_refund_review",
    workflow: MyApp.Workflows.RefundReview,
    input: %{order_id: "A1001", amount: 42.50},
    trigger: {:cron, "0 9 * * 1-5"},
    timezone: "America/Chicago",
    overlap: :skip,
    misfire: :run_once,
    misfire_grace_ms: 1_000,
    cancellation: :future_only,
    retry: [max_attempts: 3]
  })
```

One-time schedules use `trigger: {:at, datetime}`. Cron schedules resolve the
next time in the declared timezone, including daylight-saving changes.

- `overlap: :skip | :allow` controls a trigger while an earlier run is active.
- `misfire: :skip | :run_once` controls a late timer after its grace period.
- `retry:` applies to background-run submission. Workflow step retry stays in
  the workflow.
- `cancellation: :future_only | :future_and_active` controls active runs when
  the schedule is cancelled.

Use `history/2` for trigger evidence. Use `trigger/3` for a manual run without
moving the next scheduled time. In deterministic tests, start the scheduler
with `auto_schedule: false` and call `trigger_due/2` with an explicit time.

## Inspect Workflows

`Jidoka.inspect/1` accepts workflow modules:

```elixir
Jidoka.inspect(MyApp.Workflows.RefundReview)
#=> %{
#=>   kind: :workflow,
#=>   graph: %{nodes: [%{name: :check_policy, kind: :function}], edges: []},
#=>   workflow: %{
#=>     id: "refund_review",
#=>     mode: :dsl,
#=>     steps: [%{name: :check_policy, kind: :function}]
#=>   }
#=> }
```

This is the fastest way to verify the step graph and generated parameters
schema before exposing the workflow to a model.

## Testing

Test workflows at two levels.

First, run the workflow directly:

```elixir
test "refund workflow returns approval data" do
  assert {:ok, %{approved: true}} =
           Jidoka.Workflow.run(
             MyApp.Workflows.RefundReview,
             %{"order_id" => "A1001", "amount" => 42.50},
             context: %{tenant: "acme"}
           )
end
```

Then test it as an agent tool with a fake LLM:

```elixir
test "agent calls refund workflow" do
  llm = fn _intent, journal, _ctx ->
    llm_calls = Enum.count(journal.results, fn {_id, r} -> r.kind == :llm end)

    case llm_calls do
      0 ->
        {:ok,
         %{
           type: :operation,
           name: "review_refund",
           arguments: %{"order_id" => "A1001", "amount" => 42.50}
         }}

      1 ->
        {:ok, %{type: :final, content: "Refund A1001 is approved."}}
    end
  end

  request =
    Jidoka.Turn.Request.new!(
      input: "Can we refund order A1001?",
      context: %{tenant: "acme"}
    )

  assert {:ok, result} =
           Jidoka.turn(MyApp.SupportAgent, request, llm: llm)

  assert result.content == "Refund A1001 is approved."
end
```

For the package's own examples, see
`test/jidoka/workflow_dsl_test.exs` and
`test/integration/workflow_dsl_integration_test.exs`.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| Spark error: `workflow.id` is required | Missing `id` in `workflow do`. | Add `id :lower_snake_case`. |
| Spark error: input must be a Zoi object | `input` was omitted or passed a raw map. | Use `input Zoi.object(%{...})`. |
| Spark error: missing step ref | `from(:step)` or `after: [:step]` targets a nonexistent step. | Rename the ref or add the step. |
| Spark error: dependency cycle | Static steps refer to each other through `from` or `after`. | Break the static cycle and use one bounded `loop` step for repeated work. |
| `Missing workflow context key` | A `context(:key)` ref was declared but not forwarded/passed. | Pass `context:` to `Workflow.run/3` or configure `forward_context:` in `tools.workflow`. |
| Workflow step failed with `missing_field` | `from(:step, path)` selected a missing field. | Inspect the prior step output and correct the path. |
| Workflow timed out | A step blocked past `timeout:`. | Raise timeout or submit the workflow through `Workflow.Background`. |
| Loop limit exceeded | A loop did not halt before its exact safety bound. | Fix the termination rule or raise the declared bound with a new snapshot version. |
| Background run is `:recoverable` | Its worker stopped while event evidence remains. | Call `Background.recover/3` with fresh runtime context. |
| Schedule trigger was skipped | Misfire or overlap policy rejected this occurrence. | Inspect `Scheduler.history/2` and the trigger `reason`. |
| Agent step hibernated | A child agent requested review inside workflow execution. | Move HITL to the parent operation control boundary. |

## Related Guides

- [Agent DSL](agent-dsl.md) - where workflows are registered as tools.
- [Skill, Workflow, And Subagent Tools](skill-workflow-subagent-tools.md) -
  when to choose workflow vs skill vs subagent.
- [Operation Source Contracts](operation-source-contracts.md) - how workflow
  operations compile to the shared operation source shape.
- [Inspection And Preflight](inspection-and-preflight.md) - how to inspect
  workflow specs and agent prompts.
- [Idempotency And Safety](idempotency-and-safety.md) - operation
  idempotency and controls.
- [Workflow Composition Agent](../examples/workflow_composition/README.md) -
  one executable proof for loops, background runs, schedules, and all earlier
  graph features.
