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
  result schema: Zoi.object(%{answer: Zoi.string()}), max_repairs: 1
  memory scope: :session, max_entries: 5
end
```

Supported fields:

- `model` - any ReqLLM/LLMDB model input, such as `"openai:gpt-4o-mini"` or
  `%{provider: :openai, id: "gpt-4o-mini"}`;
- `generation` - permissive provider-facing generation defaults;
- `instructions` - system-level behavior instructions;
- `context` - optional Zoi schema for runtime context validation;
- `result` - optional Zoi schema or `Jidoka.Agent.Spec.Result` data for
  structured app-facing turn results;
- `memory` - optional memory policy data, or `true` for defaults.

When `result` is declared, models still return final assistant text, but the
runtime also validates the final structured value and exposes it as
`Jidoka.Turn.Result.value`. Invalid values trigger a bounded repair loop using
`max_repairs`; after the bound is exhausted, the turn fails with a result-phase
error.

## Tools Block

```elixir
tools do
  action MyApp.LocalTime
  browser :docs, allow: ["https://docs.example.com"]
  catalog :support_ops, via: :connect, providers: [:github], max_results: 8
end
```

Each action must be a Jido action or compatible module exposing `to_tool/0`.
Jidoka converts actions into `Agent.Spec.Operation` entries.

The `tools` block is authoring vocabulary. Internally these entries normalize
to model-callable operations:

- `action MyApp.Action` uses the built-in Jido action runtime.
- `ash_resource MyApp.Resource` records an Ash resource source. AshJido
  generated actions are imported as `:ash_resource` operations.
  `actions:` filters the generated AshJido actions exposed to the model:

  ```elixir
  tools do
    ash_resource MyApp.Accounts.User, actions: [:read, :create]
  end
  ```

- `browser :docs` expands to constrained `:browser` operations backed by
  Jido action wrappers for the `jido_browser` read-only tools: `search_web`,
  `read_page`, and `snapshot_url` in `:read_only` mode.
- `catalog :support_ops` publishes a constrained `:catalog` lookup operation
  such as `catalog_support_ops`. By default it searches the Jido Discovery
  action catalog and returns matching action metadata; it does not execute
  discovered actions.

## Controls Block

Controls describe policy at explicit turn boundaries:

- `input` runs before the first model call;
- `operation` describes policy around model-callable work;
- `output` runs before the final answer is returned;
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
  def call(%Jidoka.Runtime.Controls.OperationContext{} = operation) do
    if operation.operation == "local_time" do
      {:interrupt, :approval_required}
    else
      :cont
    end
  end
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

  output MyApp.SafeReply
end
```

Input, operation, and output controls run in declaration order at their
respective runtime boundaries. Operation controls receive
`Jidoka.Runtime.Controls.OperationContext` data and may return `:cont`,
`{:block, reason}`, `{:interrupt, reason}`, or `{:error, reason}`.

An operation interrupt hibernates the turn with a `:review` cursor and a
`Jidoka.Review.Request` in `snapshot.metadata["pending_review"]`.

See [Controls](controls.md) for approval, limit, and testing examples.

## Compiled Shape

The important boundary is the compiled spec:

```elixir
%Jidoka.Agent.Spec{
  id: "support_agent",
  model: %LLMDB.Model{},
  generation: %Jidoka.Agent.Spec.Generation{},
  context_schema: %Zoi.Schema{},
  result: %Jidoka.Agent.Spec.Result{},
  operations: [%Jidoka.Agent.Spec.Operation{}],
  controls: %Jidoka.Agent.Spec.Controls{}
}
```

Golden tests in `test/jidoka/golden/dsl_to_spec_test.exs` lock the stable
projection of this shape.

## Import Parity

JSON/YAML imports compile into the same `Jidoka.Agent.Spec` shape. Portable
documents stay data-only, so action modules and Zoi context schemas are named in
the document and resolved with registries. The import surface mirrors the
current minimal DSL: `agent`, `tools`, and `controls`.

```yaml
agent:
  id: support_agent
  model: openai:gpt-4o-mini
  instructions: Answer support questions tersely.
  context:
    ref: support_context
  result:
    ref: support_result
    max_repairs: 1
tools:
  actions:
    - local_time
  ash_resources:
    - ref: account_resource
      actions:
        - read_account
  browsers:
    - name: docs
      mode: search
      allow:
        - docs.example.com
  catalogs:
    - name: support_ops
      providers:
        - support
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
  outputs:
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
  result:
    ref: support_result
    max_repairs: 1
tools:
  actions:
    - local_time
  browsers:
    - name: docs
      mode: search
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
  outputs:
    - control: safe_reply
"""

{:ok, spec} =
  Jidoka.import(yaml,
    registries: %{
      actions: %{"local_time" => MyApp.LocalTime},
      ash_resources: %{"account_resource" => MyApp.AccountResource},
      controls: %{
        "no_secrets" => MyApp.NoSecrets,
        "require_approval" => MyApp.RequireApproval,
        "safe_reply" => MyApp.SafeReply
      },
      context_schemas: %{"support_context" => Zoi.object(%{tenant_id: Zoi.string()})},
      result_schemas: %{"support_result" => Zoi.object(%{answer: Zoi.string()})}
    }
  )
```

String refs are resolved only through explicit registries; imports do not create
atoms or modules from untrusted input.

## Intentionally Absent

The current DSL does not expose handoffs, workflows, session queues, approval
queues, extensions, or native provider tool-calling. Runtime extensions remain
plain Elixir modules registered by package/application code, not author-facing
DSL.
