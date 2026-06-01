# Human In The Loop

Jidoka treats human review as a durable pause, not as a callback or a
side-channel. An operation control returns `{:interrupt, reason}` before the
operation runs, the turn hibernates at a review cursor, and an application
later resumes the same snapshot with an approval or a denial.

## When To Use This

- Use durable approvals for any action a model can request that you do not
  want to execute automatically: refunds, deletes, deploys, sends to
  external systems.
- Use durable approvals for compliance flows where the reviewer is a
  different process or even a different deployment than the runtime.
- Do not use durable approvals as a substitute for input/output controls.
  Those run at different boundaries; see [Controls](controls.md).

## Prerequisites

- A Jidoka agent with at least one operation whose call you want to gate.
- A persistent session, or a place to store the hibernation snapshot. See
  [Sessions And Stores](sessions-and-stores.md) and
  [Snapshots And Resume](snapshots-and-resume.md).
- Familiarity with the operation control surface in [Controls](controls.md).

```bash
mix deps.get
mix test
```

## Quick Example

A refund operation, an approval control, and an end-to-end approve path.

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

defmodule MyApp.SupportAgent do
  use Jidoka.Agent

  agent :support_agent do
    instructions "Use refund_order when the customer asks for a refund."
  end

  tools do
    action MyApp.RefundOrder
  end

  controls do
    operation MyApp.RequireRefundApproval, when: [name: :refund_order]
  end
end

llm = fn _intent, journal ->
  case map_size(journal.results) do
    0 -> {:ok, %{type: :operation, name: "refund_order",
                 arguments: %{"order_id" => "A1001"}}}
    _ -> {:ok, %{type: :final, content: "Refunded A1001."}}
  end
end

operations = fn _intent, _journal -> {:ok, %{refunded: true}} end

{:hibernate, snapshot} =
  Jidoka.turn(MyApp.SupportAgent, "Refund A1001",
    llm: llm,
    operations: operations
  )

review = snapshot.metadata["pending_review"]
approval = Jidoka.Review.Response.approve(review.interrupt_id)

{:ok, %Jidoka.Turn.Result{content: "Refunded A1001."}} =
  Jidoka.resume(snapshot,
    approval: approval,
    llm: llm,
    operations: operations
  )
```

## Concepts

The data path is simple. Every stage is just data.

```diagram
╭───────────────────────╮     ╭──────────────────────╮
│ Operation control     │────▶│ {:interrupt, reason} │
╰───────────────────────╯     ╰──────┬───────────────╯
                                     │
                                     ▼
                          ╭──────────────────────╮
                          │ Review.Interrupt     │
                          │ snapshot.cursor=:review │
                          ╰──────┬───────────────╯
                                 │
                                 ▼
                          ╭──────────────────────╮
                          │ Review.Request       │
                          │ (snapshot.metadata)  │
                          ╰──────┬───────────────╯
                                 │
                                 ▼
                          ╭──────────────────────╮
                          │ Review.Response      │
                          │ approve / deny       │
                          ╰──────┬───────────────╯
                                 │
                                 ▼
                          ╭──────────────────────╮
                          │ Jidoka.resume/2      │
                          │ approval: response   │
                          ╰──────────────────────╯
