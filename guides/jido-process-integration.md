# Jido Process Integration

This guide explains how a Jidoka DSL agent becomes a supervised `Jido.AgentServer`
process. It covers the default `Jidoka.Jido` runtime instance, the
`start_agent` / `stop_agent` / `whereis` helpers, the generated `child_spec/1`,
the `"jidoka.turn.run"` signal flow, and how the typed Jidoka state is read back
out of `Jido.Agent.state[:jidoka]`. By the end you will be able to host an agent
under a supervisor, run a turn against the registered id, and inspect its
status.

## When To Use This

- Use this guide when you want a long-lived, addressable agent process: shared
  across requests, restartable, supervised, callable by id.
- Use this guide when you need `await_completion`, hibernation, or to wire an
  agent into a Phoenix `application.ex`.
- Do **not** use this guide for single-shot deterministic runs. For unit tests
  and one-off invocations, `MyAgent.run_turn/2` and `Jidoka.turn/3` against the
  spec are simpler and faster. See [Runtime And Harness](runtime-and-harness.md).

## Prerequisites

- A working Jidoka DSL agent module. See [Getting Started](getting-started.md).
- Elixir `~> 1.18` and `:jidoka` resolved through `mix deps.get`.
- The default `Jidoka.Jido` instance only needs to be in your supervision tree
  if you want supervisor-restartable agents. Direct `Jidoka.start_agent/2`
  calls in IEx will start it on demand under the application supervisor.

### Setup

Jidoka ships a default Jido runtime instance,
[`Jidoka.Jido`](`Jidoka.Jido`), which is just `use Jido, otp_app: :jidoka`.
That single supervisor owns the registry, dynamic supervisor, task supervisor,
and runtime store that hosted agents need.

Application config:

```elixir
# config/config.exs
import Config

config :jidoka,
  default_model: "openai:gpt-4o-mini"
```

Supervision tree:

```elixir
# lib/my_app/application.ex
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Jidoka.Jido,
      {MyApp.TimeAgent, jido: Jidoka.Jido}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: MyApp.Supervisor)
  end
end
```

Credentials for live turns (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, etc.) belong
in the host process environment. Jidoka itself does not read `.env` files.

### Security / Trust Boundaries

- The `Jidoka.Jido` registry is process-local; agent ids are not a global
  namespace. Two applications can each host an agent with id `"time-agent-1"`
  under their own instance without collision.
- `Jidoka.Jido.start_agent/2` accepts a module, which the caller controls.
  Never pass untrusted module names from external input; resolve through your
  own allowlist first.
- Provider credentials are taken from the process environment by ReqLLM. They
  are never written into `Agent.Spec`, snapshots, or journals.
- Inspect normalized errors with `Jidoka.error_to_map/1`; credential-shaped
  values are sanitized before being returned.

## Quick Example

Start a DSL agent under the default `Jidoka.Jido` supervisor and run a turn
against its registered id.

```elixir
defmodule MyApp.LocalTime do
  use Jidoka.Action,
    name: "local_time",
    description: "Returns the local time for a city.",
    schema: Zoi.object(%{city: Zoi.string() |> Zoi.default("Chicago")})

  @impl true
  def run(params, _context) do
    city = Map.get(params, :city) || Map.get(params, "city") || "Chicago"
    {:ok, %{city: city, time: "09:30"}}
  end
end

defmodule MyApp.TimeAgent do
  use Jidoka.Agent

  agent :time_agent do
    instructions "Use local_time when asked for the time."
  end

  tools do
    action MyApp.LocalTime
  end
end

{:ok, _pid} = MyApp.TimeAgent.start(id: "time-agent-1")
{:ok, "Chicago time is 09:30."} =
  Jidoka.chat("time-agent-1", "What time is it in Chicago?", llm: fake_llm())
```

The DSL module, the spec, and the plan are the same as the in-process flow.
Only the execution boundary differs: `Jidoka.chat/3` resolves the binary id
through [`Jidoka.whereis/2`](`Jidoka`) and sends a signal to the
`Jido.AgentServer`.

## Concepts

```diagram
╭───────────────╮      start_agent       ╭────────────────────╮
│ MyApp.Agent   │───────────────────────▶│  Jidoka.Jido       │
│ (DSL module)  │                        │  (registry +       │
╰───────┬───────╯                        │   dyn supervisor)  │
        │ child_spec/1                   ╰─────────┬──────────╯
        ▼                                          │
╭───────────────────╮  "jidoka.turn.run"           ▼
│ Jido.AgentServer  │◀────────── signal ─── Jidoka.turn(id, ...)
│  state[:jidoka] = │
│  AgentServerState │──── routes to ────▶ Jidoka.Runtime.Actions.RunTurn
╰─────────┬─────────╯                            │
          │                                      ▼
          │                            ╭──────────────────────╮
          │                            │ Jidoka.Harness       │
          │                            │ (Runic + Effects)    │
          │                            ╰──────────┬───────────╯
          ▼                                       ▼
   to_jido_state/1                         Turn.Result / Snapshot
```

