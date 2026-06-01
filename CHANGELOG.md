# Changelog

## 1.0.0-beta.1

This beta locks the minimal V2 DSL and closes import/control parity for the
current package surface.

Highlights:

- The public DSL remains limited to `agent`, `tools`, and `controls`.
- `instructions` stays string-only; runtime additions stay explicit Elixir code, not DSL.
- JSON/YAML imports now support `action`, `ash_resource`, `browser`, and
  `mcp_tools` tool sources through data-safe registries.
- Operation controls can match by kind, name, source, idempotency, and metadata.
- Hard Hex dependencies are used for the Jido ecosystem packages.

## 0.1.0-v2 Milestone

This is the first Jidoka V2 package baseline under the public `Jidoka`
namespace.

Highlights:

- Spark DSL agents compile into `Jidoka.Agent.Spec`.
- JSON/YAML imports compile into the same spec contract through
  `Jidoka.import/2`.
- ReqLLM/LLMDB model normalization replaces model aliases.
- Jido actions are exposed as model-callable operations.
- The Runic turn spine executes the ReAct-style model/operation loop without
  using `Jido.AI.ReAct`.
- `Jidoka.Harness` owns turn execution, resume, sessions, stores, replay, and
  memory recall/write boundaries.
- Operation idempotency, unsafe-operation controls, human approval interrupts,
  structured results, result repair, memory, trace sinks, inspection, and eval
  cases are covered by data contracts and tests.
- Snapshot, session, and import documents have explicit version boundaries.

Quality gate for this milestone:

- `mix format --check-formatted`
- `mix test`
- `mix test --cover`
- `mix compile --warnings-as-errors --force`
- `mix xref graph --format cycles --label compile-connected`
- `mix dialyzer`
- `mix hex.build`
- `mix test --include live test/jidoka/live_req_llm_test.exs`
