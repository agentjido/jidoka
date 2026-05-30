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

## Controls Block

Controls describe policy at explicit turn boundaries:

- `input` runs before the first model call;
- `operation` describes policy around model-callable work;
- `result` runs before the final answer is returned;
- `max_turns` and `timeout` bound the turn loop.

```elixir
defmodule MyApp.NoSecrets do
  use Jidoka.Control, name: "no_secrets"

  @impl true
  def call(%{input: input}) do
    if String.contains?(input, "secret"), do: {:block, :secret_input}, else: :cont
  end
end

defmodule MyApp.RequireApproval do
  use Jidoka.Control, name: "require_approval"

  @impl true
  def call(_operation), do: :cont
end

defmodule MyApp.SafeReply do
  use Jidoka.Control, name: "safe_reply"

  @impl true
  def call(_result), do: :cont
end

controls do
  max_turns 8
  timeout 30_000

  input MyApp.NoSecrets

  operation MyApp.RequireApproval,
    when: [kind: :action, name: :local_time]

  result MyApp.SafeReply
end
```

Input and result controls run in declaration order. Operation controls compile
into `Agent.Spec.Controls`; runtime approval, blocking, and interrupt execution
for operations remain follow-up work.

## Compiled Shape

The important boundary is the compiled spec:

```elixir
%Jidoka.Agent.Spec{
  id: "support_agent",
  model: %LLMDB.Model{},
  generation: %Jidoka.Agent.Spec.Generation{},
  context_schema: %Zoi.Schema{},
  operations: [%Jidoka.Agent.Spec.Operation{}],
  controls: %Jidoka.Agent.Spec.Controls{}
}
```

Golden tests in `test/jidoka/golden/dsl_to_spec_test.exs` lock the stable
projection of this shape.

## Import Parity

JSON/YAML imports compile into the same `Jidoka.Agent.Spec` shape. Portable
documents stay data-only, so action modules and Zoi context schemas are named in
the document and resolved with registries:

```yaml
agent:
  id: support_agent
  model: openai:gpt-4o-mini
  instructions: Answer support questions tersely.
  context:
    ref: support_context
tools:
  actions:
    - local_time
controls:
  max_turns: 8
  timeout: 30000
  inputs:
    - control: no_secrets
  operations:
    - control: require_approval
      when:
        kind: action
        name: local_time
  results:
    - control: safe_reply
```

```elixir
yaml = """
agent:
  id: support_agent
  model: openai:gpt-4o-mini
  instructions: Answer support questions tersely.
  context:
    ref: support_context
tools:
  actions:
    - local_time
controls:
  max_turns: 8
  timeout: 30000
  inputs:
    - control: no_secrets
  operations:
    - control: require_approval
      when:
        kind: action
        name: local_time
  results:
    - control: safe_reply
"""

{:ok, spec} =
  Jidoka.import(yaml,
    registries: %{
      actions: %{"local_time" => MyApp.LocalTime},
      controls: %{
        "no_secrets" => MyApp.NoSecrets,
        "require_approval" => MyApp.RequireApproval,
        "safe_reply" => MyApp.SafeReply
      },
      context_schemas: %{"support_context" => Zoi.object(%{tenant_id: Zoi.string()})}
    }
  )
```

## Intentionally Absent

The current DSL does not expose memory, handoffs, workflows, sessions, approval
queues, operation-control runtime execution, or native provider tool-calling.
Those should land after the `Agent.Spec`, harness, and runtime contracts are
stable.