Three pieces define this boundary:

1. **[`Jidoka.Jido`](`Jidoka.Jido`)** is a `use Jido, otp_app: :jidoka`
   supervisor. It owns the registry, dynamic supervisor, task supervisor, and
   runtime store. Applications may host their own instance instead.
2. **The DSL module's `child_spec/1`** wraps `Jido.AgentServer.child_spec/1`
   with `jido: Jidoka.Jido` and a default id derived from the agent module.
   The compiled signal route `{"jidoka.turn.run", Jidoka.Runtime.Actions.RunTurn}`
   is attached at compile time.
3. **[`Jidoka.Runtime.AgentServerState`](`Jidoka.Runtime.AgentServerState`)**
   is the typed Jidoka state stored under `agent.state[:jidoka]`. Conventional
   top-level Jido fields (`:status`, `:last_answer`, `:error`) are kept for
   `Jido.AgentServer` compatibility.

## How To

### Step 1: Start An Agent Under The Default Runtime

The DSL module exposes `start/1`, which calls `Jidoka.start_agent/2`, which
delegates to `Jidoka.Jido.start_agent/2`:

```elixir
{:ok, pid} = MyApp.TimeAgent.start(id: "time-agent-1")
^pid = Jidoka.whereis("time-agent-1")
```

If `id:` is omitted, the agent module supplies one derived from its DSL agent
id (`:time_agent` becomes `"time_agent"`).

### Step 2: Supervise An Agent In Your Application

For production callers, prefer `child_spec/1` over `start_agent/2` so the agent
restarts with the rest of your tree:

```elixir
children = [
  Jidoka.Jido,
  {MyApp.TimeAgent, jido: Jidoka.Jido, id: "time-agent-1"}
]

Supervisor.start_link(children, strategy: :rest_for_one, name: MyApp.Supervisor)
```

`MyApp.TimeAgent.child_spec/1` calls `Jido.AgentServer.child_spec/1` with the
right defaults. The `:rest_for_one` strategy ensures that a restart of
`Jidoka.Jido` also restarts the agents that depend on its registry.

### Step 3: Run A Turn Against A Registered Id

The facade accepts a process ref (pid, registered binary id, or `:via` tuple):

```elixir
{:ok, %Jidoka.Turn.Result{} = result} =
  Jidoka.turn("time-agent-1", "What time is it in Chicago?",
    timeout: 30_000,
    llm: fake_llm()
  )

result.content
#=> "Chicago time is 09:30."
```

Under the hood [`Jidoka`](`Jidoka`):

1. Builds a signal with `Jidoka.Runtime.Signals.turn_run/2` (type
   `"jidoka.turn.run"`).
2. Resolves the binary id through `Jidoka.whereis/2`.
3. Calls `Jido.AgentServer.call(pid, signal, timeout)` which routes to
   `Jidoka.Runtime.Actions.RunTurn`.
4. Reads the typed result back out of `agent.state[:jidoka]` and returns
   `{:ok, Turn.Result.t()}`, `{:hibernate, snapshot}`, or `{:error, reason}`.

### Step 4: Read State Out Of A Hosted Agent

The current Jidoka state can be inspected directly:

```elixir
agent = :sys.get_state(Jidoka.whereis("time-agent-1")).agent

{:ok, jidoka_state} =
  Jidoka.Runtime.AgentServerState.from_jido_state(agent.state)

jidoka_state.status        #=> :completed
jidoka_state.result.content
```

`from_jido_state/1` reads `state[:jidoka]` and returns the typed
`AgentServerState`. Use `to_run_result/1` to convert it back into the
`{:ok, ...} | {:hibernate, ...} | {:error, ...}` envelope.

### Step 5: Await Terminal Status

Most callers will just block on `Jidoka.turn/3`, but for fire-and-forget signal
dispatch you can wait for a terminal Jido status:

```elixir
{:ok, status_map} =
  Jidoka.await_agent("time-agent-1", timeout: 30_000)

status_map.status
#=> :completed
```

`await_agent/2` is only meaningful for process-hosted agents. It is a thin
wrapper around `Jido.AgentServer.await_completion/2` with Jidoka error
normalization.

### Step 6: Stop An Agent

```elixir
:ok = Jidoka.stop_agent("time-agent-1")
```

