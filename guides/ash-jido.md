# AshJido Resources

This guide explains how to expose an Ash resource as a source of model-callable
Jidoka operations through the `ash_resource` DSL entity. AshJido generates one
action module per Ash action, and Jidoka picks those up as ordinary `:ash_resource`
operations on the agent spec. By the end you will be able to register a resource,
filter which actions reach the model, understand the safety implications of
exposing `:create`, `:update`, and `:destroy`, and import the same shape from
JSON or YAML.

## When To Use This

- Use this guide when an Ash resource is the source of truth for data your agent
  should read or mutate, and you want each Ash action to surface as one tool.
- Use this guide when you want generated parameter schemas and consistent
  errors across read, create, update, and destroy paths without writing one
  `Jidoka.Action` per Ash action.
- Do **not** use this guide for one-off business logic that does not belong on
  the resource. Reach for a `Jidoka.Workflow` instead. See
  [Skill, Workflow, And Subagent Tools](skill-workflow-subagent-tools.md).

## Prerequisites

- A working Jidoka DSL agent. See [Getting Started](getting-started.md).
- An Ash domain and at least one resource that includes the AshJido extension,
  for example:

```elixir
defmodule MyApp.Support.Ticket do
  use Ash.Resource,
    domain: MyApp.Support,
    extensions: [AshJido]

  ash_jido do
    expose [:read, :create]
  end

  actions do
    defaults [:read, :create, :update]
  end
end
```

- `AshJido.Tools` is available at compile time. Jidoka resolves it through
  `Application.get_env(:jidoka, :ash_jido_tools, AshJido.Tools)` so tests may
  inject a double.

## Quick Example

The smallest agent backed by an Ash resource is one resource plus one DSL
module.

```elixir
defmodule MyApp.SupportAgent do
  use Jidoka.Agent

  agent :support_agent do
    model "openai:gpt-4o-mini"
    instructions "Look up tickets before answering. Use create_ticket only when asked."
  end

  tools do
    ash_resource MyApp.Support.Ticket, actions: [:read, :create]
  end
end
```

That spec exposes one operation per filtered Ash action. The model sees
`read_ticket` and `create_ticket`; the resource owns persistence and
authorization. No process is started by this declaration.

## Concepts

```diagram
╭───────────────────────────╮
│ Ash resource              │
│  + AshJido extension      │
╰─────────────┬─────────────╯
              │ AshJido.Tools.actions/1
              ▼
╭───────────────────────────╮     ╭──────────────────────────╮
│ Generated Jido action     │────▶│ Jidoka.Agent.Spec.Operation │
│ modules (one per action)  │     │ metadata.source = "ash_resource" │
╰─────────────┬─────────────╯     ╰──────────────────────────╯
              │ JidoActions.operations/2
              ▼
╭───────────────────────────╮
│ Jidoka turn loop          │
│ same effect path as       │
│ deterministic actions     │
╰───────────────────────────╯
```

Three concepts cover this integration:

1. **AshJido generation.** AshJido inspects the resource's exposed actions and
   emits one Jido action module per action. Each module exports `to_tool/0` and
   `run/2`, which is everything Jidoka needs.
2. **Filtering.** The DSL `actions: [...]` list limits which generated modules
   become operations. The default empty list means "every generated action".
3. **Metadata tagging.** Each compiled operation carries `metadata.source =
   "ash_resource"` and `metadata.resource = inspect(MyApp.Support.Ticket)`. The
   spec also records a `tool_sources` entry summarizing what was registered.

### Security / Trust Boundaries

- The DSL trusts the resource module. Never derive `ash_resource MyResource`
  from user input; gate registrations behind an internal allowlist.
- `actions:` is the only place in the DSL that limits *which* actions reach the
  model. Treat it as the production allowlist for write actions. A bare
  `ash_resource MyResource` exposes every AshJido-generated action.
- AshJido does not bypass resource policies. Authorization runs through Ash as
  normal; the runtime context propagated to the action carries actor and tenant.
- Generated parameter schemas come from the resource. If the resource has a
  sensitive attribute that should not be exposed, mark it private at the
  resource level, not at the agent level.
- The runtime never serializes credentials into `metadata`. Resource modules,
  resource names, and action names are the only identifiers surfaced.

## How To

### Step 1: Register A Read-Only Resource

Read paths are the safest starting point. They are pure with respect to your
data and idempotent for caching.

```elixir
defmodule MyApp.ReadAgent do
  use Jidoka.Agent

  agent :read_agent do
    instructions "Use read_ticket when asked about ticket status."
  end

  tools do
    ash_resource MyApp.Support.Ticket, actions: [:read]
  end
end
```

Confirm with `Jidoka.inspect(MyApp.ReadAgent)`. The `operations` list should
contain one `:ash_resource` operation per filtered action.

### Step 2: Add A Mutating Action With An Approval Control

When you allow write actions, pair them with a control that gates execution.

```elixir
defmodule MyApp.RequireApproval do
  use Jidoka.Control, name: "require_ash_approval"

  @impl true
  def call(_operation), do: {:interrupt, :approval_required}
end

defmodule MyApp.SupportAgent do
  use Jidoka.Agent

  agent :support_agent do
    instructions "Use create_ticket only after the user confirms."
  end

  tools do
    ash_resource MyApp.Support.Ticket, actions: [:read, :create]
  end

  controls do
    operation MyApp.RequireApproval, when: [source: "ash_resource", name: "create_ticket"]
  end
end
```

Controls match against `Jidoka.Agent.Spec.Operation` metadata, which is why
`source: "ash_resource"` is a stable filter.

