# MCP Tools

This guide explains how to expose Model Context Protocol (MCP) servers as
agent operations through the `mcp_tools` DSL entity. Jidoka discovers tools
from a configured `Jido.MCP` endpoint, compiles them into ordinary
`Jidoka.Agent.Spec.Operation` entries, and routes each operation call back to
the remote MCP tool name. By the end you will be able to register an
endpoint, list and filter tools, run a deterministic test against an injected
MCP client, and reason about the trust boundary around external servers.

## When To Use This

- Use this guide when the agent needs to call tools hosted by an MCP server -
  internal services, third-party registries, or other Anubis-compatible
  endpoints.
- Use this guide when you want one DSL entry to surface every relevant tool
  from one endpoint, instead of writing one `Jidoka.Action` per remote tool.
- Do **not** use this guide for in-process tools. A `Jidoka.Action` (see
  [Getting Started](getting-started.md)) is simpler and faster.
- Do **not** use this guide for non-MCP HTTP services. Wrap those in a
  workflow. See [Skill, Workflow, And Subagent Tools](skill-workflow-subagent-tools.md).

## Prerequisites

- A working Jidoka DSL agent. See [Getting Started](getting-started.md).
- `:jido_mcp` resolved through `mix deps.get`.
- A registered MCP endpoint. Endpoints are runtime values; register them
  before any agent calls a tool:

```elixir
{:ok, endpoint} =
  Jido.MCP.Endpoint.new(:demo_mcp,
    transport: {:stdio, command: "node", args: ["./mcp/server.js"]},
    client_info: %{"name" => "my_app", "version" => "1.0.0"}
  )

{:ok, _endpoint} = Jido.MCP.register_endpoint(endpoint)
```

- For deterministic tests, an injected client module (see Testing).

## Quick Example

The smallest MCP-backed agent declares the endpoint and lets discovery do the
rest at compile time when static `tools:` are provided, or at the first turn
when discovery is dynamic.

```elixir
defmodule MyApp.PolicyAgent do
  use Jidoka.Agent

  agent :policy_agent do
    model "openai:gpt-4o-mini"
    instructions "Use lookup_policy to answer policy questions."
  end

  tools do
    mcp_tools endpoint: :demo_mcp,
              prefix: "mcp_",
              tools: [
                %{
                  name: "lookup_policy",
                  description: "Returns the latest support policy by topic.",
                  input_schema: %{
                    "type" => "object",
                    "properties" => %{"topic" => %{"type" => "string"}}
                  }
                }
              ]
  end
end
```

That spec exposes one operation, `mcp_lookup_policy`. The prefix prevents
remote names from colliding with local actions; the static `tools:` list
removes the need to call discovery at compile time.

## Concepts

```diagram
╭───────────────────────────╮
│ tools do                  │
│   mcp_tools endpoint: ... │
│             prefix: "mcp_"│
╰─────────────┬─────────────╯
              │ Jidoka.Operation.Source.MCP.new!
              ▼
╭───────────────────────────╮     ╭──────────────────────────╮
│ MCP source struct         │────▶│ list_tools (static or    │
│  endpoint + prefix +      │     │  via Jido.MCP)           │
│  optional static tools    │     ╰──────────┬───────────────╯
╰─────────────┬─────────────╯                │
              │                              ▼
              │            ╭───────────────────────────────╮
              │            │ Jidoka.Agent.Spec.Operation   │
              ▼            │  name = prefix + slug         │
╭───────────────────────────╮  metadata.source = "mcp"     │
│ routed_capability         │  metadata.remote_tool = name │
│  intent.name -> remote    │ ╰───────────────┬─────────────╯
│  Jido.MCP.call_tool/4     │                 │
╰─────────────┬─────────────╯                 │ turn loop
              │                               ▼
              ▼                  ╭───────────────────────────╮
        remote MCP server         │ same effect path as       │
                                  │ deterministic operations  │
                                  ╰───────────────────────────╯
```

Three concepts cover this integration:

1. **Endpoint id.** Endpoints are registered with `Jido.MCP.register_endpoint/1`
   and addressed by an atom id. The DSL stores the id, not the endpoint
   struct, so compile and runtime stay decoupled.