```

- [`Jidoka.Review.Interrupt`](`Jidoka.Review.Interrupt`) is the runtime
  pause. It records the agent, request, effect id, operation, arguments,
  idempotency, and an optional `expires_at_ms`.
- [`Jidoka.Review.Request`](`Jidoka.Review.Request`) is the
  application-facing view. It is built from the interrupt and stored on
  `snapshot.metadata["pending_review"]` and `session.pending_reviews`.
- [`Jidoka.Review.Response`](`Jidoka.Review.Response`) is the small struct
  the application creates to resume: either `:approved` or `:denied`,
  always targeting one interrupt id.
- The interrupt only fires for `:operation` boundaries today; input and
  output controls cannot durably hibernate yet and must block or fail.

## How To

### Step 1: Define The Operation Control

Operation controls receive a
`Jidoka.Runtime.Controls.OperationContext`. Returning `{:interrupt,
reason}` flips the turn into the review path.

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

Match the control as narrowly as possible. Common keys are `kind`, `name`,
`source`, `idempotency`, and any `metadata`. Risky operations declared with
`idempotency: :unsafe_once` must have an operation control before the spec
can compile. See [Idempotency And Safety](idempotency-and-safety.md).

### Step 2: Observe The Hibernation

Running the turn returns `{:hibernate, snapshot}` instead of `{:ok,
result}`. Read the pending review off the snapshot.

```elixir
{:hibernate, snapshot} =
  Jidoka.turn(MyApp.SupportAgent, "Refund A1001",
    llm: llm,
    operations: operations
  )

snapshot.cursor.phase
#=> :review

%Jidoka.Review.Request{} = review = snapshot.metadata["pending_review"]
review.operation
#=> "refund_order"
review.arguments
#=> %{"order_id" => "A1001"}
```

When the turn runs inside a session, the same request is mirrored on the
session struct:

```elixir
{:ok, [^review]} = Jidoka.Session.pending_reviews(session)
```

### Step 3: Approve And Resume

`Jidoka.Review.Response.approve/2` builds the response targeted at the
pending interrupt.

```elixir
approval = Jidoka.Review.Response.approve(review.interrupt_id)

{:ok, %Jidoka.Turn.Result{}} =
  Jidoka.resume(snapshot,
    approval: approval,
    llm: llm,
    operations: operations
  )
```

The runner does not re-run the operation control for the approved
interrupt. The journal still prevents duplicate effects on later resumes:
once the operation result is in the journal, replaying the snapshot reuses
the recorded result instead of calling the capability again.

### Step 4: Deny For A Deterministic Non-Execution

A denial resumes the same snapshot but never calls the operation
capability.

```elixir
denial = Jidoka.Review.Response.deny(review.interrupt_id, reason: :policy_denied)

{:error, {:approval_denied, ^denial}} =
  Jidoka.resume(snapshot,
    approval: denial,
    llm: llm,
    operations: operations
  )
```

`{:error, {:approval_denied, response}}` is the contractual outcome of a
denial. Surface the response struct to the caller; it carries the
`reason`, `responded_at_ms`, and `metadata` the reviewer attached.

### Step 5: Honor Expiration Windows

Pass `:approval_ttl_ms` when you want approvals to expire. The runtime
stamps `expires_at_ms` on the interrupt at hibernation time.

```elixir
{:hibernate, snapshot} =
  Jidoka.turn(MyApp.SupportAgent, "Refund A1001",
    llm: llm,
    operations: operations,
    approval_ttl_ms: 60_000
  )

review = snapshot.metadata["pending_review"]
review.expires_at_ms
#=> 1717250000000
```

When resume runs after expiry, validation rejects the response:

```elixir
late = Jidoka.Review.Response.approve(review.interrupt_id,
  responded_at_ms: review.expires_at_ms + 1)

{:error, {:approval_expired, _id, _now, _expires}} =
  Jidoka.resume(snapshot,
    approval: late,
    llm: llm,
    operations: operations
  )
