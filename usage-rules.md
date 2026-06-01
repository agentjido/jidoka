# Jidoka Usage Rules

Use these rules when generating code that depends on Jidoka.

## Agent Authoring

- Prefer `use Jidoka.Agent` with the Spark DSL for application-authored agents.
- Keep `agent`, `tools`, and `controls` as the only author-facing DSL sections.
- Use plain instruction strings; do not introduce dynamic system prompt DSL.
- Use `Jidoka.agent!/1` or `Jidoka.Agent.Spec.new!/1` only when constructing
  specs directly in tests or tooling.

## Runtime

- Use `Jidoka.chat/3` for a simple one-turn text result.
- Use `Jidoka.turn/3` when callers need the full `Jidoka.Turn.Result`,
  journal, state, events, or hibernation snapshot.
- Use `Jidoka.session/2` or `Jidoka.Session` for durable, multi-turn flows.
- Use injected runtime capabilities in tests instead of live provider calls.

## Tools And Operations

- Use Jido actions for local tools.
- Use `ash_resource`, `browser`, `mcp_tools`, `subagent`, `handoff`, and
  `workflow` only when those operation sources are needed.
- Mark unsafe, non-idempotent operations with `idempotency: :unsafe_once`.
- Attach operation controls to unsafe operations before release code reaches
  production.

## Data Contracts

- Model persistent structures with Zoi-backed structs.
- Preserve version fields for imports, snapshots, and sessions.
- Avoid `String.to_atom/1` on imported or runtime data.
- Keep provider clients, stores, process ids, and credentials out of
  `Jidoka.Agent.Spec`.

## Jido Relationship

- Do not delegate the core agent loop to `Jido.AI.ReAct`.
- Keep Jidoka's Runic workflow spine as the owner of model/operation turns.
- Use Jido for process hosting, actions, signals, and ecosystem integrations.
