# Jidoka Examples

Each folder under `examples/` is one complete deterministic reference agent.
It owns the agent code, scenario code, metadata, ExUnit tests, command runner,
README, and Livebook. Example modules compile only in the test environment and
are not part of the production Jidoka application.

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
│   └── controls/
└── test/
    └── <scenario>_test.exs
```

Use the Support Agent for a controlled tool flow. Use the Warranty Claim for
agent authoring, model policy, structured results, and multimodal content. Use
the Durable Refund Agent for asynchronous execution, cancellation, execution
limits, durable recovery, and safe session forks.
