# Live LLM Tool Loop

Use this guide to verify a real provider call and one complete model-operation
loop. Keep this check separate from the deterministic test suite because it
uses credentials, network access, provider quota, and a non-deterministic
model.

## Prerequisites

Complete [Getting Started](getting-started.md) and
[Tools And Operations](tools-and-operations.md) first.

You need:

- a supported model in `Jidoka.Config.default_model/0` or in your agent;
- provider credentials that ReqLLM can use;
- network access to the provider;
- enough provider quota for at least two model calls.

A tool loop normally needs one model call to request the operation and one
model call to produce the final answer.

## Configure Credentials

Jidoka does not load `.env` files from the package runtime. Export a provider
key in the shell that runs the live check, or configure ReqLLM in the host
application.

For example:

```bash
export OPENAI_API_KEY=...
# or
export ANTHROPIC_API_KEY=...
```

Do not put provider keys in agent definitions, guide examples, test fixtures,
snapshots, or trace metadata.

## Inspect Before The Live Call

Use preflight to check the exact prompt and operations without network access:

```elixir
{:ok, preflight} =
  Jidoka.preflight(
    MyApp.TimeAgent,
    "What time is it in Chicago? Use local_time."
  )

Enum.map(preflight.prompt.operations, & &1.name)
#=> ["local_time"]
```

Check the model reference, tool name, tool description, parameters schema, and
control policy before you spend provider quota.

## Run The Packaged Live Test

The standard test configuration excludes tests tagged with `:live`. Run the
packaged live test explicitly:

```bash
mix test --include live test/jidoka/live_req_llm_test.exs
```

The test skips when neither `OPENAI_API_KEY` nor `ANTHROPIC_API_KEY` is set.
When credentials are available, the test verifies that:

- the Spark DSL compiles to a Jido-backed agent module;
- ReqLLM makes a real model call;
- the model requests the `local_time` operation;
- the operation runs through the Jido action adapter;
- the operation result is added to semantic agent state;
- the model uses the operation result in its final answer;
- the effect journal records the complete loop.

The tool returns a canary value. The final response must contain that value.
This prevents a model from passing the test with a plausible answer that did
not use the operation result.

## Run An Application Agent

After preflight succeeds, run the same agent through the public facade:

```elixir
case Jidoka.turn(MyApp.TimeAgent, "What time is it in Chicago? Use local_time.") do
  {:ok, result} ->
    IO.puts(result.content)
    IO.inspect(result.usage, label: "usage")
    IO.inspect(result.journal.results, label: "effect results")

  {:hibernate, snapshot} ->
    IO.inspect(snapshot.metadata, label: "pending review")

  {:error, reason} ->
    IO.puts(Jidoka.format_error(reason))
end
```

Use `Jidoka.turn/3` for the live check because it returns the journal, events,
usage, and snapshot data. Use `Jidoka.chat/3` when application code needs only
the final text.

## Decision Protocol

`Jidoka.Runtime.ReqLLM` currently uses a constrained JSON decision protocol.
The system prompt tells the model to return one of these shapes.

A final answer has this shape:

```json
{"type":"final","content":"answer"}
```

A single operation request has this shape:

```json
{"type":"operation","name":"local_time","arguments":{"city":"Chicago"}}
```

A parallel operation request has this shape:

```json
{
  "type": "operations",
  "operations": [
    {"name": "lookup_customer", "arguments": {"id": "C100"}},
    {"name": "lookup_order", "arguments": {"id": "O200"}}
  ]
}
```

`Jidoka.Runtime.ReqLLM.Decision` parses the provider text into
`Jidoka.Effect.LLMDecision`. The turn runner then plans effect intents. The
effect interpreter executes them through injected runtime capabilities.

Treat invalid JSON and unknown decision types as model-output errors. Do not
run an operation directly from unparsed provider text.

## Production Checks

Before you enable live traffic, verify these items:

| Check | Reason |
| --- | --- |
| Set explicit model and generation defaults | Provider defaults can change behavior and cost. |
| Set turn and provider timeouts | A provider stall must not block work without a bound. |
| Apply operation controls | Side-effecting work needs explicit policy. |
| Use safe idempotency values | Resume and retry must not repeat unsafe work. |
| Persist sessions and snapshots | In-memory state does not survive process or node loss. |
| Configure trace redaction | Prompts, tool arguments, and results can contain sensitive data. |
| Record usage and provider errors | Operators need cost and failure evidence. |
| Limit concurrency | Parallel model or operation calls can consume quota quickly. |

See [Configuration](configuration.md),
[Idempotency And Safety](idempotency-and-safety.md), and
[Tracing And Events](tracing-and-events.md) for these controls.

## Test Strategy

Use three levels of tests:

1. Unit tests inject fake `llm:` and `operations:` capabilities. They must be
   deterministic and fast.
2. Integration tests verify the DSL, operation adapters, controls, journal,
   and resume behavior without a provider.
3. A small opt-in live test verifies credentials, provider access, ReqLLM, and
   the complete tool loop.

Do not make the normal test suite depend on provider availability. A provider
failure must not hide a deterministic Jidoka regression.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| The test skips | Export `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` in the same shell. |
| Credential error | Check the key name, provider account, and ReqLLM model provider. |
| Model returns invalid JSON | Use a model that follows structured instructions and keep generation settings conservative. |
| Model returns a final answer without a tool | Check preflight output, tool descriptions, and agent instructions. |
| Operation is missing | Check that the tool is present in `preflight.prompt.operations`. |
| Operation runs but the final answer ignores it | Add a deterministic canary to the test operation result. |
| Turn hibernates | A control requires review. Inspect pending review data and resume with a valid response. |
| Request times out | Check turn timeout, ReqLLM timeout, network access, and provider status. |
| Live test is flaky | Keep it opt-in and diagnose provider behavior separately from deterministic tests. |

## Reference

- [`Jidoka.Runtime.ReqLLM`](`Jidoka.Runtime.ReqLLM`) - live LLM capability.
- [`Jidoka.Runtime.ReqLLM.Decision`](`Jidoka.Runtime.ReqLLM.Decision`) -
  decision parser.
- [`Jidoka.Effect.LLMDecision`](`Jidoka.Effect.LLMDecision`) - normalized model
  decision data.
- [`Jidoka.Runtime.EffectInterpreter`](`Jidoka.Runtime.EffectInterpreter`) -
  external effect boundary.
- [Testing And Evals](testing-and-evals.md) - deterministic test patterns.
- [Turn And Effect Contracts](turn-and-effect-contracts.md) - effect and journal
  data.
