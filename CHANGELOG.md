# Changelog

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
- `mix xref graph --format cycles --label compile`
- `mix dialyzer`
- `mix test --include live test/jidoka/live_req_llm_test.exs`
