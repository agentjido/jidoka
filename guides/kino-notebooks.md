# Kino Notebooks

This guide explains the optional Livebook helpers in
[`Jidoka.Kino`](`Jidoka.Kino`). The Kino module is **not** a runtime
dependency: every helper compiles without Kino installed and degrades to a
no-op rendering boundary outside Livebook. The helpers are thin wrappers
around stable Jidoka contracts (`Jidoka.inspect/1`, `Jidoka.preflight/3`,
`Jidoka.Harness`, `Jidoka.Turn.Result`). By the end you will be able to set up
a notebook, mirror Livebook provider secrets, debug an agent definition,
render a preflight, run a chat cell deterministically, and start an agent
process that survives notebook re-evaluation.

## When To Use This

- Use this guide when you want a Livebook to demonstrate, debug, or evaluate
  a Jidoka agent.
- Use this guide to keep notebook cells idempotent across re-evaluation.
- Do **not** add `Jidoka.Kino` calls to library code or production callers.
  These helpers exist for human inspection in notebooks; they render tables
  and Markdown that have no meaning outside Livebook.

## Prerequisites

- A working Jidoka DSL agent. See [Getting Started](getting-started.md).
- Livebook with `:kino` available, when you want rendered output. Without
  Kino loaded, the helpers still return their data but skip rendering.
- For deterministic notebooks: no provider keys are required.
- For live notebooks: a provider key in scope (`OPENAI_API_KEY`,
  `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`) or the matching Livebook secret
  (`LB_*`). `Jidoka.Kino.load_provider_env/1` mirrors `LB_*` into the
  standard provider env so ReqLLM can find it.

## Quick Example

A minimum useful notebook cell sequence:

```elixir
Mix.install([
  {:kino, "~> 0.14"},
  {:jidoka, "~> 0.1"}
])
```

```elixir
Jidoka.Kino.setup_notebook(model: "test:notebook-model", check_provider?: false)
```

```elixir
defmodule Notebook.TimeAgent do
  use Jidoka.Agent

  agent :notebook_time_agent do
    model %{provider: :test, id: "notebook-model"}
    instructions "Use a deterministic LLM for the demo."
  end
end

{:ok, _inspection} = Jidoka.Kino.debug_agent(Notebook.TimeAgent)
```

```elixir
Jidoka.Kino.chat("notebook demo", fn ->
  llm = fn _intent, _journal ->
    {:ok, %{type: :final, content: "Hello from a deterministic notebook."}}
  end

  Jidoka.turn(Notebook.TimeAgent, "Say hello.", llm: llm)
end)
```

That sequence prints a setup table, a summary of the agent, and a turn
result table - all without contacting any provider.

## Concepts

```diagram
╭────────────────────────────╮     ╭─────────────────────────╮
│ Livebook cells              │────▶│ Jidoka.Kino             │
│  (setup, debug, chat, trace)│     │  thin wrappers          │
╰─────────────┬──────────────╯     ╰────┬──────────┬─────────╯
              │                          │          │
              │                          ▼          ▼
              │                ╭─────────────╮   ╭─────────────╮
              │                │ Jidoka      │   │ Kino.Render │
              │                │ Jidoka.*    │   │ tables/md   │
              │                ╰──────┬──────╯   ╰─────────────╯
              │                       │
              ▼                       ▼
   provider secrets         deterministic data
   (LB_* mirrored to        from Jidoka contracts
    OPENAI_API_KEY, etc.)   (Spec/Plan/Result/Snapshot)
```

Four concepts cover Kino integration:

1. **Optional rendering.** Every helper returns a stable value first and
   renders second. If Kino is not loaded, rendering is a no-op and the
   returned value is unchanged.
2. **Secret mirroring.** Livebook stores secrets under `LB_*` env names.
   `load_provider_env/1` finds the first matching `LB_*` value and mirrors it
   into the canonical provider env name (`OPENAI_API_KEY`, etc.).
3. **Repeatable cells.** `start_or_reuse/3` makes hosted-agent cells
   idempotent across re-evaluation by reusing an already-registered agent
   instead of starting a new one.
4. **Stable data shapes.** Each helper takes either a module, spec, plan,
   session, snapshot, or result and projects it through the Jidoka inspection
   pipeline. The tables you see are derived, not bespoke.

### Security / Trust Boundaries

