# Jidoka Examples

These examples are small agent applications. Each scenario keeps its agent
code, deterministic support code, test, and Livebook together.

Examples are not part of `elixirc_paths`. Jidoka loads them only when an example,
test, or Livebook asks for them.

List the available examples:

```bash
mix jidoka.example --list
```

Run one deterministic example:

```bash
mix jidoka.example support_agent
```

Run all deterministic examples:

```bash
mix jidoka.example --all
```

## File Layout

```text
examples/support_agent/
├── README.md
├── manifest.exs
├── example.exs
├── support_agent_test.exs
├── support_agent.livemd
├── lib/
│   ├── agent.ex
│   ├── actions/
│   └── controls/
└── support/
    └── mock_llm.ex
```

Each `manifest.exs` gives its scenario an explicit module load order and proof
files. `examples/registry.exs` discovers these manifests. The root package does
not compile example code.

The Phoenix app in `showcase/` compiles the `lib/` folder for each scenario.
It uses the same agent code as the command, test, and Livebook.

Standalone Livebook guides live in `examples/guides/`. A guide can move into a
scenario folder when it becomes a dedicated agent.

Run the deterministic Livebook code cells:

```bash
for notebook in examples/guides/*.livemd examples/support_agent/*.livemd; do
  elixir scripts/check_livebook.exs "$notebook"
done
```

The approval walkthrough in `livebook/` is a live-provider guide. It is not part
of this deterministic check.

See [PROVEN_FEATURES.md](PROVEN_FEATURES.md) for the current proof matrix and
the limits of each check.