`stop_agent/2` accepts a pid or the registered binary id. It returns
`{:error, :not_found}` if the id has no running process.

## Common Patterns

- **Treat the registered id as your routing key.** Phoenix controllers and
  LiveViews should call `Jidoka.turn(id, ...)` instead of looking up a pid and
  threading it through assigns.
- **Use a custom Jido instance per app boundary.** If a host app already
  defines `MyApp.Jido`, pass `jido: MyApp.Jido` to the child spec so the agent
  lives under that supervisor instead of `Jidoka.Jido`.
- **Prefer `:rest_for_one`** when supervising agents alongside `Jidoka.Jido`
  so the registry and the agents that depend on it restart together.
- **Inspect with `Jidoka.inspect/1`.** Run it on the pid or registered id when
  you want a stable, human-readable view of agent status without poking into
  the raw `state[:jidoka]` struct.

## Testing

Process-hosted tests use the same deterministic capabilities as direct turns.
The test owns the supervised process; the runtime opts are forwarded as the
signal's `runtime_opts` and threaded into `RunTurn`.

```elixir
defmodule MyApp.TimeAgentTest do
  use ExUnit.Case, async: true

  setup do
    start_supervised!(Jidoka.Jido)
    id = "time-agent-#{System.unique_integer([:positive])}"
    start_supervised!({MyApp.TimeAgent, jido: Jidoka.Jido, id: id})
    %{id: id}
  end

  test "answers the time against a hosted agent", %{id: id} do
    llm = fn _intent, journal, _ctx ->
      llm_calls =
        Enum.count(journal.results, fn {_id, r} -> r.kind == :llm end)

      case llm_calls do
        0 ->
          {:ok,
           %{type: :operation, name: "local_time", arguments: %{"city" => "Chicago"}}}

        1 ->
          {:ok, %{type: :final, content: "Chicago time is 09:30."}}
      end
    end

    assert {:ok, "Chicago time is 09:30."} =
             Jidoka.chat(id, "What time is it in Chicago?", llm: llm)
  end
end
```

The fake `llm` is the same shape used in [Getting Started](getting-started.md).
No provider key is required.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, :not_found}` from `turn/3` or `stop_agent/2` | The binary id is not registered in `Jidoka.Jido`. | Confirm with `Jidoka.whereis(id)`. Start with `MyAgent.start(id: ...)` or supervise via `child_spec/1`. |
| `{:error, %Jidoka.Error{} = e}` with `phase: :agent_server` | `RunTurn` failed to build a valid request (missing `:input` or agent module context). | Send a non-empty string and verify the agent module compiled cleanly with `Jidoka.inspect(MyAgent)`. |
| Process exits when `Jidoka.Jido` restarts | Agents were supervised with `:one_for_one`. | Use `:rest_for_one` so hosted agents restart with the registry. |
| `await_agent/2` times out with `:idle` hint | No turn was ever sent; the agent has no work to wait on. | Send a `turn/3` or `chat/3` before awaiting, or skip `await_agent` and use the synchronous facade. |
| Different apps clash on the same id | They share the same `Jidoka.Jido` instance. | Each app should `use Jido, otp_app: :my_app` and host its own runtime instance. |

## Reference

Key modules touched in this guide:

- [`Jidoka.Jido`](`Jidoka.Jido`) - default Jido runtime instance for Jidoka
  agents.
- [`Jidoka`](`Jidoka`) - `start_agent/2`, `stop_agent/2`, `whereis/2`,
  `await_agent/2`, `turn/3`, `chat/3`.
- [`Jidoka.Agent`](`Jidoka.Agent`) - DSL module that injects `start/1` and
  `child_spec/1` for hosted agents.
- [`Jidoka.Runtime.Signals`](`Jidoka.Runtime.Signals`) - constructor for the
  `"jidoka.turn.run"` signal.
- [`Jidoka.Runtime.Actions.RunTurn`](`Jidoka.Runtime.Actions.RunTurn`) - Jido
  action that runs the harness inside the agent server.
- [`Jidoka.Runtime.AgentServerState`](`Jidoka.Runtime.AgentServerState`) -
  typed Jidoka state stored under `agent.state[:jidoka]`.

## Related Guides

- [Getting Started](getting-started.md) - the smallest DSL agent end to end.
- [Runtime And Harness](runtime-and-harness.md) - sessions, snapshots,
  effects, and memory.
- [Live LLM Tool Loop](live-llm-tool-loop.md) - running a hosted agent
  against a real provider.
- [AshJido Resources](ash-jido.md) - exposing Ash actions as agent tools.
- [Browser Tools](browser-tools.md) - hosted agents that read the web.
- [MCP Tools](mcp-tools.md) - hosted agents that call external MCP servers.
