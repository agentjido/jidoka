# Inspection And Preflight

Use `Jidoka.inspect/2`, `Jidoka.preflight/3`, and `Jidoka.project/1` before
spending tokens. They show what the agent compiled to, what prompt would be
sent, and what data shape your UI or tests can consume.

## Use This When

- an agent looks correct but behaves unexpectedly at runtime;
- comparing a DSL-authored spec with an imported one;
- writing golden tests against compact, deterministic
  projections.

## Prerequisites

- A working Jidoka agent module (see [Getting Started](getting-started.md)).
- Familiarity with the operation contract from
  [Tools And Operations](tools-and-operations.md).
- No provider keys are required; these calls do not contact an LLM.

```bash
mix deps.get
mix test
```

## Inspect An Agent

Start with `inspect/2`, then use `preflight/3` to assemble the exact prompt the
next turn would send.

```elixir
defmodule MyApp.TimeAgent do
  use Jidoka.Agent

  agent :time_agent do
    model "openai:gpt-4o-mini"
    instructions "Call local_time when asked for the time."
  end

  tools do
    action MyApp.Tools.LocalTime
  end
end

Jidoka.inspect(MyApp.TimeAgent)
#=> %{kind: :agent, module: "MyApp.TimeAgent",
#=>   spec: %{id: "time_agent", operations: [%{name: "local_time", ...}], ...},
#=>   plan: %{...}}

{:ok, preflight} = Jidoka.preflight(MyApp.TimeAgent, "What time is it?")
preflight.prompt.messages
preflight.prompt.tool_definitions
preflight.diagnostics
```

Nothing was sent over the network. The view shows what Jidoka would send if
the turn ran for real.

## Concepts

The three functions cover three layers of the data-first runtime.

1. **`Jidoka.project/1`** is the low-level projector. It turns Jidoka data
   contracts (`Agent.Spec`, `Turn.Plan`, `Turn.Result`, `Effect.Journal`,
   etc.) into JSON-friendly maps. Use it when you need raw
   compact data for tests, traces, or external rendering.
2. **`Jidoka.inspect/2`** is the human-facing wrapper. It dispatches on the
   value's struct and returns a tagged map with a `:kind` key plus the
   most useful fields for that kind. Internally it calls `project/1` and
   often adds a timeline view, a status badge, or related context.
3. **`Jidoka.preflight/3`** is the only one that takes a request. It runs
   the workflow up to the point where the prompt is ready, but stops
   before the LLM intent or any operation intent is interpreted. The
   returned `Jidoka.Inspection.Preflight` struct shows the normalized
   agent, plan, request, prompt, events, timeline, and diagnostics.

```diagram
╭───────────────╮   project    ╭───────────────────╮
│ Jidoka.value  │─────────────▶│ Stable data map   │
╰───────┬───────╯              ╰───────────────────╯
        │
        │ inspect              ╭───────────────────╮
        ╰─────────────────────▶│ %{kind: ..., ...} │
                               ╰───────────────────╯

╭────────────────╮   preflight  ╭──────────────────────╮
│ spec / module  │─────────────▶│ Inspection.Preflight │
│ + request_input│              │ - agent              │
╰────────────────╯              │ - plan               │
                                │ - request            │
                                │ - prompt             │
                                │ - events             │
                                │ - timeline           │
                                │ - diagnostics        │
                                ╰──────────────────────╯
```

### Picking The Right Function

| Question | Tool | Effect-free? |
| --- | --- | --- |
| "What did the DSL/import compile to?" | `Jidoka.inspect(agent_or_spec)` | yes |
| "What workflow graph did this module compile to?" | `Jidoka.inspect(workflow_module)` | yes |
| "How does this turn input shape the prompt?" | `Jidoka.preflight(agent, input)` | yes |
| "What is the deterministic projection of this value?" | `Jidoka.project(value)` | yes |
| "What happened during the turn that just ran?" | `Jidoka.inspect(turn_result)` | yes |
| "Debug the exact request that just ran." | `Jidoka.Debug.request(turn_result)` | yes |
| "Replay this snapshot." | `Jidoka.resume(snapshot, opts)` | no, runs effects |

