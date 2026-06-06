# Contributor Testing

Jidoka's test suite is designed to stay deterministic by default, with a
narrow opt-in path for live provider runs. Contributors who add a feature
must also extend the deterministic surface (unit, runtime, golden, and
integration tests) and only optionally extend the live tests. This guide
documents the test layout, the fake-LLM and local-operation patterns, the
golden-file contract, and the `mix quality` gates that every change must
clear. It is written for people contributing to the `jidoka` package, not
for application authors.

## When To Use This

- Use this guide before writing a new test in `test/`. The folder structure
  and helper modules are not obvious from the file tree alone.
- Use this guide when adding a feature that should appear in golden coverage
  (any change to `Agent.Spec`, `Turn.Plan`, or the import path).
- Use this guide when changing default `mix quality` gates or when adding a
  new opt-in test category.
- Do not use this guide for application-level testing. Application authors
  should follow [Testing And Evals](testing-and-evals.md).

## Prerequisites

- Elixir `~> 1.18` and a checkout of the `jidoka` package.
- `mix deps.get` has been run.
- For the live opt-in path: one provider key in scope
  (`OPENAI_API_KEY` or `ANTHROPIC_API_KEY`).

```bash
mix deps.get
mix test
```

## Quick Example

A deterministic test only needs a fake LLM function and (optionally) an
injected operation capability. Both go through `Jidoka.turn/3`:

```elixir
defmodule MyContributorTest do
  use ExUnit.Case, async: true

  import TestSupport

  defmodule TimeAgent do
    use Jidoka.Agent

    agent :contributor_time do
      model %{provider: :test, id: "deterministic"}
      instructions "Call local_time when asked for the time."
    end

    tools do
      local_operations do
        operation :local_time do
          description "Returns a fixed time for a city."
          handler fn %{"city" => city} -> {:ok, %{city: city, time: "09:30"}} end
        end
      end
    end
  end

  test "returns the canned answer with no provider key" do
    llm = operation_then_final_llm("local_time", %{"city" => "Chicago"}, "Chicago: 09:30")

    assert {:ok, %Jidoka.Turn.Result{content: "Chicago: 09:30"}} =
             Jidoka.turn(TimeAgent, "What time is it in Chicago?", llm: llm)
  end
end
```

No environment variable is required. The test runs in `async: true` because
both capabilities are pure functions.

## Concepts

Three ideas define the contributor test surface.

1. **Deterministic by default, live by opt-in.** `test/test_helper.exs`
   excludes the `:live` tag by default. Live tests must be tagged
   `@moduletag :live` and run with `mix test --include live`.
2. **Two injection seams replace every external dependency.** The `llm:`
   keyword option supplies a fake `t:Jidoka.Runtime.Capabilities.llm_capability/0`
   function, and `operations:` supplies a fake
   `t:Jidoka.Runtime.Capabilities.operation_capability/0` function. Together
   they make the runtime fully data-driven.
3. **Golden tests pin the public projection.** Any change to a struct that
   escapes the package boundary must update the matching golden expectation.

```diagram
                  mix test
                     │
        ╭────────────┼─────────────╮
        ▼            ▼             ▼
   unit tests   runtime tests  golden tests
  (per module) (capabilities,    (DSL->spec,
   pure data)   interpreter,      import->spec)
                runner)
        │            │             │
        ╰────────────┼─────────────╯
                     ▼
            integration tests
            (test/integration/,
            scenario-shaped)
                     │
                     ▼
            mix test --include live
            (opt-in real provider)
```

## How To

### Step 1: Pick The Right Test Folder

The repo's test layout has four buckets. New tests go in the bucket that
matches their scope:

| Folder | Scope | Conventions |
| --- | --- | --- |
| `test/jidoka/` | Unit and per-module tests | `async: true`, one module per file, no provider keys. |
| `test/jidoka/runtime/` | Runtime kernel tests | Exercise `Capabilities`, `EffectInterpreter`, `TurnRunner`, adapters. Inject fake capabilities. |
| `test/jidoka/golden/` | DSL/import projection golden files | `Jidoka.project/1` output pinned verbatim; update in the same commit as the change. |
| `test/integration/` | End-to-end scenarios | Mirror an author's flow (controls, memory, structured results, idempotency). Still deterministic. |