2. **Tool discovery.** When `tools:` is empty the runtime calls
   `Jido.MCP.list_tools/2` on the endpoint to enumerate available tools.
   `required: true` makes discovery failures hard errors; the default
   (`false`) treats a discovery failure as "no tools" and lets the agent
   keep running with whatever local operations remain.
3. **Name routing.** Each compiled operation has a slugged local name (e.g.
   `mcp_lookup_policy`). The capability maps that local name back to the
   remote tool name at call time. The model never sees the raw remote name.

### Security / Trust Boundaries

- MCP endpoints are **external code paths**. Treat every tool response as
  untrusted input: validate before you store, log, or pass it to another
  operation.
- The DSL trusts the `endpoint:` atom you provide. Never derive it from user
  input; resolve through your own allowlist of registered endpoints first.
- The `tools:` filter is the production allowlist. A bare `mcp_tools
  endpoint: :demo_mcp` exposes every tool the server advertises, including
  newly added ones after a server upgrade. Pin the list when you need
  reviewable change control.
- Credentials for the MCP transport live in `Jido.MCP.Endpoint`, not in the
  agent spec or in operation metadata. They are never serialized into
  snapshots or imports.
- The runtime never calls `String.to_atom/1` on remote tool names. The slug
  goes through `Macro.underscore/1` and a strict regex filter; injected names
  cannot escalate into new atoms.

## How To

### Step 1: Register The Endpoint At Application Boot

