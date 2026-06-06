# Idempotency And Safety

Every Jidoka operation declares one idempotency policy. That single field
drives whether the runtime can retry, whether resume can replay, whether
the spec compiles without approval or an operation control, and whether incomplete
work surfaces to application reconciliation. This guide documents each
policy in detail, the `Jidoka.Effect.Journal` semantics on resume, and the
production guardrails that depend on getting this right.

## When To Use This

- Use this guide when an agent is about to perform an external action you
  cannot blindly retry (charges, sends, deletes, deploys).
- Use this guide when you add a new operation source and need to pick the
  right `idempotency:` value.
- Use this guide when an incomplete `Jidoka.resume/2` should not blow up
  the agent loop but instead route to a reconciliation worker.

## Prerequisites

- An agent with at least one operation. See
  [Getting Started](getting-started.md).
- Familiarity with `Jidoka.Agent.Spec.Operation` (the `idempotency` field
  lives there).
- Familiarity with snapshots and resume; see
  [Snapshots And Resume](snapshots-and-resume.md).

```bash
mix deps.get
mix test
```

## Quick Example

Declare a single risky operation and attach approval. The spec refuses to
compile until `:unsafe_once` work has either approval or a matching operation
control.

```elixir
defmodule MyApp.SupportAgent do
  use Jidoka.Agent

  agent :support_agent do
    instructions "Refund only when explicitly approved."
  end

  tools do
    action MyApp.RefundOrder,
      idempotency: :unsafe_once,
      approval: [reason: :refund_requires_review]
  end
end
```

Compiling the plan now succeeds:

```elixir
{:ok, _plan} = Jidoka.plan(MyApp.SupportAgent)
```

Remove the approval policy and the plan refuses to compile with
`{:error, {:unsafe_once_requires_control, "refund_order", :action}}`.

## Concepts

Idempotency policy is the contract between the agent definition, the
runtime, and the journal. The runtime never assumes; it always asks.

```diagram
╭───────────────────────╮     ╭──────────────────────╮
│ Operation.idempotency │────▶│ Spec validation      │
╰───────────────────────╯     │ (compile-time gate)  │
                              ╰──────┬───────────────╯
                                     │
                                     ▼
                          ╭──────────────────────╮
                          │ Effect.Intent        │
                          │ idempotency: ...     │
                          │ idempotency_key: ... │
                          ╰──────┬───────────────╯
                                 │
                  ╭──────────────┼──────────────╮
                  ▼              ▼              ▼
            Journal has     Journal has     Journal has
            no intent       intent only     intent + result
                  │              │              │
                  ▼              ▼              ▼
            run capability   per-policy      replay journal
                             decision        result
```

Per-policy resume rules:

- `:pure` and `:idempotent` retry safely from inputs. Resume will replay
  the journaled result; missing results are recomputed.
- `:dedupe` prefers a recorded journal result. Use it for operations that
  are expensive but safe to repeat.
- `:reconcile` allows the application to inspect incomplete work after
  resume. The runtime returns the intent and lets a reconciliation worker
  decide.
- `:unsafe_once` forbids automatic retry. Resume returns a typed error
  when an intent is recorded without a result.

## How To

### Step 1: Pick A Policy For Each Operation

Use the smallest policy that is still correct.

- `:pure` - the operation is a deterministic function of its arguments
  with no observable side effects. Lookups, transformations, schema
  validations.
- `:idempotent` (default) - calling twice with the same key has the same
  external outcome. Most external APIs that accept idempotency keys.
- `:dedupe` - calling twice may be expensive or noisy, but is otherwise
  safe. Prefer the journaled result.
- `:reconcile` - external work can leave the system in an in-between
  state (an enqueued job whose status is unknown). The application owns
  reconciliation.
- `:unsafe_once` - calling twice is unsafe. Charges, sends, deletes,
  one-way deploys.

```elixir
tools do
  action MyApp.LookupOrder, idempotency: :pure
  action MyApp.ChargeCard, idempotency: :unsafe_once
  action MyApp.EnqueueJob, idempotency: :reconcile
end
```

