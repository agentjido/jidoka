# AGENTS.md - Jidoka Example App

## Intent

This folder contains a Phoenix showcase app for runnable, use-case-driven
Jidoka examples.

Each example should feel like a small application a new developer can inspect,
run, and adapt. Prefer clarity over completeness.

The example app is not a second runtime. It demonstrates how an application
uses Jidoka agents in a normal Phoenix/Jido process tree.

Use `AGENT_LADDER.md` as the product map for which capability each example
introduces.

The runnable V2 baseline currently includes:

- Support Agent
- Research Agent
- Approval Flow Agent
- Ash Agent
- Lead Quality Agent
- Memory Agent
- Knowledge Agent
- Debug Agent
- Lua Tools Agent
- Kitchen Sink Agent

Other V1 examples are tracked in `AGENT_LADDER.md` as parity gaps. Do not add
new runnable routes for them until the underlying Jidoka feature is stable
enough to teach without caveats.

## Example Layout

Keep one Phoenix project in `example/`:

- `mix.exs`
- `config/`
- `lib/jidoka_example/` for plain agent modules and actions
- `lib/jidoka_example_web/` for Phoenix endpoint, router, layouts, and LiveViews
- `priv/` for sample data, prompts, or fixtures

Use a path dependency back to the package root:

```elixir
{:jidoka, path: ".."}
```

## Runtime Shape

The app owns its own Jido runtime:

```elixir
defmodule JidokaExample.Jido do
  use Jido, otp_app: :jidoka_example
end
```

Example agents should be supervised directly in `JidokaExample.Application`:

```elixir
children = [
  JidokaExample.Jido,
  {JidokaExample.SupportAgent.Agent, jido: JidokaExample.Jido},
  {JidokaExample.ResearchAgent.Agent, jido: JidokaExample.Jido},
  {JidokaExample.ApprovalAgent.Agent, jido: JidokaExample.Jido},
  {JidokaExample.AshAgent.Agent, jido: JidokaExample.Jido},
  {JidokaExample.LeadQualityAgent.Agent, jido: JidokaExample.Jido},
  {JidokaExample.MemoryAgent.Agent, jido: JidokaExample.Jido},
  {JidokaExample.KnowledgeAgent.Agent, jido: JidokaExample.Jido},
  {JidokaExample.DebugAgent.Agent, jido: JidokaExample.Jido},
  {JidokaExample.LuaToolsAgent.Agent, jido: JidokaExample.Jido},
  {JidokaExample.KitchenSinkAgent.Agent, jido: JidokaExample.Jido},
  {Phoenix.PubSub, name: JidokaExample.PubSub},
  JidokaExampleWeb.Endpoint
]

opts = [strategy: :rest_for_one, name: JidokaExample.Supervisor]
```

Use `:rest_for_one` so a restart of the local Jido runtime also restarts the
supervised demo agents and Phoenix endpoint that depend on it.

This is intentional. `Jidoka.Agent` modules expose a child spec that starts a
`Jido.AgentServer`, so the example should not add app-local session stores,
runtime wrappers, or GenServers just to host one agent.

Use `JidokaExample.Jido.whereis(agent_id)` from LiveViews when a route needs to
send a turn to a supervised agent process.

## Example Template

Each agent example should have:

- a use-case folder under `lib/jidoka_example/<example_name>/`;
- a plain Jidoka DSL agent module in that folder;
- one or more `Jidoka.Action` modules in `actions/`;
- one LiveView folder under `lib/jidoka_example_web/live/<example_name>_live/`;
- one route LiveView module in `<example_name>_live/index.ex`;
- one colocated `AgentView` module in `<example_name>_live/view.ex`;
- a short module guide rendered below the route headline;
- optional sample data under `priv/<example_name>/`;
- one route in `router.ex`;
- one entry in the ordered home page examples list;
- one supervised agent child in `application.ex`.

Concrete support-agent pattern:

```text
lib/jidoka_example/support_agent/agent.ex
lib/jidoka_example/support_agent/actions/lookup_order.ex
lib/jidoka_example_web/live/support_agent_live/index.ex
lib/jidoka_example_web/live/support_agent_live/view.ex
priv/support_agent/orders.json
```

```elixir
defmodule JidokaExample.SupportAgent.Agent do
  use Jidoka.Agent

  agent :support_agent do
    instructions "..."
  end

  tools do
    action JidokaExample.SupportAgent.Actions.LookupOrder
  end
end
```

```elixir
defmodule JidokaExampleWeb.SupportAgentLive.View do
  use Jidoka.AgentView, agent: JidokaExample.SupportAgent.Agent
end
```

