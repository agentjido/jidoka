# Integration Surfaces

The README stays focused on the core agent path: agents, sessions, context,
results, actions, controls, runtime memory/compaction, schedules, delegation,
and runtime ownership. This guide collects the integration surfaces that connect
Jidoka agents to larger application and tooling boundaries.

Use these features when the agent needs integrations that are broader than one
hand-written action module.

In this guide, `capabilities` appears only as an imported JSON/YAML field name.
The Elixir DSL authoring surface is `agent`, `tools`, and `controls`.

## Tool Adapters

Integration adapters live in an agent `tools` block because they expand into
model-callable operations or operation-adjacent prompt/tool behavior. Keep the
block small and explicit; broad service catalogs should be filtered before they
reach the prompt. The old `capabilities` block is no longer accepted by the
Elixir agent DSL.

```elixir
defmodule MyApp.SupportAgent do
  use Jidoka.Agent

  agent :support_agent do
    model :fast
    instructions "Help support agents work through customer tickets."
  end

  tools do
    ash_resource MyApp.Accounts.User
    web :read_only
    mcp_tools endpoint: :github, prefix: "github_"
    skill MyApp.Skills.SupportPolicy
    load_path "priv/jidoka/skills"
    plugin MyApp.Jidoka.SupportPlugin
  end
end
```

### Ash Resources

`ash_resource MyApp.Resource` imports generated AshJido actions for an Ash
resource. The resource must be a real Ash resource, must declare an Ash domain,
and must expose AshJido actions. Jidoka validates that all declared Ash
resources belong to the same domain and that generated tool names do not
collide.

Ash resource tools require an actor at runtime. Pass it through `context:`:

```elixir
Jidoka.chat(session, "Find recent account activity.",
  context: %{actor: current_user}
)
```

If the context does not include the required actor or the domain conflicts with
the resource domain, Jidoka returns a normalized context error before the tool
call proceeds.

### MCP Tools

`mcp_tools` syncs tools from a configured or runtime MCP endpoint into the
running agent. Endpoints can come from `:jido_mcp` configuration, runtime
registration through `Jidoka.MCP.register_endpoint/2`, or inline endpoint
options on the DSL entry.

```elixir
tools do
  mcp_tools endpoint: :github, prefix: "github_"
end
```

Use a prefix when the remote catalog may overlap with local actions. Jidoka
tracks MCP sync status in inspection metadata and normalizes endpoint,
capability, and runtime errors through `Jidoka.format_error/1`.

Automatic MCP sync during an agent turn is fail-open by default. If a configured
endpoint cannot sync, Jidoka records the failure in request inspection metadata
and emits an MCP trace error event when trace correlation is available, but the
turn continues with the tools that were already registered. Mark an endpoint
`required: true` when the request should fail instead:

```elixir
tools do
  mcp_tools endpoint: :github, prefix: "github_", required: true
end
```

Call `Jidoka.MCP.sync_tools/2` directly when the application wants explicit
`{:ok, result}` or `{:error, reason}` handling before a turn starts.

Inline endpoint declarations are useful for controlled local tools:

```elixir
tools do
  mcp_tools endpoint: :local_fs,
            prefix: "fs_",
            transport: {:stdio, command: "my-mcp-server"},
            client_info: %{name: "my_app", version: "1.0.0"}
end
```

### Web Tools

`web :search` exposes public web search. `web :read_only` exposes search,
read-page, and snapshot-url tools. Jidoka intentionally keeps this surface
read-only: it does not expose click, type, JavaScript evaluation, tab/session
state, or arbitrary browser control through the agent DSL.

```elixir
tools do
  web :read_only
end
```

Declare at most one web tool mode per agent. Use operation controls around web
tools when the app needs policy checks before external lookup.

The built-in page tools are public-web only. They accept `http` and `https`
URLs whose host resolves to public addresses, and they reject local, loopback,
link-local, private, multicast, unspecified, and `.localhost` targets before a
browser request starts. DNS verification is fail-closed: if Jidoka cannot prove
that a host resolves to at least one public address, the URL is rejected.

Applications that need internal network lookup should own that policy outside
the built-in web adapter, for example with a custom action, MCP tool, or
proxy that enforces the application's allowlist. For tests and advanced
deployments, the DNS resolver is configurable with
`config :jidoka, :dns_resolver, resolver_fun`; overriding it means the host
application owns the network-safety decision for those web tools.

### Skills And Plugins

`skill MySkillModule` registers a Jido.AI skill module. `skill "name"` and
`load_path "path"` load runtime `SKILL.md` definitions by name. Skills can
narrow prompt behavior and allowed tools.

`plugin MyPlugin` registers a Jidoka plugin module built with
`use Jidoka.Plugin`. Plugins publish a stable name and action-backed tools, and
are also available to imported-agent registries.