## How To

### Step 1: Inspect An Agent Module Or Spec

`Jidoka.inspect/2` accepts a DSL agent module, an `Agent.Spec`, a
`Turn.Plan`, or any other Jidoka value. For modules and specs it returns a
combined view with the compiled plan attached.

```elixir
view = Jidoka.inspect(MyApp.TimeAgent)
view.kind
#=> :agent

view.module
#=> "MyApp.TimeAgent"

view.spec.id
#=> "time_agent"

view.spec.operations
#=> [%{name: "local_time", idempotency: :idempotent, metadata: %{...}}]

view.plan.prompt_strategy
#=> :default
```

For raw structs (Effect intents, results, sessions, eval runs) inspect
dispatches on the struct and returns the matching tagged view.

### Step 2: Inspect A Workflow Module

`Jidoka.inspect/1` also accepts `Jidoka.Workflow` modules. Use this before
exposing a workflow as an agent tool.

```elixir
view = Jidoka.inspect(MyApp.Workflows.RefundReview)

view.kind
#=> :workflow

view.workflow.id
#=> "refund_review"

Enum.map(view.workflow.steps, &{&1.name, &1.kind})
#=> [check_policy: :function, queue_refund: :action]

view.workflow.parameters_schema?
#=> true
```

When the same workflow is registered in an agent, inspect the agent operation
metadata to confirm the model-visible name, result mode, timeout, and
parameters schema:

```elixir
Jidoka.inspect(MyApp.SupportAgent).spec.operations
|> Enum.find(&(&1.metadata.source == "workflow"))
|> Map.take([:name, :idempotency, :metadata])
```

### Step 3: Preflight A Turn

`Jidoka.preflight/3` mirrors `Jidoka.turn/3`'s arguments minus the
capabilities. It validates the context, calls `Memory.Runtime.recall/3`
(passing through `memory_store:` and `session_id:` like a real turn),
and runs `Steps.assemble_prompt/1` to build the final messages.

```elixir
{:ok, preflight} =
  Jidoka.preflight(MyApp.TimeAgent, "What time is it?",
    context: %{tenant_id: "acme"},
    request_id: "req-1"
  )

Enum.map(preflight.prompt.messages, & &1.role)
#=> [:system, :user]

preflight.prompt.tool_definitions
|> Enum.map(& &1.name)
#=> ["local_time"]

preflight.request.input
#=> "What time is it?"

preflight.diagnostics
#=> []
```

A non-empty `diagnostics` list flags issues the prompt assembler noticed
(missing memory entries, oversized tool descriptions, etc.).

### Step 4: Inspect Operation Metadata

When you need to confirm `controls do operation ... when: [...] end` will
match, project the operations:

```elixir
MyApp.TimeAgent
|> Jidoka.inspect()
|> Map.fetch!(:spec)
|> Map.fetch!(:operations)
|> Enum.map(&Map.take(&1, [:name, :idempotency, :metadata]))
```

The `metadata` map is the exact shape control `when:` clauses match
against (`:kind`, `:name`, `:source`, `:idempotency`, and any free-form
keys).

### Step 5: Project Turn Results And Journals

After a turn, project the result for assertions and external rendering.

```elixir
{:ok, result} = Jidoka.turn(MyApp.TimeAgent, "ping")

projected = Jidoka.project(result)
projected.content
#=> "now"

projected.journal.intent_count
#=> 1
```

`Jidoka.inspect(result)` returns a richer map with a `:timeline` and
`:status` already filled in - useful for log output during development.

### Step 6: Debug A Completed Request

`Jidoka.Debug.request/2` assembles one request-level view from a result,
session, snapshot, or replay. Use it when you want the prompt, operation
calls, usage, timeline, journal, and replay diagnostics in one place.