- `Jidoka.Kino` never persists secrets, never writes to disk, and never
  changes `Application.put_env/3`. The only mutation it performs is
  `System.put_env/2` to mirror a `LB_*` secret into the matching provider
  env name.
- `load_provider_env/1` searches an explicit allowlist of env names. The
  default list is the standard ReqLLM providers; pass a custom list when you
  need additional names.
- `debug_agent/2`, `preflight/3`, and `timeline/2` only project values that
  already exist in `Jidoka.Agent.Spec`, `Turn.Plan`, `Turn.Result`,
  `AgentSnapshot`, and the trace event journal. No new data crosses a trust
  boundary.
- `chat/3` with `require_provider?: true` short-circuits to an `{:error,
  message}` when no provider secret is in scope. This prevents accidental
  live calls in a deterministic notebook.
- `start_or_reuse/3` returns an existing pid when one is registered. Trust
  that registration the same way you would trust any
  `Jidoka.whereis/2` result; do not rely on it as an authentication step.

## How To

### Step 1: Set Up The Notebook

`setup_notebook/1` renders a small status table and returns the same summary
as a plain map. Use it as the first executable cell.

```elixir
%{
  model: model,
  provider: provider,
  live_provider?: live?
} =
  Jidoka.Kino.setup_notebook(
    model: "openai:gpt-4o-mini",
    check_provider?: true
  )
```

Set `check_provider?: false` when the notebook is intended to be fully
deterministic. The table will then show `not required for deterministic
notebook` instead of probing for credentials.

### Step 2: Mirror A Livebook Secret

When the notebook needs a real provider, mirror the Livebook secret first.

```elixir
{:ok, "LB_OPENAI_API_KEY"} = Jidoka.Kino.load_provider_env()
```

After that call, `OPENAI_API_KEY` is set in the BEAM env and ReqLLM can
pick it up. Pass a custom list when you want a different precedence:

```elixir
Jidoka.Kino.load_provider_env(["ANTHROPIC_API_KEY", "LB_ANTHROPIC_API_KEY"])
```

### Step 3: Debug An Agent Definition

`debug_agent/2` projects a module, plan, session, or result into a table.

```elixir
{:ok, inspection} = Jidoka.Kino.debug_agent(MyApp.TimeAgent)
inspection.kind
#=> :agent
```

The returned map is the same value `Jidoka.inspect/2` returns - the helper
just renders it. Use it to confirm operations, controls, and timeouts before
running a turn.

### Step 4: Preflight Without A Provider

`preflight/3` calls `Jidoka.preflight/3` and renders a table of prompt
messages, plus a small timeline of preflight events.

```elixir
{:ok, preflight} =
  Jidoka.Kino.preflight(MyApp.TimeAgent, "What time is it in Chicago?")

length(preflight.prompt.messages)
#=> 2
```

This is the cheapest way to confirm the prompt and operation list are wired
correctly before you spend a token.

### Step 5: Run A Deterministic Chat Cell

`chat/3` runs a function, formats the result, and renders a one-row summary
table.

```elixir
Jidoka.Kino.chat("deterministic time turn", fn ->
  llm = fn _intent, _journal ->
    {:ok, %{type: :final, content: "Chicago time is 09:30."}}
  end

  Jidoka.turn(MyApp.TimeAgent, "What time is it in Chicago?", llm: llm)
end)
```

`require_provider?: true` makes the cell fail fast when no provider key is
in scope. Use it on live-only cells so a missing secret turns into a
predictable error instead of a hang or a partial result.

### Step 6: Trace A Run

`trace/3` wraps any function call and renders a Jidoka timeline derived from the
result.

```elixir
result =
  Jidoka.Kino.trace("supervised turn", fn ->
    Jidoka.turn(MyApp.TimeAgent, "Hello", llm: deterministic_llm())
  end)
```

The wrapped result is returned unchanged. Pair with
`Jidoka.Kino.timeline/2` or `Jidoka.Kino.call_graph/2` when you want a
separate cell to inspect the same data later.

### Step 7: Start An Agent Once Per Notebook Session

Plain `MyApp.TimeAgent.start(id: "demo")` raises on the second cell
evaluation because the id is already registered. `start_or_reuse/3` returns
the existing pid instead.

```elixir
{:ok, pid} =
  Jidoka.Kino.start_or_reuse("notebook-time-agent", fn ->
    MyApp.TimeAgent.start(id: "notebook-time-agent")
  end)
```

