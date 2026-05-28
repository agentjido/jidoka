# Jidoka

[![Hex.pm](https://img.shields.io/hexpm/v/jidoka.svg)](https://hex.pm/packages/jidoka)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jidoka/)
[![CI](https://github.com/agentjido/jidoka/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jidoka/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jidoka.svg)](https://github.com/agentjido/jidoka/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)

Jidoka is an approachable Elixir package for building LLM agents.

It gives developers a small, declarative agent DSL for the durable authoring
surface: agent identity, model, instructions, context, typed results, tools,
and human-in-the-loop controls. Runtime APIs cover sessions, memory,
compaction, schedules, subagents, workflows, handoffs, debugging, and tracing.

Jidoka is an opinionated agent orchestration layer on top of Jido and Jido.AI.
It owns the developer-facing DSL, prompt assembly, runtime context, controls,
memory, compaction, delegation, schedules, inspection, and tracing while
leaving provider calls, ReAct execution, threads, signals, and durable runtime
storage with the underlying Jido/Jido.AI runtime.

## Architecture Boundary

Jidoka is the application-facing layer. It should make common agent work feel
small, explicit, and Elixir-native without replacing the runtime that actually
executes model turns.

Jidoka owns:

- Spark DSL compilation and source-aware validation
- model aliases, instructions, character prompts, and prompt section assembly
- runtime context normalization, reserved Jidoka context, and session metadata
- typed result contracts, parsing, validation, repair, and result controls
- tools, generated integration tools, operation controls, and credential
  reference checks
- lifecycle coordination around the Jido.AI ReAct loop
- memory retrieval/capture and compaction prompt injection
- integration adapters, registry-backed operation surfaces, skills, and plugins
- subagent calls, handoff routing, workflow exposure, and schedule execution
- debugging, local trace collection, AgentView projections, and notebook
  surfaces
- constrained interchange specs and registry-backed runtime compilation

Jido and Jido.AI remain responsible for:

- supervised runtime processes and lower-level agent state
- provider/model calls, streaming provider events, and tool-call execution
- the ReAct loop, request tracking, cancellation, and model/tool request state
- `Jido.Thread` as the canonical conversation log
- signals, directives, strategy internals, and low-level runtime plumbing
- durable runtime storage, hibernate/thaw, checkpoints, replay, and deployment
  recovery policy
- storage adapters, instance managers, registries, supervisors, partitions, and
  worker pools when an application graduates into an app-owned runtime

That boundary is intentional. Jidoka narrows authoring and application
integration; Jido/Jido.AI continue to own the runtime substrate.

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

Vocabulary policy for the beta:

- Use **result** in public docs for the app-facing final value. `Jidoka.Output`
  remains the internal implementation namespace and trace category while the
  stable API settles.
- Use **controls** for input, operation, and result policy. `guardrails` remains
  accepted in request options, imported specs, and some compatibility metadata
  until the migration is complete.
- Use **operation** for policy boundaries around tool-like work. Actions,
  subagents, workflows, handoffs, MCP tools, web tools, and Ash-generated tools
  are operation kinds.
- Error messages and new docs should prefer the public vocabulary. Existing
  trace keys, imported field names, and implementation module names may keep
  compatibility terms during the beta when changing them would break callers.

## V3 DSL Contract

The Elixir agent DSL has three top-level sections:

- `agent` for identity, `model`, `instructions`, `character`, `context`, and
  typed `result` contracts
- `tools` for `action`, `ash_resource`, `mcp_tools`, `skill`, `load_path`,
  `plugin`, `web`, `subagent`, `workflow`, and `handoff`
- `controls` for `input`, `operation`, and `result` policy

These names are not agent DSL sections anymore: `capabilities`, `lifecycle`,
`memory`, `compaction`, `schedule`, `guardrails`, `hooks`, and `output`.
Lifecycle hook calls such as `before_turn`, `after_turn`, `on_interrupt`, and
`timeouts` are also outside the agent DSL.

Use the runtime APIs instead:

- move former `capabilities` entries into `tools`
- move former `guardrails` entries into `controls`
- configure memory and compaction through runtime/imported-agent configuration
  or call `Jidoka.compact/2` explicitly
- register clock-driven work with `Jidoka.schedule_agent/2` or
  `Jidoka.schedule_workflow/2` from application boot code
- attach request-scoped hooks and timeouts through runtime options when a turn
  needs callbacks

Imported JSON/YAML specs still use compatibility field names such as
`capabilities` and `lifecycle` because those are data interchange fields, not
the Elixir authoring DSL.

From there, add only what the agent actually needs:

- memory runtime configuration when useful facts should survive turns
- compaction runtime configuration or `Jidoka.compact/2` when long
  conversations need smaller model context
- request-scoped hooks through `Jidoka.chat/3` options when a single turn needs
  lifecycle callbacks
- `Jidoka.schedule_agent/2` or `Jidoka.schedule_workflow/2` when work should run
  without a user prompt
- `workflow` when a deterministic multi-step process belongs outside the model
- `subagent` when the parent should delegate one bounded specialist task and
  receive the result back
- `handoff` when another agent should become the conversation owner for future
  turns
- `catalog` when the agent needs to discover a few relevant tools from a larger
  integration surface without loading the whole registry into the prompt

For prompt diagnostics, call `MyAgent.prompt_preflight/2` or
`Jidoka.prompt_preflight/3` to inspect the ordered system-prompt sections and
their provenance before sending a model request.

## Context Merge Semantics

Jidoka context merges are shallow. Agent defaults, session context, and per-turn
`context:` values merge at the top level; later values replace earlier values
for the same key. Atom and string forms of the same key are treated as
equivalent, so `%{tenant: "acme"}` is replaced by `%{"tenant" => "beta"}`.

Nested maps are not deep-merged:

```elixir
session =
  Jidoka.session(MyApp.SupportAgent, "ticket-123",
    context: %{actor: %{id: "user-1", role: "admin"}}
  )

opts = Jidoka.Session.chat_opts(session, context: %{actor: %{id: "user-2"}})
opts[:context].actor
#=> %{id: "user-2"}
```

Put independently changing fields at the top level, or merge nested application
data before passing it to Jidoka.

## Runtime Model

Jidoka agents are normal supervised processes. The DSL defines the agent; your
application still decides how long the process lives and who owns it.

`Jidoka.chat/3` accepts several target shapes. They all use the same chat
primitive, but they imply different ownership boundaries:

| Target | Auto-starts? | Lifetime owner | Handoff routing | Context behavior | Use when |
| --- | --- | --- | --- | --- | --- |
| `MyAgent` compiled module | Yes, under `MyAgent.id/0` | Shared `Jidoka.Runtime` | Only if `conversation:` is passed | Per-call `context:` plus agent defaults | demos, tests, small single-agent apps |
| PID | No | caller/application | Only if `conversation:` is passed | Per-call `context:` plus runtime config | the app already started the process |
| registered id string | No | caller/application | Only if `conversation:` is passed | Per-call `context:` plus runtime config | looking up an existing runtime process |
| `%Jidoka.Session{}` | Yes, under `session.agent_id` | session/runtime boundary | Yes, via `session.conversation_id` | session context merged with per-call context | production conversations and UI flows |
| imported-agent session | Yes, under the imported runtime module | session/runtime boundary | Yes, via `session.conversation_id` | imported defaults plus session/per-call context | controlled JSON/YAML agent specs |
| target plus `conversation:` | Depends on target | target owner | Yes, through handoff owner registry | normal target context plus conversation metadata | continuing a conversation that may be owned by another agent |
| any target with `stream: true` or `chat_stream/3` | Depends on target | target owner | Same as non-streaming target | events deliver to the caller process | UI or CLI rendering of incremental model events |
| any target with `start_chat_request/3` then `await_chat_request/2` | Depends on target | target owner | Same as non-streaming target | request handle is caller-owned | advanced UI/job orchestration that needs a non-blocking turn handle |

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

This is the Jidoka-owned continuity layer:

- session addressing gives a conversation a stable runtime target
- runtime context carries caller-provided facts into prompts, tools, controls,
  memory, schedules, and UI views
- inspection and tracing explain what happened during recent turns
- compaction snapshots summarize older provider-facing context without deleting
  the underlying thread

When production needs require lower-level runtime ownership, graduate the
generated runtime module into an app-owned runtime. The Jidoka-authored module
stays the same; your app takes over registry, storage, supervision, deployment,
auth, and persistence boundaries:

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

That lower runtime boundary owns the parts that must survive process restarts or
support replay:

- process restore through hibernate/thaw
- thread journals and durable transcript storage
- checkpoints for long-running or resumable work
- storage adapters and instance managers
- deployment-specific registry, supervisor, partition, worker-pool, and
  recovery policy
- low-level signal/directive control when the application needs it

Jidoka is the on-ramp: start with the smaller DSL, then move
`MyAgent.runtime_module()` into the full runtime when production needs require
direct control over storage, recovery, and deployment. V3 does not add a
separate Jidoka durability adapter; durable transcript storage belongs to the
runtime that actually supervises and stores the agent.

### Production Runtime Recipes

Use these patterns when a demo agent becomes an application-owned production
boundary.

Start the runtime from your supervision tree and keep the generated Jidoka agent
as the authoring surface:

```elixir
defmodule MyApp.Jido do
  use Jido,
    otp_app: :my_app,
    storage: {Jido.Storage.File, path: "priv/jido/storage"}
end

children = [
  MyApp.Jido,
  {Jidoka.Schedule.Manager, name: MyApp.ScheduleManager},
  MyAppWeb.Endpoint
]
```

Address user or account conversations with sessions. Store only the session
ids, tenant ids, actor ids, and other application references you need to
recreate the descriptor; the transcript remains in the runtime/thread storage
owned by the runtime:

```elixir
session =
  Jidoka.Session.new!(
    agent: MyApp.SupportAgent,
    id: "support:#{ticket.id}",
    runtime: MyApp.Jido,
    agent_id: "support:#{tenant.id}:#{ticket.id}",
    conversation_id: "ticket:#{ticket.id}",
    context: %{
      tenant_id: tenant.id,
      actor_id: current_user.id,
      ticket_id: ticket.id
    }
  )

{:ok, reply} = Jidoka.chat(session, user_message)
```

For durable transcript storage, configure the owning Jido runtime storage and
recovery policy. Jidoka sessions, schedule history, traces, and views are
runtime projections; use them for addressing, diagnostics, and UI state, not as
the durable source of record.

Register schedules from application boot code so in-memory scheduler state can
be rebuilt after deploys or restarts. Prefer callback values for prompts and
context when they depend on current application data:

```elixir
def register_agent_schedules! do
  session =
    Jidoka.Session.new!(
      agent: MyApp.SupportDigestAgent,
      id: "support-digest",
      runtime: MyApp.Jido,
      agent_id: "support-digest",
      conversation_id: "support-digest",
      context: %{tenant_id: "system", actor_id: "scheduler"}
    )

  {:ok, _schedule} =
    Jidoka.schedule_agent(session,
      id: "support-digest",
      cron: "0 9 * * *",
      timezone: "America/Chicago",
      prompt: {MyApp.Prompts, :support_digest, []},
      context: {MyApp.ScheduleContext, :support_digest, []},
      manager: MyApp.ScheduleManager,
      replace: true
    )
end
```

`Jidoka.run_schedule/2` returns `{:ok, run}` when the schedule manager records a
run. It does not mean the scheduled agent turn or workflow succeeded. Inspect
`run.status`; expected values include `:completed`, `:failed`, `:interrupted`,
`:handoff`, and `:skipped`.

For handoffs, pass a stable `conversation:` or use a session
`conversation_id`. Future turns with the same conversation id consult the
handoff owner registry and route to the current owner until
`Jidoka.reset_handoff/1` is called:

```elixir
case Jidoka.chat(session, "I need billing help.") do
  {:handoff, handoff} ->
    log_handoff(handoff)
    Jidoka.chat(session, handoff.message)

  {:ok, reply} ->
    {:ok, reply}
end
```

The default handoff owner registry is process-local and in-memory. It is keyed
by conversation id, is not durable, and is not cluster-aware; a process restart,
node change, or deploy loses the current owner unless the application records it
elsewhere. Run handoff participants inside the same runtime boundary, or treat
cross-runtime and cross-node handoff ownership as an application integration
boundary. Configure `:handoff_owner_store` with a module implementing
`Jidoka.Handoff.OwnerStore` when the application needs durable or cluster-aware
ownership.

For multi-tenant applications, keep tenant, account, actor, request, and
credential references in `context:`. Per-turn context merges over session
context, so callers can add request-scoped facts without mutating the session:

```elixir
Jidoka.chat(session, "Draft the response.",
  context: %{
    request_id: request_id,
    credential_ref: credential_ref,
    locale: current_user.locale
  }
)
```

Do not put raw secrets in context; Jidoka rejects common raw secret shapes so
tools and providers receive references instead of credentials.

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
the result arrives. `Jidoka.start_chat_request/3` and
`Jidoka.await_chat_request/2` are the lower-level public helpers behind that
pattern; reach for them only when the application owns a custom async UI or job
flow. Do not copy the transcript into LiveView assigns as a second store, and do
not use `AgentView` as durability. If a conversation must survive process
restarts, graduate the runtime to durable storage.

## Debugging And Observability

Debugging is a first-class Jidoka concern. During development, use inspection,
request summaries, traces, AgentView projections, and notebook helper views to
answer practical questions: what prompt was sent, what operations ran, what
control interrupted, what result was returned, and what changed between turns.

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

Trace and inspection stability boundary:

- Stable enough for application code: request id, run id, session id,
  conversation id, context ref, agent id, event category, event name, status,
  duration, operation kind/name, and formatted errors.
- Debug-only diagnostics: prompt previews, result previews, raw metadata maps,
  child runtime internals, provider-specific usage maps, generated diagrams,
  and event ordering beyond a single request timeline.
- Trace event schema: normalized `Jidoka.Trace.Event` structs expose
  `schema_version: 1` through `Jidoka.Trace.Event.schema_version/0`. External
  UIs should depend on the top-level event fields, not exact `metadata` or
  `measurements` shapes.
- Beta compatibility: new stable fields may be added without a breaking
  release; existing debug-only fields may be renamed or removed before 1.0.

## Credential Brokering

Jidoka treats credentials as references, not secrets. Pass a
`%Jidoka.Credential{}` or an app-owned `credential_ref` / `connection_ref`
through session context or tool arguments. Jidoka preserves that metadata for
controls, traces, and inspection, while rejecting raw secret-looking keys such
as `api_key`, `token`, `password`, and `client_secret` before they can enter a
prompt, transcript, trace, or operation call.

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

## Memory Failure Policy

Memory retrieval runs before the model turn. If namespace resolution or memory
store retrieval fails, Jidoka treats that as a hard request failure: the request
is marked failed with a structured memory error and the model turn does not
continue.

There is no per-agent fail-open retrieval mode in the current beta. If memory is
optional for an agent, keep memory disabled for that agent or use an application
store/namespace that can satisfy reads predictably.

Memory capture runs after a completed request. If storing the user/assistant
turn fails, Jidoka records `capture_error` and `capture_warning` on the request
memory metadata and emits a memory error trace, but it does not change the
completed request result into a failure.

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
- **Integration adapters:** connect Ash resources, web tools, MCP tools,
  skills, plugins, Kino/Livebook helpers, and imported JSON/YAML specs through
  the [integration guide](docs/integrations.md).
- **Durability:** graduate to durable runtime storage, hibernate/thaw,
  checkpoints, and thread journals when sessions need to survive process
  restarts.
- **Testing:** verify contracts, actions, results, workflows, and live behavior.

## Integration Docs

The core README stays focused on authoring and running agents. See the
[integration guide](docs/integrations.md) for Ash resources, MCP tools, web
tools, skills, plugins, Kino/Livebook helpers, and imported JSON/YAML specs.

## Install

```elixir
def deps do
  [
    {:jidoka, github: "agentjido/jidoka", branch: "main"}
  ]
end
```

After Jidoka ships on Hex, replace the Git dependency with
`{:jidoka, "~> 1.0"}`.

Configure a small model alias for examples and quick starts:

```elixir
# config/config.exs
config :jidoka,
  model_aliases: %{
    fast: "anthropic:claude-haiku-4-5"
  }
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
mix credo --strict --only warning
mix docs --warnings-as-errors
```

The runnable examples under `examples/` show the provider-free testing
progression and stay deterministic by default:

```bash
mix jidoka.example --list
mix jidoka.example support_agent
mix jidoka.example --all
```

Use `--live` when you want the same scenarios to make real model calls:

```bash
mix jidoka.example support_agent --live
mix jidoka.example --all --live
```

The teaching Livebooks under `livebook/` mirror that same order for
interactive exploration.

## Status

Jidoka is in beta. The V3 surface is being actively refined, trimmed, and
simplified; APIs and features may change without notice before the stable 1.0
release.

## License

Apache-2.0. See [LICENSE](LICENSE).
