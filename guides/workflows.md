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
- Do not use a workflow for open-ended orchestration. The workflow DSL is
  deterministic: no loops, scheduling, persisted runs, or dynamic runtime graph
  mutation. Gates and bounded map/reduce fanout are supported.

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
    {:ok, %{order_id: input["order_id"], tenant: context[:tenant]}}
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
- A workflow agent step that hibernates is treated as a workflow error for
  now. Human-in-the-loop pauses should live at the parent agent operation
  boundary.

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
  llm = fn _intent, journal ->
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
           MyApp.SupportAgent.run_turn(request,
             llm: llm,
             operation_context: %{parent_context: request.context}
           )

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
| Spark error: dependency cycle | Steps refer to each other through `from` or `after`. | Break the cycle; workflows do not support loops. |
| `Missing workflow context key` | A `context(:key)` ref was declared but not forwarded/passed. | Pass `context:` to `Workflow.run/3` or configure `forward_context:` in `tools.workflow`. |
| Workflow step failed with `missing_field` | `from(:step, path)` selected a missing field. | Inspect the prior step output and correct the path. |
| Workflow timed out | A step blocked past `timeout:`. | Raise timeout or move long work out of the synchronous workflow. |
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
