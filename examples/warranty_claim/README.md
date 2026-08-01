# Warranty Claim

The Warranty Claim example reviews one claim from a customer statement, a
product photo, and a receipt reference. It shows the complete authoring, model,
and result-contract feature group in one business flow.

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

## Run It

Run the command demo:

```bash
mix jidoka.example warranty_claim
mix jidoka.example warranty_claim --json
```

Run the proof cases:

```bash
mix test examples/warranty_claim/test/warranty_claim_triage_test.exs --trace
```

Check all Warranty Claim surfaces:

```bash
mix jidoka.examples.check --example warranty_claim
mix jidoka.examples.check --example warranty_claim --verbose
```

Open `warranty_claim.livemd` for the executable walkthrough.

## Important Files

- `lib/agent.ex` defines the code-first agent and both Zoi schemas.
- `agent.yaml` defines the equivalent data-authored agent.
- `lib/instructions.ex` resolves the tenant policy from public context.
- `lib/scripted_llm.ex` causes deterministic retry, fallback, and repair.
- `example.exs` builds the multimodal claim and produces a safe report.
- `test/warranty_claim_triage_test.exs` is the proof authority.

For the public contracts, see these guides:

- [`guides/agent-dsl.md`](../../guides/agent-dsl.md)
- [`guides/import-json-yaml.md`](../../guides/import-json-yaml.md)
- [`guides/agent-spec-contract.md`](../../guides/agent-spec-contract.md)
- [`guides/structured-results.md`](../../guides/structured-results.md)
- [`guides/turn-and-effect-contracts.md`](../../guides/turn-and-effect-contracts.md)
