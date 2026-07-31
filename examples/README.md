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
mix jidoka.examples.check --example support_agent
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

Use the Support Agent as the reference for a new example. Keep one causal
Jidoka behavior in each scenario. Put stable guarantees under `proves` and
required capabilities or components under `uses`.

See [PROVEN_FEATURES.md](PROVEN_FEATURES.md) for coverage verified by the latest
complete proof run.
