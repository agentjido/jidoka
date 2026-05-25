# Jidoka

[![Hex.pm](https://img.shields.io/hexpm/v/jidoka.svg)](https://hex.pm/packages/jidoka)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jidoka/)
[![CI](https://github.com/agentjido/jidoka/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jidoka/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jidoka.svg)](https://github.com/agentjido/jidoka/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)

Jidoka is an approachable Elixir package for building LLM agents.

It gives developers a small, declarative agent DSL for common LLM agent
workflows: chat, actions, typed results, human-in-the-loop controls, memory,
compaction, schedules, subagents, workflows, handoffs, debugging, and tracing.

Jidoka is intentionally thin. It gives you a friendly authoring layer on top of
a solid runtime, execution, and model-calling foundation.

## First Agent

```elixir
defmodule MyApp.AssistantAgent do
  use Jidoka.Agent

  agent :assistant do
    model :fast
    instructions "Answer clearly and concisely."
  end
end
```

Run a turn directly:

```elixir
{:ok, reply} = Jidoka.chat(MyApp.AssistantAgent, "Summarize this ticket.")
```

When the conversation needs identity and runtime context, make the session
explicit without changing the chat primitive:

```elixir
{:ok, reply} =
  MyApp.AssistantAgent
  |> Jidoka.session("user-123", context: %{actor: current_user})
  |> Jidoka.chat("Summarize this ticket.")
```

`Jidoka.Session` is the underlying descriptor for stable conversation identity.
It is not a process, database table, or separate chat API.

## Grow The Agent

The useful middle step is one app-shaped agent: pass runtime context, call one
deterministic action, and put one control around that operation.

```elixir
defmodule MyApp.SupportAgent do
  use Jidoka.Agent

  agent :support_agent do
    model :fast
    instructions "Use the ticket data, then recommend the next support step."

    # Context is caller-provided runtime data.
    context Zoi.object(%{
      account_id: Zoi.string(),
      actor_id: Zoi.string()
    })
  end

  tools do
    # Actions are deterministic operations the agent can call.
    action MyApp.Actions.LoadTicket
  end

  controls do
    # Controls wrap inputs, operations, and results with policy.
    operation MyApp.Controls.RequireApproval,
      when: [kind: :action, name: :load_ticket]
  end
end
```

Then call it with session context:

```elixir
{:ok, triage} =
  MyApp.SupportAgent
  |> Jidoka.session("ticket-123",
    context: %{account_id: "acct_123", actor_id: current_user.id}
  )
  |> Jidoka.chat("What should we do next?")
```

That example introduces the core growth path:

- `context` is caller-provided runtime data
- `actions` are deterministic operations the agent may call
- `controls` are policy boundaries around input, operations, and results
- human-in-the-loop flows are controls that pause risky operations for approval

Use these nouns consistently:

- **context** is per-turn application data supplied by the caller, such as
  actor, account, tenant, or ticket ids
- **agent state** belongs to the running process and is not the normal place for
  application inputs
- **memory** recalls useful facts from prior turns or external stores
- **compaction** summarizes older transcript context so the next model call can
  stay smaller
- **result** is the final value returned to application code after Jidoka parses
  and validates the raw model answer when a typed result contract is declared

From there, add only what the agent actually needs:

- `memory` when useful facts should survive turns
- `compaction` when long conversations need smaller model context
- `schedule` when the agent should run without a user prompt
- `workflow` when a deterministic multi-step process belongs outside the model
- `subagent` when the parent should delegate one bounded specialist task and
  receive the result back
- `handoff` when another agent should become the conversation owner for future
  turns
- `catalog` when the agent needs to discover tools from a larger integration
  surface

## Runtime Model

Jidoka agents are normal supervised processes. The DSL defines the agent; your
application still decides how long the process lives and who owns it.

For demos, tests, and small apps, a compiled agent module can be the chat target.
Jidoka starts or reuses one shared runtime process under the agent's public id:

```elixir
{:ok, reply} = Jidoka.chat(MyApp.AssistantAgent, "Summarize this ticket.")
```

That module-target form is intentionally convenient. When process lifetime
matters, make ownership explicit.

For application-owned agents, put them directly in your supervision tree:

```elixir
children = [
  {MyApp.AssistantAgent, id: "assistant"},
  MyAppWeb.Endpoint
]
```

For session-scoped agents, let the session name the process and conversation.
`Jidoka.chat/3` starts or reuses the session runtime agent when a turn arrives:

```elixir
session = Jidoka.session(MyApp.AssistantAgent, "user-123")
{:ok, reply} = Jidoka.chat(session, "What should we do next?")
```

Sessions are conversation addresses, not durable storage. They carry `agent_id`,
`conversation_id`, `context`, and startup options so controllers, LiveViews,
jobs, schedules, and tests can all point at the same runtime boundary without a
second chat API.

For lower-level OTP ownership, run generated agents under an app-owned runtime.
The Jidoka-authored module stays the same; your app takes over registry,
storage, supervision, deployment, auth, and persistence boundaries:

```elixir
defmodule MyApp.Jido do
  use Jido,
    otp_app: :my_app,
    storage: {Jido.Storage.File, path: "priv/jido/storage"}
end

children = [
  MyApp.Jido,
  MyAppWeb.Endpoint
]
```

Start the generated runtime module from that owner:

```elixir
{:ok, pid} =
  MyApp.Jido.start_agent(MyApp.SupportAgent.runtime_module(),
    id: "support-agent-user-123"
  )
```

The lower-level runtime owns hibernate/thaw, checkpointing, thread journals,
storage adapters, instance managers, and low-level signal/directive control.
Jidoka is the on-ramp: start with the smaller DSL, then move the generated
runtime module into the full runtime when production needs outgrow the wrapper.

## Phoenix And UI State

Phoenix and LiveView code should treat agents as runtime processes and
`AgentView` as a projection for assigns. Keep the source of truth in the
running agent and its thread; keep only the session, current view, and any
in-flight run handle in UI state.

```elixir
defmodule MyAppWeb.SupportAgentView do
  use Jidoka.AgentView, agent: MyApp.SupportAgent
end

def mount(%{"ticket_id" => ticket_id}, _session, socket) do
  jidoka_session =
    Jidoka.session(MyApp.SupportAgent, "ticket:#{ticket_id}",
      context: %{actor_id: socket.assigns.current_user.id, ticket_id: ticket_id}
    )

  {:ok, pid} = MyAppWeb.SupportAgentView.start_agent(jidoka_session)
  {:ok, view} = MyAppWeb.SupportAgentView.snapshot(pid, jidoka_session)

  {:ok, assign(socket, jidoka_session: jidoka_session, agent_pid: pid, agent_view: view)}
end
```

For a submit event, run a normal Jidoka turn with the session. Use
`Jidoka.chat_stream/3` when the UI should render incremental model events. If
the UI uses `AgentView.start_turn/4`, keep the returned run handle in assigns,
refresh the projection while the turn is running, then call `after_turn/2` after
the result arrives. Do not copy the transcript into LiveView assigns as a second
store, and do not use `AgentView` as durability. If a conversation must survive
process restarts, graduate the runtime to durable storage.

## Debugging And Observability

Debugging is a first-class Jidoka concern. During development, use inspection,
request summaries, traces, AgentView projections, and Kino/Livebook views to
answer practical questions: what prompt was sent, what operations ran, what control
interrupted, what result was returned, and what changed between turns.

Production observability stays standards-friendly instead of becoming a
Jidoka-only format. The foundation emits structured telemetry and correlation
IDs, and model calls can flow into OpenTelemetry GenAI-compatible OTLP
pipelines.

Your host app still configures the telemetry exporter. Jidoka's job is to
preserve session, conversation, request, run, and trace IDs so local debugging
and production telemetry tell the same story.

For production export, keep the exporter in your app's normal telemetry
boundary. The useful event families are:

- runtime request/model/tool events under `[:jido, :ai, ...]`
- Jidoka lifecycle events under `[:jidoka, category, :event]`

Attach your exporter, metrics collector, or tracing bridge in application code:

```elixir
:telemetry.attach_many(
  "my-app-agent-observability",
  [
    [:jido, :ai, :request, :complete],
    [:jido, :ai, :llm, :complete],
    [:jido, :ai, :tool, :complete],
    [:jidoka, :control, :event],
    [:jidoka, :workflow, :event],
    [:jidoka, :output, :event]
  ],
  &MyApp.AgentTelemetry.handle_event/4,
  nil
)
```

The handler should treat `metadata.session_id`, `metadata.conversation_id`,
`metadata.request_id`, `metadata.run_id`, `metadata.trace_id`, and
`metadata.span_id` as the join keys between local `Jidoka.Trace` inspection and
your production backend. Use whichever exporter your app already standardizes
on; Jidoka does not require an exporter dependency just to build agents.

## Credential Brokering

Jidoka treats credentials as references, not secrets. Pass a
`%Jidoka.Credential{}` or an app-owned `credential_ref` / `connection_ref`
through session context or tool arguments. Jidoka preserves that metadata for
controls, traces, and inspection, while rejecting raw secret-looking keys such
as `api_key`, `token`, `password`, and `client_secret` before they can enter a
prompt, transcript, trace, or tool call.

```elixir
credential =
  Jidoka.Credential.new!(
    provider: :github,
    account: "acct_123",
    actor: current_user.id,
    scopes: ["repo"],
    lease_id: "lease_123",
    risk: :high,
    confirmation_required: true
  )

session =
  Jidoka.session(MyApp.SupportAgent, "ticket-123",
    context: %{actor_id: current_user.id, credential_ref: credential}
  )
```

At execution time, your broker, proxy, sidecar, or connect layer exchanges the
reference for the real credential inside your application boundary. That layer
can look up a vault record, refresh OAuth, choose a tenant-specific connection,
or sign the outbound request. The model sees only the operation and reference
metadata; the actual secret stays with the system that owns the integration.

## Feature Map

- **Agents:** define identity, model, instructions, and runtime behavior in one
  module.
- **Chat turns:** call agents directly, through pids, or through sessions.
- **Sessions:** name a conversation and carry runtime context across turns.
- **Context:** pass caller-provided facts into tools, prompts, controls, memory,
  and views.
- **Typed results:** validate final results with Zoi when the app needs
  structured data.
- **Actions:** expose deterministic operations the agent may call.
- **Controls:** add policy at input, operation, and result boundaries.
- **Human-in-the-loop:** pause risky inputs, operations, or results for manual
  approval through controls, `Jidoka.Approval`, and interrupts.
- **Credential brokering:** carry credential references through sessions,
  controls, traces, and tool execution without exposing raw secrets to the
  model.
- **Debugging:** inspect prompts, requests, traces, runtime state, and projected
  conversation views while building agents.
- **Observability standards:** flow structured telemetry into OpenTelemetry
  GenAI-compatible backends.
- **Memory and compaction:** preserve useful facts and keep long sessions within
  model context limits.
- **Streaming and UI projections:** build UI-facing agents with `AgentView`
  state for LiveView, controllers, CLIs, tests, and jobs.
- **Schedules:** run agent turns or workflows on a clock with an in-memory
  manager that apps re-register on boot.
- **Workflows:** keep deterministic multi-step processes outside the model.
- **Subagents:** delegate a bounded specialist task while the parent remains
  responsible for the turn.
- **Handoffs:** transfer conversation ownership so future turns route to the
  receiving agent until reset.
- **Tool integrations:** connect Ash actions, web tools, MCP tools, skills,
  plugins, and catalogs.
- **Imported agents:** load constrained JSON/YAML specs through allowlisted
  registries.
- **Durability:** graduate to durable runtime storage, hibernate/thaw,
  checkpoints, and thread journals when sessions need to survive process
  restarts.
- **Testing:** verify contracts, actions, results, workflows, and live behavior.

## Install

```elixir
def deps do
  [
    {:jidoka, "~> 1.0"}
  ]
end
```

Configure a provider for live LLM calls:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

The default `:fast` model alias is meant for quick starts. You can also pass
explicit model strings wherever `model` is accepted.

## Development

```bash
mix deps.get
mix compile
mix test
mix format
```

Useful verification commands:

```bash
mix compile --warnings-as-errors
mix docs --warnings-as-errors
mix doctor --raise
```

## Status

The old guide, example, dev, and Livebook support trees are being replaced while
the V2 DSL settles. The package source remains the source of truth during this
cleanup pass.

## License

Apache-2.0. See [LICENSE](LICENSE).
