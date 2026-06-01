# Testing And Evals

Use deterministic tests for agent behaviour. Inject a fake LLM and local
operations, assert the compiled spec shape, and run small eval cases without
calling a provider.

## When To Use This

- Use this guide when adding tests for a new agent, tool, control, or
  memory contract.
- Use this guide when setting up regression coverage for the
  DSL-to-`Jidoka.Agent.Spec` contract.
- Use this guide when building a small eval suite for CI.
- Do not use this guide for live model evaluations or benchmarking; those
  belong in opt-in suites that explicitly require provider credentials.

## Prerequisites

- A working Jidoka project (see [Getting Started](getting-started.md)).
- Familiarity with the operation contract from
  [Tools And Operations](tools-and-operations.md).
- No provider keys are required for any example below.

```bash
mix deps.get
mix test
```

## Quick Example

A minimal eval pins both capabilities, declares one assertion, and runs
the case through the same harness as production.

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

operations =
  Jidoka.Runtime.LocalOperations.operations(%{
    "local_time" => fn _args -> {:ok, %{city: "Chicago", time: "09:30"}} end
  })

llm = fn _intent, journal ->
  case map_size(journal.results) do
    0 -> {:ok, %{type: :operation, name: "local_time", arguments: %{}}}
    _ -> {:ok, %{type: :final, content: "Chicago time is 09:30."}}
  end
end

{:ok, run} =
  Jidoka.Eval.run_case(
    %{
      id: "time_basic",
      agent: MyApp.TimeAgent.spec(),
      input: "What time is it?",
      assertions: %{
        contains: "09:30",
        operation_called: "local_time"
      }
    },
    llm: llm,
    operations: operations
  )

run.status
#=> :passed
```

The run is reproducible. The same inputs always produce the same
`Jidoka.Eval.Run`, so this example doubles as a regression test.

## Concepts

Deterministic testing in Jidoka uses four building blocks.

1. **Fake LLM function.** Every LLM capability is a 2-arity function
   `fn intent, journal -> {:ok, decision} | {:error, reason} end`. The
   decision shape is `%{type: :operation, name: ..., arguments: ...}` or
   `%{type: :final, content: ...}`. The journal is the replay trace;
   counting `map_size(journal.results)` is the standard way to drive
   multi-step decisions.
2. **Local operation capability.** `Jidoka.Runtime.LocalOperations.operations/1`
   wraps a map of `%{name => handler}` into a capability. Handlers may be
   `(args -> term)` or `(intent, journal -> term)`. The same helper is what
   `Jidoka.Operation.Source.Local` uses under the hood.
3. **Golden DSL-to-spec tests.** `Jidoka.project/1` produces compact,
   deterministic maps from any Jidoka data. Snapshotting those projections
   locks the DSL/import contract; changes show up as diffs in the golden
   file.
4. **`Jidoka.Eval`.** `Jidoka.Eval.Case` packages an agent + request +
   assertion set into one value. `Jidoka.Eval.run_case/2` runs the case
   through the normal turn runtime and returns a `Jidoka.Eval.Run` with
   status, evaluated assertions, and observations.

```diagram
╭──────────────────╮     ╭───────────────────╮     ╭──────────────────╮
│  Eval.Case data  │────▶│ Jidoka.Eval       │────▶│ turn runtime     │
│ - agent (spec)   │     │   .run_case/2     │     │   .run_turn/3    │
│ - request/input  │     ╰─────────┬─────────╯     ╰────────┬─────────╯
│ - assertions     │               │                        │
╰──────────────────╯               │                        ▼
                                   │              {:ok, Turn.Result}
                                   │              | {:hibernate, Snap}
                                   │              | {:error, reason}
                                   ▼                        │
                          ╭───────────────────╮             │
                          │ evaluate/2        │◀────────────╯
                          │ - contains        │
                          │ - equals          │
                          │ - operation_called│
                          ╰─────────┬─────────╯
                                    ▼
                          ╭───────────────────╮
                          │ Jidoka.Eval.Run   │
                          │ status:           │
                          │   :passed         │
                          │   :failed         │
                          │   :error          │
                          ╰───────────────────╯
```

### Three Kinds Of Outcome

`Jidoka.Eval.Run.status` is one of:

- `:passed` - the harness returned `{:ok, %Turn.Result{}}` and every
  evaluated assertion passed.
- `:failed` - the harness returned `{:ok, _result}` but at least one
  assertion failed. The `:assertions` list contains `:passed`/`:failed`
  entries with `:expected` and `:actual`.
- `:error` - the harness did not produce a result. Two subcases live here:
  - **Input validation errors** (`{:error, %Jidoka.Error.Invalid{}}` from
    request normalization, context schema mismatch, or spec compilation).
    `run.error` is the projected error map.
  - **Execution errors** (`{:error, reason}` from the operation or LLM
    capability). `run.error` carries the same shape.
  - **Hibernation outcomes** (`{:hibernate, snapshot}` from an operation
    control returning `{:interrupt, ...}`). `run.error` is
    `%{reason: :hibernated, snapshot: ...}`. The eval does not resume
    automatically; treat hibernation as a non-pass outcome and feed the
    snapshot into a `Jidoka.resume/2` test if you need to drive the rest.

## How To

### Step 1: Author A Fake LLM

The simplest fake returns one decision regardless of journal:

```elixir
llm = fn _intent, _journal ->
  {:ok, %{type: :final, content: "pong"}}
