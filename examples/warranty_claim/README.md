# Warranty Claim

## Purpose

The Warranty Claim example reviews one claim from a customer statement, a
product photo, and a receipt reference. It shows the complete authoring, model,
and result-contract feature group in one business flow.

## Features

The example proves these behaviors:

- The Elixir DSL and YAML document compile to the same semantic agent spec.
- A typed public context selects the tenant and plan instructions.
- Typed text, image, and document parts enter the model prompt.
- A transient primary-model failure retries once and then uses a fallback.
- An invalid confidence value causes one bounded result-repair pass.
- The final value conforms to the warranty result schema.
- The response includes typed text and document parts.
- Public reports show media metadata, but do not show media bytes or file IDs.

The scripted model makes the failure and repair paths repeatable. It does not
use a provider key, network request, or recorded provider response.

## Read It In This Order

1. `lib/agent.ex` - the code-first context and result contracts.
2. `agent.yaml` - the equivalent data-defined agent.
3. `lib/instructions.ex` - request-time tenant policy.
4. `lib/scenario.ex` - media input and model-policy wiring.
5. `test/warranty_claim_triage_test.exs` - application behavior and runtime
   guarantees.
6. `warranty_claim.livemd` - the guided contract walkthrough.

The agent, YAML definition, schemas, and instruction provider are application
patterns. `ScriptedLLM`, `scenario.ex`, `example.exs`, the manifest, and the
tests are deterministic demo code. A production application supplies real
provider credentials and keeps the same model-policy and result contracts.

## Run It

Run the command demo:

```bash
mix run examples/warranty_claim/example.exs
mix test --only example:warranty_claim
```

Run the scenario tests:

```bash
mix test examples/warranty_claim/test/warranty_claim_triage_test.exs --trace
```

Run one feature through its native ExUnit tag:

```bash
mix test --only structured_results
```

Open `warranty_claim.livemd` for the executable walkthrough.

## Important Files

- `lib/agent.ex` defines the code-first agent and both Zoi schemas.
- `agent.yaml` defines the equivalent data-authored agent.
- `lib/instructions.ex` resolves the tenant policy from public context.
- `lib/scripted_llm.ex` causes deterministic retry, fallback, and repair.
- `lib/scenario.ex` builds the multimodal claim and produces a safe report.
- `example.exs` is the small command entry point.
- `test/warranty_claim_triage_test.exs` is the behavior authority.

## Expected Result

The command prints one repaired, schema-valid warranty decision. It also shows
authoring parity, fallback model use, and the number of result-repair passes.

## Next Guide

For the public contracts, read these guides:

- [`guides/agent-dsl.md`](../../guides/agent-dsl.md)
- [`guides/import-json-yaml.md`](../../guides/import-json-yaml.md)
- [`guides/agent-spec-contract.md`](../../guides/agent-spec-contract.md)
- [`guides/structured-results.md`](../../guides/structured-results.md)
- [`guides/turn-and-effect-contracts.md`](../../guides/turn-and-effect-contracts.md)