Tests that need shared agents, actions, or controls go under
`test/support/integration/{agents,actions,controls}/`. The
`test/support/integration/README.md` file documents who lives there.

### Step 2: Write A Fake LLM Capability

The shared helpers in `test/support/test_support.ex` cover the common
shapes. The three building blocks are `final_llm/2`, `operation_llm/2`,
and `operation_then_final_llm/3`:

```elixir
def final_llm(content, opts \\ []) when is_binary(content) do
  result = Keyword.get(opts, :result)

  fn _intent, _journal, _ctx ->
    {:ok, %{type: :final, content: content, result: result}}
  end
end

def operation_llm(name, arguments \\ %{}) when is_binary(name) and is_map(arguments) do
  fn _intent, _journal, _ctx ->
    {:ok, %{type: :operation, name: name, arguments: arguments}}
  end
end

def operation_then_final_llm(name, arguments, content) do
  fn _intent, %Effect.Journal{} = journal, _ctx ->
    case count_results(journal, :llm) do
      0 -> {:ok, %{type: :operation, name: name, arguments: arguments}}
      _count -> {:ok, %{type: :final, content: content}}
    end
  end
end
```

The contract:

- **The function takes `(Effect.Intent.t(), Effect.Journal.t())` and returns
  `{:ok, decision_map_or_struct} | {:error, term}`.**
- **The decision can be a `Jidoka.Effect.LLMDecision` struct or a plain map
  matching the JSON decision shape.**
- **The function is called once per loop iteration.** Use `count_results/2`
  on the journal to branch by iteration number.

For multi-step loops, write a small reduction directly inline rather than a
helper:

```elixir
llm = fn _intent, %Effect.Journal{} = journal, _ctx ->
  case TestSupport.count_results(journal, :llm) do
    0 -> {:ok, %{type: :operation, name: "step_a", arguments: %{}}}
    1 -> {:ok, %{type: :operation, name: "step_b", arguments: %{}}}
    2 -> {:ok, %{type: :final, content: "done"}}
  end
end
```

### Step 3: Write A Local Operation Capability

For tests that exercise tool calls, use
[`Jidoka.Operation.Source.Local`](`Jidoka.Operation.Source.Local`) when the
agent is defined through the DSL, or
[`Jidoka.Runtime.LocalOperations.operations/1`](`Jidoka.Runtime.LocalOperations`)
when you want a bare capability function:

```elixir
operations =
  Jidoka.Runtime.LocalOperations.operations(%{
    "local_time" => fn %{"city" => city} -> {:ok, %{city: city, time: "09:30"}} end
  })

Jidoka.turn(MyAgent, "input", llm: llm, operations: operations)
```

When the test agent declares operations through DSL, prefer
`Jidoka.Operation.Source.Local` inside the DSL itself so the spec is
self-contained and golden-testable.

The handler signatures:

| Arity | Receives | Use when |
| --- | --- | --- |
| 1 | `request.arguments` (a map) | The test only cares about input/output. |
| 2 | `(Effect.Intent.t(), Effect.Journal.t())` | The test needs the full intent (idempotency key, metadata) or to branch on prior results. |

### Step 4: Author A Golden Test

Golden tests live in `test/jidoka/golden/`. The canonical shape is in
`test/jidoka/golden/dsl_to_spec_test.exs`:

```elixir
defmodule Jidoka.GoldenTest.Support.MinimalAgent do
  use Jidoka.Agent

  agent :golden_minimal_agent do
    model %{provider: :test, id: "golden-minimal-model"}
  end
end

defmodule Jidoka.Golden.DslToSpecTest do
  use ExUnit.Case, async: true

  alias Jidoka.GoldenTest.Support.MinimalAgent

  test "minimal DSL agent compiles to the expected Agent.Spec projection" do
    assert Jidoka.project(MinimalAgent.spec()) == %{
             id: "golden_minimal_agent",
             instructions: Jidoka.Agent.default_instructions(),
             model: "test:golden-minimal-model",
             generation: %{params: %{temperature: 0.0, max_tokens: 500},
                           provider_options: %{},
                           extra: %{}},
             context_schema?: false,
             result: nil,
             memory: nil,
             operations: [],
             controls: %{max_turns: nil, timeout_ms: nil,
                         inputs: [], outputs: [], operations: [],
                         metadata: %{}},
             runtime_defaults: %{},
             metadata: %{...}
           }
  end
end
```

Three rules for golden tests:

- **Use `==` not `=~`.** The whole point is to detect any drift.
- **Co-locate the support modules in the same file.** Each golden test
  module owns its fixtures so cross-file moves are obvious.
- **Update the expected map in the same commit as the change.** A green
  golden test after a struct change usually means you forgot to assert the
  new field.

### Step 5: Author An Integration Test

Integration tests live in `test/integration/` and mirror an author flow.
They are still deterministic; they just exercise more than one module per
test. Folder conventions:

| Test file | Scenario |
| --- | --- |
| `controls_integration_test.exs` | Input/operation/output controls |
| `harness_session_integration_test.exs` | `Jidoka.Session` lifecycle |
| `human_in_the_loop_integration_test.exs` | Review interrupt + resume |
| `memory_integration_test.exs` | Recall/capture flow |
| `multi_turn_integration_test.exs` | Multiple turns in one session |
| `observability_integration_test.exs` | Trace and event emission |
| `operation_idempotency_integration_test.exs` | `:unsafe_once` and replay |
| `operation_source_integration_test.exs` | Local/jido/mcp operation sources |
| `structured_result_integration_test.exs` | Typed `Turn.Result.value` |

Reuse the shared agents under `test/support/integration/agents/` whenever a
scenario fits one of them (`MinimalChatAgent`, `AccountAgent`,
`ControlledLookupAgent`).

### Step 6: Add A Live Test (Opt-In)

The live test pattern is documented in `test/jidoka/live_req_llm_test.exs`:

```elixir
defmodule Jidoka.LiveReqLLMTest do
  use ExUnit.Case, async: false

  @moduletag :live
  @moduletag timeout: 120_000

  @live_enabled? not is_nil(System.get_env("OPENAI_API_KEY") || System.get_env("ANTHROPIC_API_KEY"))

  if @live_enabled? do
    # ... test bodies referencing real providers ...
  end
end
```

Three rules for live tests:

- **Always tag `@moduletag :live`.** The `test/test_helper.exs` excludes
  `:live` so default `mix test` stays fast.
- **Guard with `@live_enabled?`.** A live test without a key should compile
  but contain no test cases.
- **Set a generous `@moduletag timeout`.** Real providers vary; 120s is the
  current default.

Run live tests with `mix test --include live`.

### Step 7: Clear `mix quality` Before You Push

The `mix quality` alias (also aliased as `mix q`) runs the gates defined in
`mix.exs`:

```elixir
quality: [
  "format --check-formatted",
  "compile --warnings-as-errors",
  "credo",
  "dialyzer",
  "doctor --raise"
]
```

Each step is non-negotiable:

| Gate | Why |
| --- | --- |
| `format --check-formatted` | Keeps diffs minimal; `mix format` should be run before commit. |
| `compile --warnings-as-errors` | Warnings are real bugs; treat them like failing tests. |
| `credo` | Style and idiom enforcement. Refactor; do not add `# credo:disable` lightly. |
| `dialyzer` | Catches contract drift in the Zoi-backed structs and capability functions. |
| `doctor --raise` | Documentation coverage. New public functions need `@spec` and `@doc`. |

Run `mix q` after every meaningful change. Do not push a branch that fails
any of these.

## Common Patterns

- **Inject capabilities at the top of the test.** A test that fakes the LLM
  inside a helper deep in the call chain is hard to follow. Keep the seam
  visible.