The LiveView should render projection state and call the supervised process:

```elixir
with {:ok, pid} <- support_agent_pid() do
  Jidoka.turn(pid, input, opts)
end
```

Phoenix should not own agent logic. Phoenix owns presentation state, form state,
and source-inspection UI. Jido/Jidoka owns the agent process and turn state.

## Add An Example Checklist

1. Create `lib/jidoka_example/<example_name>/agent.ex`.
2. Create any actions in `lib/jidoka_example/<example_name>/actions/`.
3. Add fixtures or sample data in `priv/<example_name>/` when useful.
4. Add `lib/jidoka_example_web/live/<example_name>_live/index.ex`.
5. Add `lib/jidoka_example_web/live/<example_name>_live/view.ex`.
6. Supervise the agent in `JidokaExample.Application`.
7. Add the route in `JidokaExampleWeb.Router`.
8. Add the example metadata to the ordered list in `HomeLive`.
9. Add source-inspection entries inside the example LiveView.
10. Run `mix format`, `mix compile --warnings-as-errors`, and `mix phx.server`.

Keep the first slice small: one agent, one prompt surface, one meaningful tool
call, one visible activity projection.

## Runtime Configuration

The app should use `dotenvy` and load environment from these locations, in this
order:

1. `jidoka/.env`
2. `jidoka/example/.env`
3. the host process environment

The host process environment should win over file values.

Keep `.env` focused on provider credentials such as `OPENAI_API_KEY`,
`ANTHROPIC_API_KEY`, and `BRAVE_SEARCH_API_KEY`. Jidoka defaults belong in
application config or agent DSL, not `JIDOKA_*` environment variables.

Never commit real `.env` files. Commit `.env.example` files only.

## Runner Contract

The example app should support:

```bash
mix deps.get
mix jido_browser.install agent_browser --if-missing
mix phx.server
```

Optional CLI scripts are fine, but the web route should be the primary path.

The research agent depends on the local `agent_browser` binary installed by
`jido_browser`. The example runtime prefers that local binary so a different
global `agent-browser` install does not break the browser tools.

Example-specific tests are optional. For this showcase app, a clean format pass,
compile pass, and manual route check are enough unless an example adds behavior
that would be risky to validate by hand.

## UI Guidance

Use one LiveView per agent. Shared UI belongs in layouts or components only when
there is real repetition.

Keep the UI quiet and task-focused:

- left navigation for examples;
- a prompt panel;
- conversation output;
- model/status fields;
- an activity panel for tool calls and raw projections.

The UI is product-register UI: quiet, task-focused, system-font, restrained
color, familiar controls, and clear inspection affordances. Avoid marketing-page
composition, decorative cards, or in-app instructional copy that repeats what
the controls already say.

When adding more examples, keep the home page driven from an ordered examples
list so route order is explicit.

## Reset And Sessions

The current examples are intentionally ephemeral. A "New session" button may
reset the local UI projection and restart the supervised demo agent process.

Do not reintroduce app-local session stores, plugs, ETS tables, or GenServers
for demo persistence. Durable sessions are a Jidoka feature, not a Phoenix
example concern. When durable sessions are demonstrated, build that example
against the public Jidoka session/harness APIs.

## DSL Guidance

Examples should use the public `Jidoka.Agent` DSL and regular `Jidoka.Action`
tools. Avoid lower-level runtime modules unless the example is specifically
about harness internals.

Prefer simple DSL examples:

- `agent :id do ... end`
- `context Zoi.object(...)` when the example needs typed runtime context
- `instructions "..."`
- `generation %{params: %{...}}` only when the example needs it
- `controls do max_turns ... timeout ... end` for operational bounds
- `controls do output MyControl end` for final-result policy checks
- `controls do operation MyControl, when: [...] end` for review before side effects
- `tools do action MyAction end`
- `tools do skill MySkill end` for Jido.AI skill prompt/action bundles
- `tools do mcp_tools ... end` for MCP-backed operation sources
- `tools do browser :public_web, mode: :read_only end` for search plus page reads
- `tools do ash_resource MyResource end` for AshJido generated Jido actions
- `memory %{scope: :session, max_entries: 5}` for examples that demonstrate Jidoka memory

Debugging examples should use the public `Jidoka.inspect/1` and
`Jidoka.preflight/3` APIs rather than reaching into turn internals directly.

Do not add a plugin DSL or hook DSL to examples. V2 examples should model V1
hook use cases through explicit controls, operation review, trace/events, or
ordinary actions.

Do not add abstractions ahead of need. The value of this app is that a new
developer can see the minimal shape and copy it.
