# Jidoka Examples

Each folder under `examples/` is one complete reference agent. It owns the
agent code, manifest, proof tests, command runner, README, and Livebook. Example
modules are not compiled into the production library.

Reusable proof infrastructure and deterministic helpers stay in `_support/`.
Standalone documentation Livebooks stay in `guides/livebooks/`.

## Run An Example

```bash
mix jidoka.example --list
mix jidoka.example support_agent
mix jidoka.example warranty_claim
mix jidoka.example durable_refund
mix jidoka.examples.check --example support_agent
mix jidoka.examples.check --example warranty_claim
mix jidoka.examples.check --example durable_refund
mix jidoka.examples.check
```

All default proof cases are deterministic and offline. They do not use provider
keys, network calls, or recorded model fixtures.

## Example Layout

```text
examples/<name>/
├── README.md
├── manifest.yaml
├── example.exs
├── <name>.livemd
├── lib/
│   ├── agent.ex
│   ├── actions/
│   └── controls/
└── test/
    └── <scenario>_test.exs
```

The YAML manifest declares scenarios, cases, expected capabilities, and public
surfaces. Tagged ExUnit tests are the only capability-proof authority. The
runner demonstrates normal use. The Livebook is an executable walkthrough.
The optional Showcase surface provides an interactive UI.

Use the Support Agent as the reference for a controlled tool flow. Use the
Warranty Claim example as the reference for agent authoring, model policy,
structured results, and multimodal content. Keep one causal Jidoka behavior in
each proof case. Use the Durable Refund Agent as the reference for asynchronous
execution, cancellation, execution limits, durable recovery, and safe forks.
Put stable guarantees under `proves` and required capabilities or components
under `uses`.

A complete proof run writes verified coverage to the ignored local file
`docs/PROVEN_FEATURES.md`.