end
```

For multi-step tests, branch on `map_size(journal.results)`:

```elixir
llm = fn _intent, journal ->
  case map_size(journal.results) do
    0 -> {:ok, %{type: :operation, name: "local_time", arguments: %{}}}
    1 -> {:ok, %{type: :final, content: "09:30"}}
  end
end
```

You can also branch on intent metadata or the journal contents when you
need to assert specific tool arguments came back. The fake is just a
function; complexity lives in your test, not in a mock framework.

### Step 2: Provide Local Operations

`Jidoka.Runtime.LocalOperations.operations/1` is the helper for local
operation tests:

```elixir
operations =
  Jidoka.Runtime.LocalOperations.operations(%{
    "local_time" => fn _args -> {:ok, %{time: "09:30"}} end,
    "echo" => fn %{"phrase" => phrase} -> {:ok, %{echoed: phrase}} end
  })
```

Handlers can be `(args -> term)` or `(intent, journal -> term)`. A return
value that is not `{:ok, _}` or `{:error, _}` is wrapped in `{:ok, value}`.

Pass it to `turn/3` (or to `Jidoka.Eval.run_case/2`) as `operations:`. The
runtime routes any intent with `kind: :operation` through this capability.

### Step 3: Write A Golden DSL-To-Spec Test

The DSL is data-first; the most effective regression test compares the
projected spec to a snapshot.

```elixir
defmodule MyApp.Golden.TimeAgentTest do
  use ExUnit.Case, async: true

  test "compiled spec matches the golden projection" do
    projection =
      MyApp.TimeAgent.spec()
      |> Jidoka.project()
      |> drop_volatile_fields()

    expected = %{
      id: "time_agent",
      operations: [
        %{name: "local_time", idempotency: :idempotent}
      ]
    }

    assert match?(^expected, projection)
  end

  defp drop_volatile_fields(%{} = projection) do
    Map.update!(projection, :operations, fn operations ->
      Enum.map(operations, &Map.take(&1, [:name, :idempotency]))
    end)
    |> Map.take([:id, :operations])
  end
end
```

In the Jidoka repository, `test/jidoka/golden/dsl_to_spec_test.exs` asserts
the full projection against a recorded snapshot.

### Step 4: Use Jidoka.Eval.run_case For Behavior Tests

`Jidoka.Eval.run_case/2` accepts a `Jidoka.Eval.Case` struct, a map, or a
keyword list. Three assertion kinds are supported today:

- `contains: "substring"` (or a list of substrings) - asserts
  `result.content` contains each.
- `equals: "exact content"` - asserts `result.content` equals the value.
- `operation_called: "name"` (or a list) - asserts each name appears in
  `result.agent_state.operation_results`.

```elixir
{:ok, run} =
  Jidoka.Eval.run_case(
    %{
      id: "time_basic",
      agent: MyApp.TimeAgent.spec(),
      input: "What time is it?",
      assertions: %{
        contains: ["09:30", "Chicago"],
        operation_called: ["local_time"]
      }
    },
    llm: llm,
    operations: operations
  )

run.status
#=> :passed

run.observations
#=> %{content: "Chicago time is 09:30.", operation_calls: ["local_time"], ...}
```

The `Run` struct also carries `result` (the full `Turn.Result`),
`assertions` (with `:expected` and `:actual`), and `metadata` so test
output can stay close to the source data.

### Step 5: Distinguish Outcome Kinds

When a test fails, look at `run.status` and `run.error` first:

```elixir
case Jidoka.Eval.run_case(case_input, llm: llm, operations: operations) do
  {:ok, %Jidoka.Eval.Run{status: :passed} = run} -> {:ok, run}
  {:ok, %Jidoka.Eval.Run{status: :failed, assertions: as}} -> {:failed, as}
  {:ok, %Jidoka.Eval.Run{status: :error, error: %{reason: :hibernated} = e}} ->
    {:hibernated, e.snapshot}
  {:ok, %Jidoka.Eval.Run{status: :error, error: e}} -> {:execution_error, e}
  {:error, reason} -> {:case_validation_error, reason}
