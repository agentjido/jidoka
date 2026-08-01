# Durable Refund Agent

The Durable Refund Agent proves the execution and continuation feature group
with one deterministic business flow. It does not use a provider key, network
request, or recorded model response.

The five proof cases show:

- one asynchronous request with thinking and content deltas;
- typed cooperative cancellation with one terminal event;
- model-turn, output-token, and capability-time limits;
- worker crash recovery after an unsafe refund result is durable;
- an independent runnable fork with root and parent lineage.

The crash case stops the first worker after the refund result reaches the
session store but before the worker can acknowledge it. A second worker takes
the expired lease, resumes the stored snapshot, and uses the result without
calling `issue_refund` again.

## Run It

```bash
mix jidoka.example durable_refund
mix test examples/durable_refund/test/execution_and_continuation_test.exs --trace
mix jidoka.examples.check --example durable_refund --verbose
```

Open `durable_refund.livemd` for the complete executable walkthrough.

## Important Files

- `lib/agent.ex` defines the refund agent and its execution limits.
- `lib/actions/issue_refund.ex` is the unsafe-once operation.
- `lib/controls/allow_refund.ex` makes the unsafe operation policy explicit.
- `lib/scripted_llm.ex` provides deterministic stream, cancel, and refund paths.
- `example.exs` owns the five runnable demonstrations.
- `test/execution_and_continuation_test.exs` is the proof authority.

For the public contracts, see:

- [`guides/streaming.md`](../../guides/streaming.md)
- [`guides/sessions-and-stores.md`](../../guides/sessions-and-stores.md)
- [`guides/idempotency-and-safety.md`](../../guides/idempotency-and-safety.md)