### Step 2: Add Approval Or Controls For `:unsafe_once`

`Jidoka.Agent.Spec.Operation.requires_control?/1` returns `true` for
`:unsafe_once`. The plan compiler refuses to produce a plan unless the
operation has an approval policy or a matching operation control.

```elixir
tools do
  action MyApp.ChargeCard,
    idempotency: :unsafe_once,
    approval: true
end
```

Use a control when the policy needs code:

```elixir
controls do
  operation MyApp.RequireChargeApproval,
    when: [name: :charge_card, idempotency: :unsafe_once]
end
```

The control can allow, block, or interrupt for human review. See
[Human In The Loop](human-in-the-loop.md) for the durable approval flow.

### Step 3: Understand The Journal On Resume

Every effect is recorded as an intent before the capability runs and as
a result when the capability returns. On resume:

- If the journal already has a result for the pending intent, the
  effect interpreter replays it and never calls the capability.
- If only the intent is recorded, the per-policy validation runs.
- If the intent is missing, the runtime asks for the result through the
  capability.

```elixir
%Jidoka.Effect.Journal{
  intents: %{"operation:abc" => intent},
  results: %{"operation:abc" => result}
}
```

`Jidoka.Effect.Journal.result_for/2` and `Jidoka.Effect.Journal.intent_for/2`
are the lookup helpers. `Jidoka.Effect.Journal.incomplete_intent?/2` is
true when an intent has no recorded result.

### Step 4: Handle Reconciliation Paths

For `:reconcile` operations, the application is expected to observe
incomplete intents and resolve them out of band. A common pattern is to
enumerate snapshots whose journal has incomplete intents and route them
to a reconciler.

```elixir
def reconcile_pending(snapshot) do
  journal = snapshot.turn_state.journal

  for {_id, intent} <- journal.intents,
      is_nil(Jidoka.Effect.Journal.result_for(journal, intent)),
      intent.idempotency == :reconcile do
    MyApp.Reconciler.queue(intent)
  end
end
```

After reconciliation completes externally, persist the result into the
journal (or rebuild the snapshot through your own session pipeline) and
resume.

### Step 5: Trust The `:unsafe_once` Guard On Resume

The runtime never quietly retries an `:unsafe_once` operation that has
an incomplete intent. Resume returns a typed error instead:

```elixir
case Jidoka.resume(snapshot, llm: llm, operations: operations) do
  {:error, %Jidoka.Error{} = error} ->
    case Jidoka.error_to_map(error) do
      %{reason: :unsafe_once_incomplete_effect, intent_id: id} ->
        MyApp.UnsafeOnceQueue.route(id, snapshot)

      _ ->
        Logger.error("resume failed: " <> inspect(error))
    end

  other ->
    other
end
```

Approved interrupts are the supported way to re-enter an `:unsafe_once`
intent: the operation control approves the specific interrupt, and the
runtime stamps `metadata["approved_interrupt_id"]` on the effect. The
journal then accepts the call exactly once.

### Step 6: Distinguish `:dedupe` From `:idempotent`

Both policies are safe to retry. The difference is intent:

- `:idempotent` says "retry is correct; do not avoid it." Use it for
  HTTP calls with idempotency keys, database upserts, and most external
  APIs that already promise safe retries.
- `:dedupe` says "retry is correct but wasteful; prefer the journaled
  result." Use it for cache-fronted lookups or any operation that
  encountered a cost (LLM call, paid API, expensive aggregation) you do
  not want to repeat.

In practice this guides resume behavior: `:dedupe` on resume always
prefers the journaled result; `:idempotent` is happy to call the
capability again when the intent has no result.

## Common Patterns

- **Default to `:idempotent`.** It is the spec default for a reason.
- **Promote to `:unsafe_once` for external state changes.** Charges,
  sends, deletes, and deploys deserve the strongest guard.
- **Use `:reconcile` when truth lives elsewhere.** Async work queued to
  an external system is the canonical case.
- **Pair `:unsafe_once` with approval.** `approval: true` is the simplest
  route. A blocking control is fine for "never allow"; a custom interrupting
  control is useful when approval depends on code.