### Step 3: Pass A Tenant And Actor Through Context

Ash needs an actor and tenant to enforce policies. Both flow through the turn
context.

```elixir
{:ok, result} =
  Jidoka.turn(MyApp.SupportAgent, "Open ticket for refund of order 42.",
    context: %{actor: current_user, tenant: tenant_id},
    llm: llm
  )
```

The `:ash_resource` capability forwards the public context (everything that is
not stripped by a `forward_context: {:except, ...}` policy) into the generated
Jido action's `context` argument.

### Step 4: Import The Same Agent From YAML

The DSL is one authoring path. JSON and YAML imports compile into the same
spec, but every module reference must be resolved through a registry the caller
supplies.

```elixir
yaml = """
agent:
  id: support_agent
  model: openai:gpt-4o-mini
  instructions: Look up tickets before answering.
tools:
  ash_resources:
    - resource: my_app.support.ticket
      actions: [read, create]
"""

{:ok, spec} =
  Jidoka.import(yaml,
    ash_resources: %{"my_app.support.ticket" => MyApp.Support.Ticket}
  )
```

Imports never call `String.to_atom/1` on input. Unknown resource names produce
an `Jidoka.Error.Invalid` with the offending key.

### Step 5: Inspect The Operation Metadata

The spec metadata records exactly what was registered, including whether
expansion succeeded.

```elixir
spec = MyApp.SupportAgent.spec()

spec.metadata["tool_sources"]
#=> [%{"source" => "ash_resource", "resource" => "MyApp.Support.Ticket",
#      "actions" => ["read", "create"], "expanded?" => true}]
```

`expanded?: false` means AshJido did not return generated modules. The most
common cause is a missing extension on the resource.

## Common Patterns

- **Pin `actions:` even for reads.** An explicit list makes future audits
  cheap and prevents a new action from silently reaching the model.
- **Keep write actions behind a control.** Use `operation MyControl, when: [source: "ash_resource", name: "create_ticket"]`
  to require approval, dry runs, or rate limiting.
- **Use separate agents for read and write.** A `ReadAgent` exposing only
  `:read` and a `WriteAgent` exposing `:create`/`:update` is easier to reason
  about than one agent with both.
- **Surface generated descriptions.** AshJido derives the action description
  from the resource. Improve it on the resource, not at the agent layer.

## Testing

Tests can drive ash_resource agents with the same deterministic capabilities
used elsewhere. The Ash action is real; only the LLM is faked.

```elixir
defmodule MyApp.ReadAgentTest do
  use ExUnit.Case, async: true

  test "agent calls read_ticket" do
    llm = fn _intent, journal ->
      llm_calls =
        Enum.count(journal.results, fn {_id, r} -> r.kind == :llm end)

      case llm_calls do
        0 ->
          {:ok, %{type: :operation, name: "read_ticket", arguments: %{"id" => "T-1"}}}

        1 ->
          {:ok, %{type: :final, content: "Ticket T-1 is open."}}
      end
    end

    assert {:ok, result} =
             Jidoka.turn(MyApp.ReadAgent, "Status of T-1?", llm: llm)

    assert result.content =~ "T-1"
  end
end
```

For unit tests of the registration step itself, swap `AshJido.Tools` with a
double:

```elixir
defmodule MyApp.FakeAshTools do
  def actions(MyApp.Support.Ticket), do: [MyApp.Support.Generated.Read]
end

Application.put_env(:jidoka, :ash_jido_tools, MyApp.FakeAshTools)
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `expanded?: false` in `tool_sources` | AshJido did not generate any actions; usually the extension is missing on the resource. | Add `extensions: [AshJido]` and at least one exposed action. |
| `{:error, {:duplicate_operation_source_name, name}}` | Two registrations expose the same action name. | Make `actions:` lists disjoint or rename through a custom Ash action name. |
| `Ash.Error.Forbidden` from a turn | The runtime context did not carry an actor or tenant. | Pass `context: %{actor: ..., tenant: ...}` to `Jidoka.turn/3`. |
| `to_tool/0` rescued internally and the action is missing | AshJido could not project the action. | Inspect with `AshJido.Tools.tools(MyApp.Support.Ticket)` and resolve the generation error on the resource. |
| Import fails with `:invalid` on `ash_resources` | A name was not in the supplied registry. | Add the name under `ash_resources: %{...}` in the `Jidoka.import/2` call. |

## Reference

Key modules touched in this guide:

- [`Jidoka.Agent`](`Jidoka.Agent`) - DSL entry point that hosts the `tools do
  ash_resource ... end` entity.
- Tool DSL section - DSL
  schema for `ash_resource`, including `:actions`, `:description`,
  `:idempotency`, and `:metadata` options.
- [`Jidoka.Agent.Spec.Operation`](`Jidoka.Agent.Spec.Operation`) - the compiled
  operation entry tagged with `metadata.source = "ash_resource"`.
- [`AshJido.Tools`](`AshJido.Tools`) - generator helper Jidoka uses to discover
  action modules for a resource.

## Related Guides

- [Getting Started](getting-started.md) - the smallest DSL agent end to end.
- [Skill, Workflow, And Subagent Tools](skill-workflow-subagent-tools.md) -
  the three other DSL-level operation sources that compile through
  `Jidoka.Operation.Source`.
- [Controls](controls.md) - how to gate `create`, `update`, and `destroy`
  operations with approvals or dry runs.
- [Browser Tools](browser-tools.md) - a sibling source for constrained
  external reads.
- [MCP Tools](mcp-tools.md) - a sibling source for remote MCP servers.
