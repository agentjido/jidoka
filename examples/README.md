# Jidoka Examples

Each example is one complete reference agent. It owns its agent code, proof
cases, README, Livebook, and optional showcase surface. Reusable deterministic
support stays in `examples/_support/shared/`.

Example code is not part of the production package build. The checker loads or
compiles only the selected non-production surfaces.

## Start Here

List and run examples:

```bash
mix jidoka.example --list
mix jidoka.example support_agent
```

Run the complete check for one example while you work:

```bash
mix jidoka.examples.check --example support_agent
mix jidoka.examples.check --example support_agent --verbose
```

Run all proof and documentation surfaces before you publish a change:

```bash
mix jidoka.examples.check
```

All default proof cases are deterministic and offline. They use the shared Mock
LLM helper. They do not use provider keys, network calls, or recorded fixtures.

## Standard Layout

```text
examples/
├── _support/
│   └── shared/
│       └── mock_llm.ex
└── support_agent/
    ├── README.md
    ├── manifest.yaml
    ├── example.exs
    ├── support_agent.livemd
    ├── lib/
    │   ├── agent.ex
    │   ├── actions/
    │   └── controls/
    └── test/
        └── controlled_tool_call_test.exs
```

The YAML manifest declares expected scenarios, cases, capabilities,
dependencies, and user surfaces. It is data and does not execute code. Normal
tagged ExUnit tests are the only proof authority. The checker derives run
coverage from passed case results.

The runner is only a useful command demonstration. The Livebook is an
executable walkthrough. The showcase is an optional interactive surface. None
of these surfaces can create capability proof.

## Add An Example

Use `support_agent` as the reference. Keep these rules:

1. Use one causal Jidoka behavior for each scenario.
2. Put deterministic paths and edge cases under that scenario.
3. Give each manifest case exactly one ExUnit test with `proof_case` and
   `proof_example` tags.
4. Declare stable Jidoka guarantees under `proves`.
5. Declare required capabilities and components under `uses`.
6. Use or extend the shared Mock LLM helper. Keep it deterministic.
7. Make `example.exs` return a domain result, not a capability map.
8. Keep one README and one Livebook for the complete example.
9. Add structured showcase metadata only when the example has a curated route.

There is no example generator or custom test DSL. This keeps the files clear to
a developer who already knows ExUnit.

Standalone Livebook guides stay in `examples/guides/`. They are documentation
assets and do not create capability proof.

See [PROVEN_FEATURES.md](PROVEN_FEATURES.md) for verified coverage and showcase
inventory.