- **Treat the journal as the contract.** Tests should make assertions
  against `Effect.Journal.intent_recorded?/2` and
  `Effect.Journal.result_for/2`, not on capability call counts alone.

## Testing

A simple test exercises both the compile-time gate and the resume-time
guard.

```elixir
test "unsafe_once requires approval or an operation control before plan compiles" do
  spec =
    Jidoka.agent!(
      id: "risky",
      instructions: "Charge only when explicit.",
      operations: [
        %{name: "charge_card", idempotency: :unsafe_once, kind: :action}
      ]
    )

  assert {:error, {:unsafe_once_requires_control, "charge_card", :action}} =
           Jidoka.plan(spec)
end

test "incomplete unsafe_once intent fails on resume" do
  llm = fn _intent, _journal, _ctx ->
    {:ok, %{type: :operation, name: "charge_card",
            arguments: %{"order_id" => "A1"}}}
  end

  operations = fn _intent, _journal, _ctx -> raise "boom" end

  assert {:error, _error} =
           Jidoka.turn(MyApp.SupportAgent, "Charge A1",
             llm: llm,
             operations: operations
           )

  # The application persisted the snapshot for a reconciler before
  # surfacing the failure; resuming it never retries the operation.
end
```

For `:dedupe` and `:reconcile` operations, build a journal that already
has the desired shape and assert that resume routes correctly.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, {:unsafe_once_requires_control, name, kind}}` | An `:unsafe_once` operation has no approval policy or matching operation control. | Add `approval: true` or a `controls do ... operation ... when: [name: name] end` clause. |
| `{:error, %Jidoka.Error{reason: :unsafe_once_incomplete_effect}}` | Resume saw a recorded intent without a result. | Route the snapshot to reconciliation; do not auto-retry. |
| Capability called twice on resume | Operation is `:idempotent` and the journal lost the result. | Persist the full snapshot including its journal; ensure your store preserves all fields. |
| Reconciliation never fires | The journal had no incomplete intents because the runtime did call the capability. | Confirm the policy is `:reconcile`, not `:idempotent`, and inspect `result.journal`. |
| Approved interrupt still errors on `:unsafe_once` | Approval target was the wrong interrupt id. | Build the response with `Jidoka.Review.Response.approve(review.interrupt_id)`. |
| `:dedupe` operation still runs every time | The journal across resumes is empty because each call started a new turn. | Use a session so the journal persists, or pass the prior `snapshot` to `resume/2`. |

## Reference

Key modules touched in this guide:

- [`Jidoka.Agent.Spec.Operation`](`Jidoka.Agent.Spec.Operation`) -
  `valid_idempotencies/0`, `requires_control?/1`, `replay_safe?/1`,
  `kind/1`.
- [`Jidoka.Agent.Spec`](`Jidoka.Agent.Spec`) -
  `validate_operation_policies/1`, `validate_operation_policy/2`.
- [`Jidoka.Effect.Intent`](`Jidoka.Effect.Intent`) - struct that carries
  the policy and the deterministic `idempotency_key`.
- [`Jidoka.Effect.Journal`](`Jidoka.Effect.Journal`) - `put_intent/2`,
  `put_result/2`, `result_for/2`, `intent_recorded?/2`,
  `incomplete_intent?/2`.
- [`Jidoka.Runtime.EffectInterpreter`](`Jidoka.Runtime.EffectInterpreter`) -
  effect shell that enforces the per-policy resume rules.
- [`Jidoka.Review.Response`](`Jidoka.Review.Response`) - the approval
  path that lets `:unsafe_once` operations execute exactly once.

## Related Guides

- [Controls](controls.md) - the operation control surface required by
  `:unsafe_once`.
- [Human In The Loop](human-in-the-loop.md) - durable approvals for
  risky operations.
- [Snapshots And Resume](snapshots-and-resume.md) - the durable artifact
  the journal lives inside.
- [Sessions And Stores](sessions-and-stores.md) - the durable session
  that preserves the journal between turns.