Endpoints are runtime state. Register them before any agent starts a turn.

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    {:ok, _} =
      :demo_mcp
      |> Jido.MCP.Endpoint.new!(
        transport: {:stdio, command: "node", args: ["./mcp/server.js"]},
        client_info: %{"name" => "my_app", "version" => "1.0.0"}
      )
      |> Jido.MCP.register_endpoint()

    Supervisor.start_link([Jidoka.Jido], strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
```

### Step 2: Pin The Tool List

When the server may advertise many tools, list the ones the agent should
actually use.

```elixir
tools do
  mcp_tools endpoint: :demo_mcp,
            prefix: "mcp_",
            tools: [
              %{name: "lookup_policy"},
              %{name: "list_topics"}
            ]
end
```

Static tool entries can be sparse maps. Only `name:` is required; descriptions
and `input_schema` fill in from discovery when they are absent.

### Step 3: Add A Prefix To Avoid Name Collisions

Two endpoints may advertise tools with the same name. Use prefixes to keep
operation names unique across an agent.

```elixir
tools do
  mcp_tools endpoint: :customer_mcp, prefix: "cust_"
  mcp_tools endpoint: :inventory_mcp, prefix: "inv_"
end
```

If `prefix:` is omitted, the source uses `mcp_<endpoint_slug>_` so the
default already keeps endpoints disjoint.

### Step 4: Make Discovery Required In Production

By default a discovery failure returns "no tools" and the agent continues.
Production code that depends on MCP being live should fail fast.

```elixir
tools do
  mcp_tools endpoint: :customer_mcp, required: true, timeout: 5_000
end
```

`required: true` turns discovery errors into spec compilation errors of the
shape `{:mcp_tool_discovery_failed, endpoint, reason}`.

### Step 5: Run A Deterministic Test With An Injected Client

The MCP source accepts a `:client` override and the runtime context accepts
`mcp_client:` so tests can run without a real server.

```elixir
defmodule FakeMCPClient do
  def list_tools(:demo_mcp, _opts) do
    {:ok,
     %{data: %{"tools" => [%{"name" => "lookup_policy"}]}}}
  end

  def call_tool(:demo_mcp, "lookup_policy", args, _opts) do
    {:ok, %{data: %{"topic" => args["topic"], "policy" => "Use the fake."}}}
  end
end

llm = fn _intent, journal, _ctx ->
  llm_calls = Enum.count(journal.results, fn {_id, r} -> r.kind == :llm end)

  case llm_calls do
    0 ->
      {:ok,
       %{type: :operation, name: "mcp_lookup_policy",
         arguments: %{"topic" => "runtime"}}}

    1 ->
      {:ok, %{type: :final, content: "Policy is to use the fake."}}
  end
end

{:ok, result} =
  Jidoka.turn(MyApp.PolicyAgent, "What is the runtime policy?",
    llm: llm,
    context: %{mcp_client: FakeMCPClient}
  )
```

## Common Patterns

- **Treat MCP tools as `:idempotent` only when the server promises it.** The
  default `idempotency: :idempotent` is correct for read-only tools. Set
  `idempotency: :unsafe_once` (or stricter) for tools that mutate.
- **Use prefixes to encode trust.** A prefix like `internal_` versus
  `external_` makes the trust boundary visible in logs, traces, and the
  prompt.
- **Pin `tools:` for any agent that ships to production.** Use discovery for
  local development and CI smoke tests.
- **Combine with controls.** `operation MyControl, when: [source: "mcp",
  endpoint: "demo_mcp"]` lets you gate every tool from one endpoint with one
  control.

## Testing

The MCP test suite is the canonical reference. See
`test/jidoka/mcp_test.exs` for the full pattern. A small
deterministic test looks like this:

```elixir
defmodule MyApp.PolicyAgentTest do
  use ExUnit.Case, async: true

  defmodule FakeMCPClient do
    def list_tools(:demo_mcp, _opts),
      do: {:ok, %{data: %{"tools" => [%{"name" => "lookup_policy"}]}}}

    def call_tool(:demo_mcp, "lookup_policy", _args, _opts),
      do: {:ok, %{data: %{"policy" => "ok"}}}
  end

  test "lookup_policy round trip" do
    llm = fn _intent, journal, _ctx ->
      llm_calls = Enum.count(journal.results, fn {_id, r} -> r.kind == :llm end)

      case llm_calls do
        0 ->
          {:ok,
           %{type: :operation, name: "mcp_lookup_policy",
             arguments: %{"topic" => "runtime"}}}

        1 ->
          {:ok, %{type: :final, content: "Policy is ok."}}
      end
    end

    assert {:ok, result} =
             Jidoka.turn(MyApp.PolicyAgent, "Runtime policy?",
               llm: llm,
               context: %{mcp_client: FakeMCPClient}
             )

    assert result.content =~ "ok"
  end
end
```

Tests should never call out to a real MCP server. Use the client override on
the source or the `mcp_client:` context key, whichever is more convenient.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, {:mcp_tool_discovery_failed, endpoint, reason}}` | `required: true` and discovery failed. | Register the endpoint at boot, or set `required: false` while iterating. |
| `{:error, {:missing_operation_handler, name}}` from a turn | The model called a tool name that did not exist in the routed source. | Confirm the operation name with `Jidoka.inspect/1`; tighten the prompt or pin `tools:`. |
| `{:error, {:invalid_mcp_client, client}}` | The supplied client module did not export `list_tools/2` and `call_tool/4`. | Implement the two functions on the double, or fall back to the default `Jido.MCP`. |
| `{:error, {:invalid_mcp_tool, tool}}` at compile time | A static `tools:` entry was malformed. | Ensure each entry is a map with at least `name:`. |
| Operation name unexpectedly differs from the remote tool | The prefix plus slug rewrite produced a different name. | Inspect `metadata.remote_tool` to see the original name and adjust the prefix or `name:` overrides. |

## Reference

Key modules touched in this guide:

- [`Jidoka.Operation.Source.MCP`](`Jidoka.Operation.Source.MCP`) - struct,
  normalization, discovery, and routed capability.
- [`Jidoka.Operation.Source`](`Jidoka.Operation.Source`) - the behaviour and
  compiler all operation sources share.
- Tool DSL section - DSL
  schema for the `mcp_tools` entity (`endpoint`, `prefix`, `tools`,
  `required`, `timeout`, `description`, `idempotency`, `metadata`).
- [`Jido.MCP`](`Jido.MCP`) - public MCP client API.
- [`Jido.MCP.Endpoint`](`Jido.MCP.Endpoint`) - endpoint registration.

## Related Guides

- [Getting Started](getting-started.md) - the smallest DSL agent end to end.
- [Skill, Workflow, And Subagent Tools](skill-workflow-subagent-tools.md) -
  the three other DSL-level operation sources that share `Jidoka.Operation.Source`.
- [AshJido Resources](ash-jido.md) - a sibling source for resource-backed
  tools.
- [Browser Tools](browser-tools.md) - a sibling source for constrained
  read-only browsing.
- [Idempotency And Safety](idempotency-and-safety.md) - why MCP defaults to
  `:idempotent` and when to override.