end
```

`{:error, reason}` from `run_case/2` itself is the **case validation**
path - the input could not be normalized into a `Jidoka.Eval.Case`. The
three statuses inside the run cover the runtime outcomes.

### Step 6: Build A Small Eval Suite

Eval cases are plain data, so they compose well into a regular ExUnit
suite. Iterate the case list, attach the agent spec, and assert on
`run.status`. `Jidoka.Eval` is not a replacement for ExUnit, just a
packaging convenience for the agent/request/assertions trio.

## Common Patterns

- **One fake per scenario.** Resist building a single mega-fake. Each test
  is clearest when the LLM function shows exactly the decisions that
  matter for that case.
- **Use the journal as the state machine.** `map_size(journal.results)`
  and `Map.values(journal.results)` are usually enough to branch decisions
  without inventing a separate test state.
- **Inspect before asserting.** When an assertion fails, run
  `Jidoka.inspect(run.result)` to see the timeline, then refine the
  assertion or the fake.
- **Project, then snapshot.** Golden tests should compare
  `Jidoka.project/1` output, not raw structs.
- **Treat hibernation as data.** When a test deliberately exercises a
  control interrupt, assert on `run.error.reason == :hibernated` and use
  `Jidoka.resume/2` in a follow-up test to drive the resume path.

## Testing

The dedicated tests under `test/jidoka/eval` exercise this guide's surface
end to end. The recipe is short: build a spec, pin an LLM and operations
capability, then assert on `Jidoka.Eval.Run.status`.

```elixir
test "passes when content and operations match" do
  operations =
    Jidoka.Runtime.LocalOperations.operations(%{
      "echo" => fn %{"phrase" => phrase} -> {:ok, %{echoed: phrase}} end
    })

  llm = fn _intent, journal ->
    case map_size(journal.results) do
      0 -> {:ok, %{type: :operation, name: "echo", arguments: %{"phrase" => "hi"}}}
      _ -> {:ok, %{type: :final, content: "hi"}}
    end
  end

  spec =
    Jidoka.agent!(
      id: "echo_agent",
      instructions: "Echo the user's input.",
      operations: [Jidoka.Agent.Spec.Operation.new!(name: "echo")]
    )

  assert {:ok, %Jidoka.Eval.Run{status: :passed}} =
           Jidoka.Eval.run_case(
             %{id: "echo_basic", agent: spec, input: "hi",
               assertions: %{contains: "hi", operation_called: "echo"}},
             llm: llm,
             operations: operations
           )
end
```

For tests that need to inspect the full run shape, project it with
`Jidoka.project(run)`.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, %Jidoka.Error.Invalid{}}` from `run_case/2` | The case input was malformed (missing `:agent`, invalid `:input`). | Verify the case keys; `agent:` is required and must be a spec or compatible map. |
| `run.status == :error` with `error.reason == :hibernated` | An operation control returned `{:interrupt, _}`. | Either remove the control for the test or assert on hibernation and resume in a follow-up. |
| `run.status == :error` with a Splode error map | The LLM or operation capability returned `{:error, _}`. | Inspect `run.error.details`; the capability is the fastest place to fix. |
| Assertions report `:passed` but content is wrong | The fake LLM returned the expected string by accident even when the operation was never called. | Add `operation_called:` to lock down the path. |
| Golden test fails after an unrelated change | Volatile fields (ids, timestamps) leaked into the snapshot. | Project the spec, drop the volatile keys, then assert. |

## Reference

- [`Jidoka.Eval`](`Jidoka.Eval`) - `run_case/2` and `evaluate/2`.
- [`Jidoka.Eval.Case`](`Jidoka.Eval.Case`) - case schema, `new/2`,
  `new!/2`, `from_input/2`.
- [`Jidoka.Eval.Run`](`Jidoka.Eval.Run`) - run schema, `:passed | :failed |
  :error` status, assertions, observations.
- [`Jidoka.Runtime.LocalOperations`](`Jidoka.Runtime.LocalOperations`) -
  `operations/1` helper that wraps a handler map.
- [`Jidoka.Operation.Source.Local`](`Jidoka.Operation.Source.Local`) -
  source-shaped wrapper around the same handlers.
- [`Jidoka.Projection`](`Jidoka.Projection`) - data projector used by
  golden tests.
- [`Jidoka`](`Jidoka`) - public facade: `turn/3`, `chat/3`, `resume/2`,
  `inspect/2`, `project/1`.

## Related Guides

- [Tools And Operations](tools-and-operations.md) - shape of the operation
  contract under test.
- [Memory](memory.md) - test patterns for memory-backed turns.
- [Handoffs](handoffs.md) - testing ownership transitions.
- [Inspection And Preflight](inspection-and-preflight.md) - debugging
  failures before adding assertions.
- [Runtime And Harness](runtime-and-harness.md) - hibernation and resume
  flows referenced by error-status cases.