Keep skills and plugins explicit. They are prompt and tool-surface inputs, so
large or ambiguous bundles make agent behavior harder to inspect.

## Kino And Livebook

`Jidoka.Kino` contains optional Livebook helpers. The core runtime does not
depend on Kino; outside Livebook the rendering helpers become no-ops.

Common helpers:

- `Jidoka.Kino.setup_notebook/1` configures concise notebook output and provider
  secret bridging.
- `Jidoka.Kino.chat/3` wraps provider-backed chat examples and formats common
  results.
- `Jidoka.Kino.debug_agent/2`, `debug_request/2`, `timeline/2`,
  `call_graph/2`, `trace_table/2`, and `compaction/2` render inspection and
  trace views while developing.

Use these helpers for examples, demos, and teaching notebooks. Production
observability should stay in the host application's telemetry/export pipeline.

## Imported Agents

Imported agents are an experimental portability surface for controlled JSON/YAML
interchange. They are not arbitrary code loading.

An imported spec can name actions, plugins, subagents, workflows, handoffs,
lifecycle hooks, controls, skills, web tools, MCP tools, memory, compaction,
and typed results, but names only resolve through registries
supplied by the host application. Raw module strings are rejected; the app must
explicitly decide which modules and local skill paths are available at import
time.

Use imported agents for fixtures, portability tests, generated specs, and
controlled interchange. Use the Elixir DSL as the canonical authoring surface
while the beta DSL settles.

### Native DSL And Imported Spec Parity

| Feature | Native DSL | Imported JSON/YAML | Status |
| --- | --- | --- | --- |
| agent id and description | `agent :id do ... end` | `agent.id`, `agent.description` | supported |
| model and instructions | `model`, `instructions`, character callbacks | `defaults.model`, `defaults.instructions`, `defaults.character` | supported, with static imported values |
| runtime context defaults | `context Zoi.object(...)` plus `context:` at call time | `defaults.context` plus session/per-call context | supported; imported specs do not carry a Zoi context schema |
| typed result contracts | `result Zoi.object(...)` | `result.schema` JSON Schema | supported; native DSL uses Zoi, imports use JSON Schema |
| actions | `tools do action MyAction end` | `capabilities.tools` names | supported through `available_tools` registries |
| controls | `controls` | `lifecycle.guardrails` | supported through allowlisted registries |
| lifecycle hooks | request/runtime options | `lifecycle.hooks` | imported/runtime only |
| memory and compaction | runtime config and APIs | `lifecycle.memory`, `lifecycle.compaction` | imported/runtime only |
| schedules | `Jidoka.schedule_agent/2`, `Jidoka.schedule_workflow/2` | none | runtime API only |
| subagents, workflows, handoffs | `tools do subagent/workflow/handoff ... end` | `capabilities.subagents`, `workflows`, `handoffs` | supported through allowlisted registries |
| Ash resources | `tools do ash_resource MyResource end` | none | DSL-only; imports can expose named generated actions through `tools` |
| MCP tools | `tools do mcp_tools ... end` | `capabilities.mcp_tools` | supported |
| web tools | `tools do web :search | :read_only end` | `capabilities.web` | supported |
| skills and skill paths | `tools do skill/load_path ... end` | `capabilities.skills`, `skill_paths` | supported |
| plugins | `tools do plugin MyPlugin end` | `capabilities.plugins` | supported through `available_plugins` registries |
| arbitrary module references | Elixir modules in trusted app code | raw module strings rejected | unsupported by design |
| source-aware Spark errors | compile-time DSL errors | import-time validation errors | native DSL is richer |
| dynamic Elixir callbacks | functions, modules, and app code | none in data | DSL-only by design |

```elixir
{:ok, agent} =
  Jidoka.import_agent_file("priv/agents/support.yaml",
    available_tools: [MyApp.Actions.LoadTicket],
    available_plugins: [MyApp.Jidoka.SupportPlugin],
    available_handoffs: [MyApp.BillingAgent],
    available_workflows: %{"support_summary" => MyApp.SupportSummaryWorkflow}
  )

session =
  Jidoka.session(agent, "ticket-123",
    context: %{tenant_id: "tenant_123", actor_id: current_user.id}
  )

{:ok, reply} = Jidoka.chat(session, "Summarize the current ticket.")
```

A minimal imported spec keeps executable modules out of the data:

```yaml
agent:
  id: support_assistant
defaults:
  model: fast
  instructions: Help support staff resolve customer tickets.
  context:
    tenant: demo
capabilities:
  tools:
    - load_ticket
  plugins:
    - support_plugin
  web:
    - mode: read_only
```

The host application supplies the registries that map names such as
`load_ticket` and `support_plugin` to local modules.