The second cell evaluation returns the same pid without restarting the
process, which keeps any in-memory session state intact.

### Step 8: Render Context Maps Without Leaking Internals

`context/3` separates the public and internal halves of a runtime context
map and renders them as two tables.

```elixir
Jidoka.Kino.context("turn context", %{
  public: %{tenant: "acme"},
  internal: %{actor_id: "u-1"}
})
```

This is the right surface for notebooks that demonstrate context plumbing
without inviting copy-paste of secret values.

## Common Patterns

- **Pin the model with `model:`** in `setup_notebook/1`. The default reads
  `Jidoka.Config.default_model/0`, which depends on application config.
  Pinning makes the notebook reproducible across machines.
- **Set `check_provider?: false` for deterministic demos.** It avoids
  spurious "missing credentials" rows in the setup table.
- **Wrap process-hosted cells with `start_or_reuse/3`.** This is the only
  reliable way to make hosted-agent notebooks idempotent.
- **Use `chat/3` with deterministic LLMs by default.** Reach for
  `require_provider?: true` only when the cell intentionally calls a
  provider.

## Testing

`Jidoka.Kino` is tested through `test/jidoka/kino_test.exs`. The same
pattern is the easiest way to confirm a notebook helper behaves the way you
expect locally:

```elixir
defmodule MyApp.NotebookHelpersTest do
  use ExUnit.Case, async: true

  test "setup_notebook returns a summary map even without Kino loaded" do
    summary =
      Jidoka.Kino.setup_notebook(
        model: "test:notebook-model",
        check_provider?: false,
        render?: false
      )

    assert summary.model == "test:notebook-model"
    refute summary.live_provider?
  end

  test "start_or_reuse returns the existing pid on the second call" do
    {:ok, pid_a} =
      Jidoka.Kino.start_or_reuse("kino-demo-agent", fn ->
        MyApp.TimeAgent.start(id: "kino-demo-agent")
      end)

    {:ok, ^pid_a} =
      Jidoka.Kino.start_or_reuse("kino-demo-agent", fn ->
        MyApp.TimeAgent.start(id: "kino-demo-agent")
      end)
  end
end
```

`render?: false` is the most useful test option because it skips the table
rendering path entirely.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `chat/3` returns `{:error, message}` immediately | `require_provider?: true` and no `*_API_KEY` is in scope. | Mirror the secret with `load_provider_env/1` or remove the flag for deterministic cells. |
| `setup_notebook` always shows `missing <provider> credentials` | The Livebook secret is named differently than expected. | Pass `provider_env: ["LB_MY_KEY"]` to override the lookup list. |
| `start_or_reuse/3` starts a new agent every evaluation | The id changes between cell runs. | Use a stable string id, not one derived from `System.unique_integer/0`. |
| `debug_agent/2` returns `{:error, message}` | The target is not a Jidoka inspectable value. | Pass a module, spec, plan, session, snapshot, or result. |
| Tables render as raw Markdown lists | The notebook is not running under Livebook. | Expected; outside Livebook, rendering is a no-op and the returned values are still correct. |

## Reference

Key modules touched in this guide:

- [`Jidoka.Kino`](`Jidoka.Kino`) - public surface: `setup_notebook/1`,
  `debug_agent/2`, `preflight/3`, `chat/3`, `trace/3`, `timeline/2`,
  `context/3`, `start_or_reuse/3`, `load_provider_env/1`.
- Runtime setup helper - notebook
  summary and provider-env mirroring.
- Chat helper - chat-cell formatting.
- Agent view helper - debug/preflight
  rendering.
- Trace view helper - trace, timeline, call
  graph.
- [`Jidoka.Config`](`Jidoka.Config`) - default model used by
  `setup_notebook/1` when one is not supplied.

## Related Guides

- [Getting Started](getting-started.md) - the smallest DSL agent end to end.
- [Inspection And Preflight](inspection-and-preflight.md) - the plain
  (non-notebook) versions of `inspect/2` and `preflight/3`.
- [Tracing And Events](tracing-and-events.md) - the timeline data structure
  Kino renders.
- [Configuration](configuration.md) - where the default model and other
  knobs come from.
- [Jido Process Integration](jido-process-integration.md) - the underlying
  process API used by `start_or_reuse/3`.
