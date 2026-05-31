# Controls

Controls are Jidoka's policy surface. They are declared on `Agent.Spec` and run
at explicit runtime boundaries without changing the pure Runic workflow steps.

## Boundaries

Jidoka currently supports these control surfaces:

- `input` runs before prompt assembly and the first model call.
- `operation` runs before a model-requested operation capability executes.
- `output` runs after structured result validation and before the turn returns.
- `max_turns` bounds model/operation loops.
- `timeout` bounds wall-clock turn runtime in milliseconds.

Controls may return:

- `:cont`, `:allow`, or `:ok` to continue;
- `{:block, reason}` to fail deterministically;
- `{:interrupt, reason}` to pause when supported by that boundary;
- `{:error, reason}` to fail as a control error.

Operation interrupts are durable today. Input/output interrupts are currently
reported as errors until those boundaries get resumable wait semantics.

## Input Controls

Input controls receive a map with the request, context, metadata, and input
text:

```elixir
defmodule MyApp.NoSecrets do
  use Jidoka.Control, name: "no_secrets"

  @impl true
  def call(%{input: input}) do
    if String.contains?(input, "secret") do
      {:block, :secret_input}
    else
      :cont
    end
  end
end
```

Declare the control in the agent:

```elixir
defmodule MyApp.SupportAgent do
  use Jidoka.Agent

  agent :support_agent do
    instructions "Answer support questions tersely."
  end

  controls do
    input MyApp.NoSecrets
  end
end
```

## Operation Controls And Approvals

Operation controls receive `Jidoka.Runtime.Controls.OperationContext`. This is
the safety boundary for tool/action execution.

```elixir
defmodule MyApp.RequireRefundApproval do
  use Jidoka.Control, name: "require_refund_approval"

  @impl true
  def call(%Jidoka.Runtime.Controls.OperationContext{} = operation) do
    if operation.operation == "refund_order" do
      {:interrupt, :approval_required}
    else
      :cont
    end
  end
end
```

Attach it to a specific operation:

```elixir
controls do
  operation MyApp.RequireRefundApproval,
    when: [kind: :action, name: :refund_order]
end
```

Operation matches can be broad or narrow. Supported match keys are `kind`,
`name`, `source`, `idempotency`, and top-level `metadata` values:

```elixir
controls do
  operation MyApp.RequireRefundApproval,
    when: [
      kind: :tool,
      source: :payments,
      idempotency: :unsafe_once,
      metadata: %{risk: "high"}
    ]
end
```

If an operation control interrupts, the turn hibernates:

```elixir
{:hibernate, snapshot} =
  Jidoka.run_turn(spec, "Refund order_123",
    llm: llm,
    operations: operations
  )

review = snapshot.metadata["pending_review"]
approval = Jidoka.Review.Response.approve(review.interrupt_id)

{:ok, result} =
  Jidoka.resume(snapshot,
    approval: approval,
    llm: llm,
    operations: operations
  )
```

Operations marked `:unsafe_once` must have a matching operation control before
the agent can compile into a plan. This makes risky work visible during
preflight instead of after a model chooses the operation.

## Output Controls

Output controls run after any configured structured result schema validates.
They receive both the assistant text and `result_value`:

```elixir
defmodule MyApp.SafeReply do
  use Jidoka.Control, name: "safe_reply"

  @impl true
  def call(%{result: text, result_value: value}) do
    cond do
      String.contains?(text, "forbidden") -> {:block, :unsafe_reply}
      match?(%{approved: false}, value) -> {:block, :unapproved_result}
      true -> :cont
    end
  end
end
```

## Import Shape

JSON/YAML controls use string refs resolved through registries:

```yaml
controls:
  max_turns: 8
  timeout: 30000
  inputs:
    - control: no_secrets
  operations:
    - control: require_refund_approval
      when:
        kind: action
        name: refund_order
  outputs:
    - control: safe_reply
```

```elixir
{:ok, spec} =
  Jidoka.import(yaml,
    registries: %{
      controls: %{
        "no_secrets" => MyApp.NoSecrets,
        "require_refund_approval" => MyApp.RequireRefundApproval,
        "safe_reply" => MyApp.SafeReply
      }
    }
  )
```

## Testing

Use a fake LLM and local operation capability for deterministic control tests.
Existing examples live under:

- `test/integration/controls_integration_test.exs`
- `test/integration/human_in_the_loop_integration_test.exs`
- `test/support/integration/controls/`
