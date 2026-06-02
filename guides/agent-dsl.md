# Agent DSL

The Jidoka DSL is small. It compiles agent modules to `Jidoka.Agent.Spec`.

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
  instructions "Answer support questions tersely."
  context Zoi.object(%{tenant_id: Zoi.string()})
  result schema: Zoi.object(%{answer: Zoi.string()}), max_repairs: 1
  memory scope: :session, max_entries: 5
end
```

Supported fields:

- `model` - any ReqLLM/LLMDB model input, such as `"openai:gpt-4o-mini"` or
  `%{provider: :openai, id: "gpt-4o-mini"}`;
- `generation` - optional provider-facing generation overrides; omitted agents
  use `Jidoka.Config.default_generation/0`;
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
  ash_resource MyApp.Accounts.Customer, actions: [:read, :create]
  browser :docs, allow: ["https://docs.example.com"]
  mcp_tools endpoint: :support_mcp, prefix: "support_"
  skill MyApp.Skills.RefundPolicy
  load_path "priv/skills"
  workflow MyApp.Workflows.RefundQuote, as: :quote_refund
  subagent MyApp.EvidenceAgent, as: :collect_evidence
  handoff MyApp.BillingAgent, as: :billing_specialist
end
```

The `tools` block is authoring vocabulary for anything the model can ask
Jidoka to do. Every entry compiles to one or more `Agent.Spec.Operation`
records. The runtime still sees a small operation boundary; the DSL gives you
clear source-specific syntax.

Supported entries:

| DSL entry | Use it for | Runtime shape |
| --- | --- | --- |
| `action MyApp.Action` | One deterministic Jido/Jidoka action. | One `:action` operation. |
| `ash_resource MyApp.Resource` | AshJido-generated actions from an Ash resource. | One operation per exposed Ash action. |
| `browser :docs` | Search/read/snapshot browser capabilities backed by `jido_browser`. | `:browser` operations. |
| `mcp_tools endpoint: :id` | Tools exposed by a configured MCP endpoint. | One `:mcp` operation per discovered/static tool. |
| `skill MyApp.Skill` | Jido.AI skill instructions and any declared operations. | Skill prompt plus `:skill` operations when present. |
| `load_path "priv/skills"` | Runtime-loaded `SKILL.md` files. | Adds skill instructions from the path. |
| `workflow MyApp.Workflow` | Deterministic application workflow as one callable operation. | One `:workflow` operation. |
| `subagent MyApp.Agent` | Bounded delegation to another Jidoka agent for one task. | One `:subagent` operation. |
| `handoff MyApp.Agent` | Transfer future conversation ownership to another agent. | One `:handoff` operation. |

`action` is the smallest tool source. The module must be a Jido action or a
compatible module exposing `to_tool/0`.

```elixir
tools do
  action MyApp.LocalTime
end
```

`ash_resource` records an Ash resource source. AshJido-generated actions are
imported as `:ash_resource` operations. Use `actions:` to filter the generated
operations exposed to the model:

```elixir
tools do
  ash_resource MyApp.Accounts.User, actions: [:read, :create]
end
```

`browser` expands to constrained browser operations backed by Jido action
wrappers for the `jido_browser` read-only tools: `search_web`, `read_page`, and
`snapshot_url` in `:read_only` mode.

```elixir
tools do
  browser :docs, mode: :read_only, allow: ["https://hexdocs.pm"]
end
```

`mcp_tools` imports tools from a configured MCP endpoint. Use `prefix:` to keep
remote tool names distinct from local operation names.

```elixir
tools do
  mcp_tools endpoint: :support_mcp,
            prefix: "support_",
            tools: [%{name: "lookup_policy", description: "Look up support policy."}]
end
```

`skill` and `load_path` add Jido.AI skill context. A skill can add prompt
instructions, operation metadata, or both depending on the skill definition.

```elixir
tools do
  skill MyApp.Skills.RefundPolicy
  load_path "priv/skills"
end
```

`workflow` exposes deterministic application code as one operation. Use it when
the model should choose a business workflow, but your application owns the
workflow steps. Define the workflow in a module, then register it in
`tools do`.

```elixir
defmodule MyApp.Workflows.RefundQuote do
  use Jidoka.Workflow

  workflow do
    id :refund_quote
    input Zoi.object(%{order_id: Zoi.string()})
  end

  steps do
    function :quote, {MyApp.Refunds, :quote, 2},
      input: %{order_id: input(:order_id)}
  end

  output from(:quote)
end

tools do
  workflow MyApp.Workflows.RefundQuote,
    as: :quote_refund,
    timeout: 10_000,
    forward_context: {:only, [:tenant]},
    idempotency: :idempotent,
    result: :structured
end
```

Workflow tool options:

| Option | Default | Purpose |
| --- | --- | --- |
| `as:` | workflow id | Operation name the model sees. |
| `description:` | workflow description | Tool description. |
| `timeout:` | `30_000` | Total workflow wall-clock timeout in milliseconds. |
| `forward_context:` | `:public` | Runtime context forwarded into workflow execution. |
| `result:` | `:output` | `:output` returns raw workflow output; `:structured` wraps workflow metadata. |
| `idempotency:` | `:idempotent` | Operation safety level. Use `:unsafe_once` with an operation control. |
| `metadata:` | `%{}` | Extra operation metadata. |

For workflow module authoring, refs, step kinds, direct execution, and testing,
see [Workflows](workflows.md).

`subagent` delegates one bounded task to another Jidoka agent and returns the
child result to the parent. It does not change who owns the next user turn.
Use it when the parent should synthesize the child result and keep owning the
conversation.

```elixir
tools do
  subagent MyApp.EvidenceAgent,
    as: :collect_evidence,
    timeout: 30_000,
    result: :structured
end
```

`handoff` records that another agent should own future turns for a conversation.
The current turn still completes normally; your application reads
`Jidoka.handoff/1` to route the next message.
Use it when the next user message should be handled by a different agent.

```elixir
tools do
  handoff MyApp.BillingAgent,
    as: :billing_specialist,
    target: :auto,
    forward_context: :public
end
```

For the decision model, context rules, and testing shape for both primitives,
see [Agent Orchestration](agent-orchestration.md).

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

Input, operation, and output controls run in declaration order. Operation controls receive
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

Golden tests in `test/jidoka/golden/dsl_to_spec_test.exs` lock the projected
shape.

## Import Parity

JSON/YAML imports compile into the same `Jidoka.Agent.Spec` shape. Portable
documents stay data-only, so action modules and Zoi context schemas are named in
the document and resolved with registries. Import currently covers the data-safe
agent fields, controls, and the portable tool sources: `action`,
`ash_resource`, `browser`, and `mcp_tools`.

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
  mcp_tools:
    - endpoint: support_mcp
      prefix: support_
      tools:
        - name: lookup_policy
          description: Look up support policy.
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

## Not In The DSL Yet

The current DSL does not expose session queues, approval queues, or native
provider tool-calling. Runtime additions remain explicit Elixir code, not
agent DSL.