- **Branch on the journal, not on test state.** `count_results(journal, :llm)`
  is the canonical way to "do this on the first call, that on the second".
- **Prefer `Jidoka.project/1` over deep struct assertions.** Asserting on a
  projection survives implementation churn that does not change the public
  shape.
- **Use `Jidoka.Trace.timeline/1` for event assertions.** It
  shrinks event details to the stable trace shape.
- **Group integration helpers in `test/support/integration/`.** Per-file
  one-off agents accumulate noise.

## Testing

The package itself is the test bed. Two cross-cutting commands matter:

```bash
# Fast, deterministic, default. Excludes :live.
mix test

# Include live tests. Requires a provider key.
mix test --include live

# Full quality bar.
mix quality
```

For a single contributor change, the loop is usually:

```bash
mix test path/to/test_file.exs
mix format
mix q
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| Test passes locally, fails in CI with provider error | Test missed `@moduletag :live` and made a live call | Add the tag and rerun with `mix test --include live`. |
| `mix test` is slow | A test forgot `async: true` or held a Jido agent process open | Make the test async; teardown processes with `start_supervised/1`. |
| Golden test fails after a struct change | Projection drifted | Update the expected map in the golden file in the same commit. |
| Fake LLM returns wrong shape | Decision map missing `:type` | Use one of the shared test helpers or set `type: :final`/`:operation`. |
| `mix dialyzer` complains about an opaque type | A capability function was typed too loosely | Add `@spec` matching `t:Jidoka.Runtime.Capabilities.llm_capability/0` or `t:Jidoka.Runtime.Capabilities.operation_capability/0`. |
| `mix doctor --raise` fails on a new function | Missing `@doc` or `@spec` on a public function | Document the function and add a spec. Hide internal helpers with `@doc false`. |
| `credo` flags `Credo.Check.Refactor.PipeChainStart` on a fixture | Helper builds a struct in one line | Wrap in `Map.new/2` or split into a named step. |
| `mix q` fails on `compile --warnings-as-errors` for unused alias | Test or module aliases a struct it does not use | Remove the alias or suppress with `_ = SomeModule`. |
| Test agent process leaks between tests | `Jidoka.start_agent/2` not torn down | Use `start_supervised!(MyApp.TimeAgent)` or call `Jidoka.stop_agent/2` in `on_exit/1`. |

## Reference

- `test/support/test_support.ex` - shared helpers: `final_llm/2`,
  `operation_llm/2`, `operation_then_final_llm/3`, `timeline/1`,
  `event_index/2`, `operation_control_index/2`,
  `operation_capability_index/2`.
- [`Jidoka.Runtime.LocalOperations`](`Jidoka.Runtime.LocalOperations`) -
  function-backed operation capability for tests.
- [`Jidoka.Operation.Source.Local`](`Jidoka.Operation.Source.Local`) - DSL
  surface that wraps `LocalOperations` for self-contained test agents.
- [`Jidoka.Runtime.Capabilities`](`Jidoka.Runtime.Capabilities`) - typed
  bundle that the runner consumes; the `llm_capability/0` and
  `operation_capability/0` types are the test contract.
- [`Jidoka.Effect.Journal`](`Jidoka.Effect.Journal`) - the journal the fake
  LLM inspects to branch on iteration.
- [`Jidoka.Projection`](`Jidoka.Projection`) - target of golden assertions.
- [`Jidoka.Trace`](`Jidoka.Trace`) - source of the
  `timeline/1` helper used in event assertions.

## Related Guides

- [Testing And Evals](testing-and-evals.md) - author-facing test patterns.
- [Turn Runner And Effect Interpreter](turn-runner-and-effect-interpreter.md) -
  how the loop the tests exercise actually runs.
- [Runtime Capabilities Internals](runtime-capabilities-internals.md) - the
  adapters the test capabilities mirror.
- [Projection Internals](projection-internals.md) - what golden tests are
  pinning.
- [Troubleshooting](troubleshooting.md) - error reference for failures that
  surface during tests.