```elixir
{:ok, result} = Jidoka.turn(MyApp.TimeAgent, "What time is it?", llm: llm)

{:ok, summary} = Jidoka.Debug.request(result)

summary.request_id
summary.prompt.messages
summary.operation_names
summary.operation_results
summary.usage
summary.replay_diagnostics.status
#=> :complete
```

The summary is a typed `Jidoka.Debug.RequestSummary`:

```elixir
%Jidoka.Debug.RequestSummary{
  request_id: "turn_...",
  agent_id: "time_agent",
  status: :finished,
  model: "openai:gpt-4o-mini",
  input: "What time is it?",
  content: "It is 09:30 in Chicago.",
  context_keys: [],
  operation_names: ["local_time"],
  usage: %{llm_calls: 2, total_tokens: 184},
  replay_diagnostics: %Jidoka.Debug.ReplayDiagnostics{status: :complete}
}
```

The summary is data-only. It does not call an LLM, tool, memory store, or
runtime capability. For sessions, use `Jidoka.Debug.latest(session)` or pass
`request_id:` when you need a specific hibernated request. Unknown request ids
return `{:error, {:request_debug_not_found, session_id, request_id}}` instead
of falling back to the latest request.

For hibernated snapshots and sessions, the same call exposes pending review
data and incomplete effects:

```elixir
{:hibernate, session, snapshot} = Jidoka.Session.run(session, "Refund A1001")

{:ok, summary} = Jidoka.Debug.request(snapshot, session: session)

summary.status
#=> :waiting

summary.pending_reviews
#=> [%{operation: "refund_order", ...}]

summary.replay_diagnostics.status
#=> :waiting
```

### Step 7: Inspect A Snapshot Or Session

When a turn hibernates (typically because an operation control
returned `{:interrupt, _}`), `inspect/2` produces a snapshot view that
exposes the cursor, journal, and pending review request.

```elixir
case Jidoka.turn(MyApp.TimeAgent, "ping") do
  {:hibernate, snapshot} ->
    view = Jidoka.inspect(snapshot)
    view.kind
    #=> :snapshot

    view.cursor
    view.timeline

  {:ok, result} ->
    Jidoka.inspect(result)
end
```

For sessions, `Jidoka.inspect(session)` adds replay metadata, snapshot
count, pending reviews, and the latest cursor. Sessions are documented in
[Runtime And Harness](runtime-and-harness.md); the inspection view is the
debugging entry point for them.

Replay diagnostics explain whether recorded effect data is complete:

```elixir
{:ok, replay} = Jidoka.Session.replay(session)
{:ok, diagnostics} = Jidoka.Harness.Replay.diagnose(replay)

diagnostics.status
#=> :complete | :waiting | :failed | :incomplete
```

Status meanings:

| Status | Meaning |
| --- | --- |
| `:complete` | Every recorded effect intent has a result. |
| `:waiting` | A human review request is still pending. |
| `:failed` | An effect result or timeline event failed. |
| `:incomplete` | At least one effect intent has no recorded result. |

### Step 8: Use Inspect For Logging

Because every view is a plain map, it serializes cleanly:

```elixir
require Logger

Logger.info(MyApp.TimeAgent |> Jidoka.inspect() |> :json.encode())
```

When you only want a subset, lower with `Jidoka.project/1` first and
`Map.take/2` the keys you care about. This is the recommended pattern for
production traces; `inspect/2` is the developer view.

## Common Patterns

- **Preflight before live calls.** The first sanity check for a new agent
  is `Jidoka.preflight(agent, "your prompt")`. If the messages and tool
  definitions look right, the live turn is much less likely to surprise
  you.
- **Snapshot views in failure logs.** When a session hibernates, log the
  result of `Jidoka.inspect(snapshot)`; the timeline plus pending review
  data is usually enough to diagnose stuck approvals.
