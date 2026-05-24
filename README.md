# Jidoka

[![Hex.pm](https://img.shields.io/hexpm/v/jidoka.svg)](https://hex.pm/packages/jidoka)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jidoka/)
[![CI](https://github.com/agentjido/jidoka/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jidoka/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jidoka.svg)](https://github.com/agentjido/jidoka/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

The easy on-ramp to LLM agents in Elixir.

Jidoka is a small, opinionated harness over [Jido](https://github.com/agentjido/jido)
and [Jido.AI](https://github.com/agentjido/jido_ai). It gives you a developer-friendly
DSL focused on the common LLM-agent use cases, without asking you to learn signals,
directives, state operations, strategy internals, or request plumbing on day one.

If you have looked at the broader Jido ecosystem and felt it was a lot to absorb
just to ship one agent, Jidoka is for you.

> **Beta status:** Jidoka is in beta. We are actively refining, trimming, and
> reshaping the package before a stable release. APIs, behaviors, and feature
> boundaries can change without notice while this work continues.

## Why this exists

The Jido ecosystem is powerful, but powerful is not the same as approachable.
Jidoka is the opinionated layer that:

- starts with a single agent module and a `chat/3` call
- grows progressively when you actually need tools, memory, compaction,
  structured output, workflows, subagents, or handoffs
- hides Jido's lower-level surface until you choose to opt in

You can stay on the easy path indefinitely, or drop down into Jido directly when
your application needs it. Jidoka does not get in the way.

## What you get

- **A tiny DSL.** `use Jidoka.Agent`, name it, give it instructions, you have an
  agent.
- **Fast time-to-first-agent.** Define, start, and chat in under thirty lines.
- **Progressive opt-in.** Tools, structured output, memory, compaction,
  characters, workflows, subagents, handoffs, MCP, web access, plugins, hooks, and
  guardrails are all available, but none are required.

## Your first agent

```elixir
defmodule MyApp.AssistantAgent do
  use Jidoka.Agent

  agent do
    id :assistant_agent
  end

  defaults do
    model :fast
    instructions "You are a concise assistant. Answer directly."
  end
end
```

Start it and chat:

```elixir
{:ok, pid} = MyApp.AssistantAgent.start_link(id: "assistant-1")

{:ok, reply} =
  MyApp.AssistantAgent.chat(pid, "Write one sentence about why Elixir works well for agents.")
```

That is a complete Jidoka agent. Only `agent.id` and `defaults.instructions`
are required. Everything else is optional.

You can also load the same conceptual agent from a JSON or YAML spec at
runtime. See [Two equal authoring paths](#two-equal-authoring-paths) below.

## Run it in your app

Jidoka agents are OTP processes owned by the shared `Jidoka.Runtime`
supervisor. Your application chooses the lifetime: one request, one user
session, one long-lived application worker, or one first-class Jidoka schedule.

```elixir
session =
  Jidoka.Session.new!(
    agent: MyApp.AssistantAgent,
    id: "support-123",
    context: %{actor: current_user}
  )

{:ok, reply} =
  Jidoka.chat(session, "Help me triage this support ticket.")
```

`Jidoka.Session` is a plain descriptor for stable conversation identity and
runtime context. It is not a process or persistence layer. For UI-facing agents,
use an `AgentView` adapter to project visible messages, async turns, streaming
state, and final result mapping.

If you need an application-owned Jido instance instead of the shared
`Jidoka.Runtime`, start the generated `runtime_module/0` under your own
`use Jido, otp_app: :my_app` runtime and keep calling `Jidoka.chat/3`.

For event-level streaming, keep the same API and opt in per turn:

```elixir
{:ok, stream} = Jidoka.chat(session, "Draft a reply.", stream: true)

for event <- stream do
  if delta = Jidoka.Chat.Stream.text_delta(event), do: IO.write(delta)
end

{:ok, final_reply} = Jidoka.Chat.Stream.await(stream)
```

See [Running Agents](guides/running-agents.md), [Sessions](guides/sessions.md),
[AgentView](guides/agent-view.md), [Schedules](guides/schedules.md),
[Phoenix LiveView](guides/phoenix-liveview.md), and [Graduating To Jido](guides/graduating-to-jido.md).

## Return structured data, not just text

For classification, extraction, and routing tasks, put the response shape on
the agent. Jidoka asks the model for JSON, parses it, validates it with
[Zoi](https://github.com/marpo60/zoi), and hands you back a typed map.

```elixir
defmodule MyApp.TicketClassifier do
  use Jidoka.Agent

  agent do
    id :ticket_classifier

    output do
      schema Zoi.object(%{
        category: Zoi.enum([:billing, :technical, :account]),
        confidence: Zoi.float(),
        summary: Zoi.string()
      })
    end
  end

  defaults do
    model :fast
    instructions "Classify support tickets for routing."
  end
end
```

```elixir
{:ok, pid} = MyApp.TicketClassifier.start_link(id: "ticket-classifier-1")

{:ok, ticket} =
  MyApp.TicketClassifier.chat(pid, "I was double charged for my last invoice.")

# ticket =>
# %{category: :billing, confidence: 0.92, summary: "Customer reports a duplicate invoice charge."}
```

Validation retries and repair behavior are configurable. See
[Structured Output](guides/structured-output.md) and [Errors](guides/errors.md)
for the details.

## Add a tool

Tools are how an agent does deterministic application work: lookups, math,
API calls, anything that should not be the model's job to imagine.

```elixir
defmodule MyApp.Tools.AddNumbers do
  use Jidoka.Tool,
    description: "Adds two integers.",
    schema: Zoi.object(%{a: Zoi.integer(), b: Zoi.integer()})

  @impl true
  def run(%{a: a, b: b}, _context) do
    {:ok, %{sum: a + b}}
  end
end

defmodule MyApp.MathAgent do
  use Jidoka.Agent

  agent do
    id :math_agent
  end

  defaults do
    model :fast
    instructions "Use tools when they help. Keep the final answer short."
  end

  capabilities do
    tool MyApp.Tools.AddNumbers
  end
end
```

The model can now call `add_numbers` mid-turn. See [Tools](guides/tools.md) for
the full tool API, plus the per-capability guides for
[Ash Resources](guides/ash-resources.md), [MCP](guides/mcp-tools.md),
[Web Access](guides/web-access.md), [Skills](guides/skills.md), and
[Plugins](guides/plugins.md).

## What else is in the box

Jidoka grows with you. The capabilities below are all optional and individually
documented under `guides/`.

### Agent building blocks

- **[Context schemas](guides/context.md)**: declare a Zoi schema on
  the agent and have per-turn `context:` validated before the model is called.
- **[Memory](guides/memory.md)**: opt-in conversation memory built on
  `jido_memory`, with simple namespace and capture/retrieve options.
- **[Compaction](guides/compaction.md)**: opt-in summary compaction for long
  sessions, trimming only provider-facing messages while preserving the
  original thread.
- **[Characters](guides/characters.md)**: structured persona data for voice,
  tone, and identity, rendered into the prompt before instructions.
- **[Structured output](guides/structured-output.md)**: Zoi-validated final
  answers with retries and optional repair.
- **[Schedules](guides/schedules.md)**: cron-based scheduled agent turns and
  workflow runs through `Jidoka.Schedule.Manager`.

### Orchestration

- **[Workflows](guides/workflows.md)**: deterministic, app-owned multi-step
  processes via `use Jidoka.Workflow`.
- **[Subagents](guides/subagents.md)**: specialist agents exposed to a parent
  agent as tools, for one-turn delegation.
- **[Handoffs](guides/handoffs.md)**: transfer ownership of future turns in a
  conversation to another agent.

### Integrations and extensions

- **[Imported agents](guides/imported-agents.md)**: load agents from JSON or
  YAML at runtime through explicit allowlist registries.
- **MCP tools**: sync external tools through `jido_mcp`.
- **Web access**: constrained, read-only public web search and page reads.
- **Plugins**: deeper extension points that contribute tools and runtime
  behavior.
- **Ash resources**: expose generated `AshJido` actions as model-callable
  tools.

### Safety and runtime controls

- **Hooks and guardrails**: turn-scoped callbacks and input/output/tool
  validation.
- **Structured errors**: `Jidoka.format_error/1` turns any runtime failure
  into a user-safe string. See [Errors](guides/errors.md).
- **Inspection**: `Jidoka.inspect_agent/1`, `Jidoka.inspect_request/1`, and
  `Jidoka.inspect_workflow/1` expose stable views of definitions and runs.
  `Jidoka.inspect_compaction/1` shows the latest context summary snapshot.
- **Tracing**: first-class run traces through `Jidoka.Trace` and Livebook
  helpers.
- **Testing**: provider-free contract, tool, guardrail, structured output, and
  workflow tests, plus opt-in live evals. See [Testing Agents](guides/testing-agents.md).

### Where to learn each feature

Recommended reading order:

1. [Getting Started](guides/getting-started.md)
2. [Agents](guides/agents.md)
3. [Models](guides/models.md)
4. [Instructions](guides/instructions.md)
5. [Context](guides/context.md)
6. [Structured Output](guides/structured-output.md)
7. [Running Agents](guides/running-agents.md)
8. [Sessions](guides/sessions.md)
9. [Schedules](guides/schedules.md)
10. [AgentView](guides/agent-view.md)
11. [Tools](guides/tools.md) (then see Capabilities for the rest)
12. [Subagents](guides/subagents.md), [Workflows](guides/workflows.md), [Handoffs](guides/handoffs.md)
13. [Memory](guides/memory.md)
14. [Compaction](guides/compaction.md)
15. [Imported Agents](guides/imported-agents.md)
16. [Errors](guides/errors.md), [Inspection](guides/inspection.md), and [Testing Agents](guides/testing-agents.md)
17. [Examples](guides/examples.md)
18. [Phoenix LiveView](guides/phoenix-liveview.md)
19. [Graduating To Jido](guides/graduating-to-jido.md)
20. [Production](guides/production.md)

The full guide index is at [guides/overview.md](guides/overview.md).

## Two equal authoring paths

Jidoka has two ways to describe the same conceptual agent. They are peers, not
a primary and a fallback.

### Elixir DSL

`use Jidoka.Agent` is the recommended path for Elixir developers. You get
compile-time validation, formatter support, and source-aware errors.

```elixir
defmodule MyApp.AssistantAgent do
  use Jidoka.Agent

  agent do
    id :assistant_agent
  end

  defaults do
    model :fast
    instructions "You are a concise assistant."
  end
end
```

### Imported JSON/YAML agents

For teams that want portable specs, or want to author agents without writing
Elixir, Jidoka supports a constrained runtime import path:

```elixir
json = ~S"""
{
  "agent": { "id": "json_agent" },
  "defaults": {
    "model": "fast",
    "instructions": "You are a concise assistant."
  }
}
"""

{:ok, agent} = Jidoka.import_agent(json)
{:ok, pid}   = Jidoka.start_agent(agent, id: "json-agent")
{:ok, reply} = Jidoka.chat(pid, "Say hello.")
```

YAML works the same way with `format: :yaml`. Tools, plugins, hooks,
guardrails, characters, workflows, and handoffs are resolved through explicit
`available_*` allowlist registries so imported agents stay safe.

See [Imported Agents](guides/imported-agents.md) for the full constrained
schema.

## Install and configure

### Add the dependency

Jidoka beta releases are distributed through Hex:

```elixir
def deps do
  [
    {:jidoka, "~> 1.0.0-beta.1"}
  ]
end
```

During beta development, you can also pin a specific Git commit:

```elixir
def deps do
  [
    {:jidoka,
     git: "https://github.com/agentjido/jidoka.git",
     ref: "COMMIT_SHA"}
  ]
end
```

For local development against a checkout:

```elixir
def deps do
  [
    {:jidoka, path: "../jidoka"}
  ]
end
```

Then:

```bash
mix deps.get
```

### Configure a provider

The README examples use Anthropic through ReqLLM/Jido.AI:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

In this repo, `.env` is also loaded automatically through `dotenvy`. Shell
environment variables win over `.env`.

### Model aliases

Jidoka owns a small alias layer under `config :jidoka, :model_aliases`. The
default `:fast` alias maps to `anthropic:claude-haiku-4-5`. You can also pass
direct model strings (`"anthropic:claude-haiku-4-5"`) or inline maps wherever
`model` is accepted.

### Beta status

Jidoka is currently beta. The core authoring surface (agents, tools, workflows,
imports, structured output, tracing, structured errors, examples, and the Phoenix
LiveView consumer) is ready for early adopters, but small breaking changes are
still possible before stable 1.0.

## Try the demos and develop locally

### Built-in demo commands

```bash
mix jidoka chat --dry-run
mix jidoka imported --dry-run
mix jidoka workflow --dry-run
mix jidoka orchestrator --dry-run
```

Drop `--dry-run` to run a demo against a configured provider:

```bash
mix jidoka chat -- "Use one sentence to explain what Jidoka is."
```

The `examples/` directory contains focused, runnable demos for chat, structured
output, tools, workflows, orchestration, support, and more. Each canonical
example also supports `--verify` to exercise its tool and output contracts
without calling a provider:

```bash
mix jidoka lead_qualification --verify
```

### Local development

From this directory:

```bash
mix deps.get
mix compile
mix test
mix format
```

`mix quality` runs formatting, compiler warnings, Credo, Dialyzer, and
documentation coverage.

### Phoenix LiveView consumer app

`dev/jidoka_consumer/` is a Phoenix LiveView fixture that integrates a Jidoka
chat agent, an Ash-backed ticket resource, subagents, workflows, and handoffs.
Boot it on port 4002:

```bash
cd dev/jidoka_consumer
mix deps.get
PORT=4002 mix phx.server
```

See [Phoenix LiveView](guides/phoenix-liveview.md) for the integration walk-through.

## License

Apache-2.0. See [LICENSE](LICENSE).
