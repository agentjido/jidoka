# Durable Refund Agent

The Durable Refund Agent demonstrates the execution and continuation feature group
with one deterministic business flow. It does not use a provider key, network
request, or recorded model response.

The five deterministic demonstrations show:

- one asynchronous request with thinking and content deltas;
- typed cooperative cancellation with one terminal event;
- model-turn, output-token, and capability-time limits;
- worker crash recovery after an unsafe refund result is durable;
- an independent runnable fork with root and parent lineage.

The crash case stops the first worker after the refund result reaches the
session store but before the worker can acknowledge it. A second worker takes
the expired lease, resumes the stored snapshot, and uses the result without
calling `issue_refund` again.

## Read It In This Order

1. `lib/agent.ex` - the agent limits and unsafe-once refund operation.
2. `lib/actions/issue_refund.ex` - the external effect boundary.
3. `lib/scenarios/async_execution.ex` - streaming and cancellation.
4. `lib/scenarios/execution_limits.ex` - turn, token, and timeout limits.
5. `lib/scenarios/durable_recovery.ex` - checkpoint, lease, and recovery
   behavior.
6. `lib/scenarios/safe_fork.ex` - independent session branches.
7. `test/execution_and_continuation_test.exs` - application behavior and
   runtime guarantees.
8. `durable_refund.livemd` - the guided runtime walkthrough.

The agent, action, control, limits, and store interfaces are application
patterns. `ScriptedLLM`, the scenario modules, `example.exs`, the manifest, and
the tests are deterministic demo code. Production code uses a real model and a
durable store, but the same cancellation, recovery, and fork APIs apply.

## Run It

```bash
mix run examples/durable_refund/example.exs
mix test --only example:durable_refund
mix test examples/durable_refund/test/execution_and_continuation_test.exs --trace
mix run scripts/check_livebooks.exs -- --project examples/durable_refund/durable_refund.livemd
```

Open `durable_refund.livemd` for the complete executable walkthrough.

## Important Files

- `lib/agent.ex` defines the refund agent and its execution limits.
- `lib/actions/issue_refund.ex` is the unsafe-once operation.
- `lib/controls/allow_refund.ex` makes the unsafe operation policy explicit.
- `lib/scripted_llm.ex` provides deterministic stream, cancel, and refund paths.
- `lib/scenario.ex` gives callers one stable entry point.
- `lib/scenarios/` separates the five runtime demonstrations by concept.
- `example.exs` is the small command entry point.
- `test/execution_and_continuation_test.exs` is the behavior authority.

For the public contracts, see:

- [`guides/streaming.md`](../../guides/streaming.md)
- [`guides/sessions-and-stores.md`](../../guides/sessions-and-stores.md)
- [`guides/idempotency-and-safety.md`](../../guides/idempotency-and-safety.md)