- **Request summaries for user reports.** When a user says "that answer was
  wrong", capture `Jidoka.Debug.request(result)` so you have the prompt,
  operation results, usage, and replay diagnostics together.
- **Compare DSL and imported specs.** `Jidoka.inspect(dsl_module).spec ==
  Jidoka.inspect(imported_spec).spec` is the simplest parity assertion.
- **Inspect workflow modules before agent prompts.** If the workflow graph or
  parameters schema is wrong, fix it before debugging a model decision.
- **Strip identifiers in golden tests.** Use `Jidoka.project/1` and then
  drop generated id fields before snapshotting.
- **Never `IO.inspect/1` raw structs in production.** They print
  implementation detail; the inspection view is designed for callers.

## Testing

A typical preflight test asserts both the prompt content and the absence
of diagnostics.

```elixir
defmodule MyApp.PreflightTest do
  use ExUnit.Case, async: true

  test "assembles a prompt for the time agent" do
    {:ok, preflight} = Jidoka.preflight(MyApp.TimeAgent, "What time is it?")

    system_message =
      Enum.find(preflight.prompt.messages, &(&1.role == :system))

    assert system_message.content =~ "Call local_time"
    assert Enum.find(preflight.prompt.tool_definitions, &(&1.name == "local_time"))
    assert preflight.diagnostics == []
  end

  test "inspect/1 returns a tagged map" do
    view = Jidoka.inspect(MyApp.TimeAgent)
    assert view.kind == :agent
    assert view.spec.id == "time_agent"
    assert is_list(view.spec.operations)
  end
end
```

Snapshot tests should generally compare against `Jidoka.project/1` output
rather than the full `inspect/2` view; projections are smaller and rotate
less between releases.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `Jidoka.inspect(agent)` returns a plain projection without `:plan` | `Turn.Plan.new/1` failed for the spec. | Check the `:error` key in the view; it carries a normalized error from `Jidoka.error_to_map/1`. |
| `Jidoka.preflight/3` returns `{:error, %Jidoka.Error.Invalid{}}` | The supplied `context:` did not match the agent's `context` schema. | Either update the context or relax the schema; preflight runs the same `validate_context/2` as a real turn. |
| Memory does not appear in `preflight.prompt` | The `memory_store:` option was not threaded through. | Pass `memory_store: store` (and `session_id:` when needed) to `preflight/3`. |
| `preflight.diagnostics` is non-empty | The prompt assembler flagged a warning (oversized description, missing schema). | Read the diagnostic and adjust the source; warnings here are runtime issues at slightly higher cost. |
| Turn result view has no `:timeline` entries | The turn never made a model or tool call. | Confirm the model returned an operation or final answer. |

## Reference

- [`Jidoka`](`Jidoka`) - public facade: `Jidoka.inspect/2`,
  `Jidoka.preflight/3`, `Jidoka.project/1`.
- [`Jidoka.Inspection`](`Jidoka.Inspection`) - implementation of
  `inspect/2` and the per-struct dispatchers.
- [`Jidoka.Inspection.Preflight`](`Jidoka.Inspection.Preflight`) - struct
  returned by `Jidoka.preflight/3` with fields `agent`, `plan`, `request`,
  `prompt`, `events`, `timeline`, `diagnostics`.
- [`Jidoka.Projection`](`Jidoka.Projection`) - the data-facing companion
  used by `Jidoka.project/1`.
- [`Jidoka.Debug`](`Jidoka.Debug`) - request-level summaries and replay
  diagnostics.
- [`Jidoka.Agent.Spec`](`Jidoka.Agent.Spec`) - the spec inspect views
  path.

## Related Guides

- [Agent DSL](agent-dsl.md) - what the DSL compiles into, mirrored by
  inspect views.
- [Tools And Operations](tools-and-operations.md) - reading operation
  metadata from inspect views to debug control matches.
- [Memory](memory.md) - how memory contributions show up in preflight.
- [Testing And Evals](testing-and-evals.md) - using projections in
  deterministic tests and golden files.
