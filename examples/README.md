# Jidoka Examples

Each example is one complete reference agent. It owns its agent code,
deterministic support, proof cases, README, Livebook, and optional showcase
surface.

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

All default proof cases are deterministic and offline. They use local Mock LLM
functions. They do not use provider keys, network calls, or recorded fixtures.

## Standard Layout

```text
examples/support_agent/
├── README.md
├── manifest.exs
├── example.exs
├── support_agent.livemd
├── lib/
│   ├── agent.ex
│   ├── actions/
│   └── controls/
├── support/
│   └── mock_llm.ex
└── test/
    └── controlled_tool_call_test.exs
```

The manifest declares expected scenarios, cases, capabilities, dependencies,
and user surfaces. Normal tagged ExUnit tests are the only proof authority. The
checker derives run coverage from passed case results.

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
6. Keep the Mock LLM local and deterministic.
7. Make `example.exs` return a domain result, not a capability map.
8. Keep one README and one Livebook for the complete example.
9. Add structured showcase metadata only when the example has a curated route.

There is no example generator or custom test DSL. This keeps the files clear to
a developer who already knows ExUnit.

Standalone Livebook guides stay in `examples/guides/`. They are documentation
assets and do not create capability proof.

See [PROVEN_FEATURES.md](PROVEN_FEATURES.md) for verified coverage and showcase
inventory.
