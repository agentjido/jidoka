# Migration From V1

Jidoka V2 is a hard cut. It keeps the public module name `Jidoka`, but the
architecture is not a refactor of V1 internals.

## Vocabulary

Use the V2 vocabulary consistently:

| V1 / older term | V2 term |
| --- | --- |
| strategy / ReAct strategy | Runic turn spine |
| adapter | capability or runtime function |
| tool execution branch | operation effect |
| output | result |
| guardrail | control |
| plugin DSL | no V2 DSL equivalent; use runtime/package code |
| generated runtime module | data contract plus runtime capability |

The core loop does not use `Jido.AI.ReAct`. Jidoka models a ReAct-style flow as
turn data, Runic workflow steps, effect intents, and capability results.

## API Shape

Start with these V2 entrypoints:

- `Jidoka.agent/1` / `Jidoka.agent!/1` for programmatic specs.
- `use Jidoka.Agent` for the Spark DSL.
- `Jidoka.import/2` for JSON/YAML strings.
- `Jidoka.plan/1` / `Jidoka.plan!/1` for executable turn plans.
- `Jidoka.turn/3` for full typed results.
- `Jidoka.chat/3` for final text only.
- `Jidoka.resume/2` for hibernated snapshots.
- `Jidoka.inspect/1` and `Jidoka.preflight/3` for debugging.

Runtime work is supplied through explicit capabilities such as `llm:` and
`operations:`. Do not use `adapters:` in V2 code.

## DSL Shape

V2 keeps the DSL intentionally small:

```elixir
defmodule MyApp.Assistant do
  use Jidoka.Agent

  agent :assistant do
    model "openai:gpt-4o-mini"
    instructions "Answer tersely."
  end

  tools do
    action MyApp.LookupAction
  end

  controls do
    max_turns 8
    timeout 30_000
  end
end
```

Build back complexity in this order:

1. one agent;
2. one Jido action;
3. input/operation/output controls;
4. structured result schema;
5. session/replay/memory where the application needs durability.

Do not migrate V1 `plugin`, `skill`, or `load_path` DSL entries directly.
Jidoka V2 keeps extension-style behavior in normal Elixir code and runtime
registration rather than adding author-facing DSL.

## Versioned Contracts

Current V2 contract versions:

- import document `version: 1`;
- snapshot `schema_version: 1`;
- serialized snapshot prefix `jidoka:snapshot:v1:`;
- harness session `schema_version: 1`.

Unsupported future versions fail fast. V1 import compatibility, if needed,
should live at the edge as a translator that emits a V2 import document or
`Jidoka.Agent.Spec`. V1 terms should not leak into V2 core modules.

## What Not To Port Directly

Do not port V1 strategy callbacks, generated nested runtime modules, model
aliases, or broad provider abstraction layers directly into V2. The V2 shape is
data first:

```text
Agent.Spec
-> Turn.Plan
-> Harness
-> Runic workflow
-> Effect.Intent / Effect.Result
-> ReqLLM + Jido.Action
```

The goal is not to recreate every V1 feature. The goal is a smaller Jido-native
agent harness that is inspectable, durable, and testable.
