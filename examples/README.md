# Jidoka Examples

Each folder under `examples/` is one complete deterministic reference agent.
It owns the agent code, scenario code, metadata, ExUnit tests, command runner,
README, and Livebook. Example modules compile only in the test environment and
are not part of the production Jidoka application.

## Start Here

If you have not used Jidoka, start with
[`guides/getting-started.md`](../guides/getting-started.md). It teaches the
smallest agent and the normal `chat/3` API. Then use these examples in order:

1. **Support Agent** - learn one complete tool call and approval flow.
2. **Warranty Claim** - add typed context, model policy, media, and results.
3. **Durable Refund** - add asynchronous and durable runtime behavior.

The agent, action, control, instruction, and YAML files are application
patterns. The scenario, scripted model, command runner, test, and manifest
files make the examples deterministic and are not required in production.

`ScriptedLLM` is a model test double. It returns known decisions without a
provider or network request. Production code normally uses the model declared
by the agent or supplies a runtime model policy; it does not pass
`ScriptedLLM` as `:llm`.

The small `loader.exs` file only starts examples outside the test environment.
It keeps the Spark compile order out of each command runner and Livebook. Mix
compiles the same source files normally when it runs the example tests.

## Run Examples

```bash
mix run examples/support_agent/example.exs
mix run examples/warranty_claim/example.exs
mix run examples/durable_refund/example.exs
```

## Test Examples

The root `mix test` command runs the example tests with the rest of the suite.
Use standard ExUnit tags for focused runs:

```bash
mix test --only example:support_agent
mix test --only tool_calling
mix test examples/durable_refund/test/execution_and_continuation_test.exs --trace
```

The YAML manifest lists the aggregate features for an example. Tags on each
ExUnit test show the exact features that the scenario verifies.

Run all Livebooks without their standalone `Mix.install` calls:

```bash
mix run scripts/check_livebooks.exs -- --project examples/*/*.livemd guides/livebooks/*.livemd
```

## Example Layout

```text
examples/<name>/
├── README.md
├── manifest.yaml
├── example.exs
├── <name>.livemd
├── lib/
│   ├── agent.ex
│   ├── scenario.ex
│   ├── scripted_llm.ex
│   ├── actions/
│   ├── controls/
│   └── scenarios/       # optional for examples with several workflows
└── test/
    └── <scenario>_test.exs
```

## Choose An Example

| Example | Level | Read it to learn |
| --- | --- | --- |
| Support Agent | Intermediate | Tools, observations, controls, approval, and resume |
| Warranty Claim | Advanced | Data authoring, typed results, media, fallback, and repair |
| Durable Refund | Expert | Async work, streams, limits, recovery, and forks |

Use the Support Agent for a controlled tool flow. Use the Warranty Claim for
agent authoring, model policy, structured results, and multimodal content. Use
the Durable Refund Agent for asynchronous execution, cancellation, execution
limits, durable recovery, and safe session forks.
