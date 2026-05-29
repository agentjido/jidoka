# Agent DSL

The V2 DSL is intentionally small. It is an authoring layer that compiles to
`Jidoka.Agent.Spec`.

## Minimal Agent

```elixir
defmodule MyApp.Assistant do
  use Jidoka.Agent

  agent :assistant
end
```

This uses default instructions and the configured default model.

## Agent Block

```elixir
agent :support_agent do
  model "openai:gpt-4o-mini"
  generation %{temperature: 0.0, max_tokens: 500}
  instructions "Answer support questions tersely."
  context Zoi.object(%{tenant_id: Zoi.string()})
end
```

Supported fields:

- `model` - any ReqLLM/LLMDB model input, such as `"openai:gpt-4o-mini"` or
  `%{provider: :openai, id: "gpt-4o-mini"}`;
- `generation` - permissive provider-facing generation defaults;
- `instructions` - system-level behavior instructions;
- `context` - optional Zoi schema for runtime context validation.

## Tools Block

```elixir
tools do
  action MyApp.LocalTime
end
```

Each action must be a Jido action or compatible module exposing `to_tool/0`.
Jidoka converts actions into `Agent.Spec.Operation` entries.

## Compiled Shape

The important boundary is the compiled spec:

```elixir
%Jidoka.Agent.Spec{
  id: "support_agent",
  model: %LLMDB.Model{},
  generation: %Jidoka.Agent.Spec.Generation{},
  context_schema: %Zoi.Schema{},
  operations: [%Jidoka.Agent.Spec.Operation{}]
}
```

Golden tests in `test/jidoka/golden/dsl_to_spec_test.exs` lock the stable
projection of this shape.

## Intentionally Absent

The current DSL does not expose memory, handoffs, workflows, sessions, approval
queues, or native provider tool-calling. Those should land after the
`Agent.Spec`, harness, and runtime contracts are stable.