```

Application code should set `responded_at_ms` from the same clock it uses
for `created_at_ms`; the harness fills it in with the current system clock
if you leave it `nil`.

### Step 6: List Pending Reviews Across A Store

A session keeps its own pending requests. A store can flatten across
sessions for an operator dashboard.

```elixir
{:ok, [_review | _rest]} = Jidoka.Session.pending_reviews(store)
```

Each entry is a `Jidoka.Review.Request` struct. It carries everything an
operator needs to render the decision: agent id, operation, arguments,
reason, and the expiration timestamp.

## Common Patterns

- **One control per risk class.** Keep the control logic to a simple
  match on `operation` and `kind`. Push richer policy into the
  application-side approval workflow.
- **Persist before showing to a reviewer.** Always save the snapshot
  (or its session) before exposing the pending review. The reviewer's
  decision must be able to find the same snapshot later.
- **Pass `:approval_ttl_ms`.** Even a long TTL is safer than none.
  Expired approvals fail deterministically.
- **Treat denials as expected.** A `{:error, {:approval_denied, _}}`
  return value should be logged but is not a runtime fault.
- **Do not retry approvals.** Once an interrupt is resolved its effect
  result is journaled. A second `Jidoka.resume/2` against the same
  snapshot will reuse that result, not call the operation again.

## Testing

Use deterministic fakes for both the LLM and the operations capability.

```elixir
test "approval resumes the pending refund" do
  llm = fn _intent, journal ->
    case map_size(journal.results) do
      0 -> {:ok, %{type: :operation, name: "refund_order",
                   arguments: %{"order_id" => "A1001"}}}
      _ -> {:ok, %{type: :final, content: "Refunded A1001."}}
    end
  end

  operations = fn _intent, _journal -> {:ok, %{refunded: true}} end

  assert {:hibernate, snapshot} =
           Jidoka.turn(MyApp.SupportAgent, "Refund A1001",
             llm: llm,
             operations: operations
           )

  review = snapshot.metadata["pending_review"]
  approval = Jidoka.Review.Response.approve(review.interrupt_id)

  assert {:ok, %Jidoka.Turn.Result{content: "Refunded A1001."}} =
           Jidoka.resume(snapshot,
             approval: approval,
             llm: llm,
             operations: operations
           )
end

```

A denial test mirrors the approval test: build the snapshot, call
`Jidoka.Review.Response.deny/2`, assert on
`{:error, {:approval_denied, _response}}`, and assert the operations
capability was never invoked.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, {:approval_interrupt_mismatch, expected, actual}}` | Approval was built for a different interrupt id. | Always read `review.interrupt_id` from the live snapshot. |
| `{:error, {:approval_expired, _, _, _}}` | Response came in after `expires_at_ms`. | Build a fresh review request, or extend `:approval_ttl_ms`. |
| `{:error, {:approval_denied, response}}` | Reviewer denied the action. | Surface the response to the caller; do not retry. |
| Operation is called twice after approval | Snapshot was resumed twice without checking the result. | Resume each snapshot once; persist `Turn.Result` after success. |
| `{:error, {:unsafe_once_requires_control, name, kind}}` at compile | An `:unsafe_once` operation has no operation control. | Add a matching operation control before compiling the plan. |
| `snapshot.metadata["pending_review"]` is `nil` | The hibernation came from `:after_prompt`/`:before_each_effect`, not a review. | Inspect `snapshot.cursor.phase`; only `:review` produces a pending request. |

## Reference

Key modules touched in this guide:

- [`Jidoka.Review`](`Jidoka.Review`) - umbrella alias module.
- [`Jidoka.Review.Interrupt`](`Jidoka.Review.Interrupt`) - durable pause
  data with `with_review_window/3` and `expired?/2`.
- [`Jidoka.Review.Request`](`Jidoka.Review.Request`) - application-facing
  request built from an interrupt.
- [`Jidoka.Review.Response`](`Jidoka.Review.Response`) - `approve/2`,
  `deny/2`, decision enum `[:approved, :denied]`.
- [`Jidoka.Runtime.Controls.OperationContext`](`Jidoka.Runtime.Controls.OperationContext`) -
  what the operation control receives.
- [`Jidoka.Harness`](`Jidoka.Harness`) - resume and approval normalization
  via `:approval` / `:approval_ttl_ms` options.

## Related Guides

- [Controls](controls.md) - the full control surface, including input and
  output controls.
- [Sessions And Stores](sessions-and-stores.md) - listing pending reviews
  across sessions.
- [Snapshots And Resume](snapshots-and-resume.md) - the snapshot lifecycle
  beneath the approval flow.
- [Idempotency And Safety](idempotency-and-safety.md) - why
  `:unsafe_once` operations must have an approval control.
