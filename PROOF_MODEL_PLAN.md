# Jidoka Example Proof Model Plan

Status: implemented

Plan date: 2026-07-31

Scope: consolidate, tighten, and harden the example proof model. Use the Support
Agent as the only real scenario during this work.

Implementation result: the Support Agent is the only cataloged example. ExUnit
is the proof authority for its three deterministic cases. The checker owns
isolated proof execution, Livebook and showcase surface gates, machine reports,
changed-file selection, and transactional proof publication.

## Outcome

Jidoka will have one deterministic proof system for example agents.

The system will make a clear distinction between declared coverage and verified
coverage. A manifest will declare the behavior that a case is expected to prove.
ExUnit will be the only authority that can mark that case as passed. The checker
will derive verified capability coverage from completed ExUnit case results.

The CLI, Livebook, and showcase will remain important surfaces. They will be
checked for their own contracts. They will not create capability proof.

This plan keeps the current example-folder design. It does not add a scenario
generator or a custom scenario DSL.

## Decisions

These decisions are part of the plan:

1. Keep `examples/<example_name>/` as the ownership boundary for one complete
   reference agent.
2. Use one Support Agent scenario named `controlled_tool_call`.
3. Use three deterministic cases inside that scenario.
4. Make ExUnit the only capability-proof authority.
5. Remove successful proof construction from scenario runners.
6. Remove `:compiled`, `:executed`, and `:live` as proof levels.
7. Keep execution mode, surface status, and capability coverage as separate data.
8. Generate verified coverage only from a complete successful check.
9. Keep all default proof execution offline.
10. Do a hard cut to manifest version 2. Do not keep a version 1 compatibility
    layer because there is only one cataloged example.
11. Do not add another real scenario until this model is complete.
12. Do not add a generator in this work.
13. Make `mix jidoka.examples.check` the owner of example proof tests. Keep the
    normal package test suite focused on `test/` after the CI proof job exists.
14. Keep the packaged catalog portable. Repository-only showcase validation must
    not prevent an installed package from listing or running an example.

## Non-Goals

This plan does not include:

- a scenario generator;
- a custom ExUnit test DSL;
- a new example agent;
- migration of the other showcase agents into `examples/`;
- live provider proof;
- recorded LLM fixtures;
- external framework research;
- a redesign of the Jidoka runtime;
- a full Livebook browser or Kino UI test system;
- one Livebook for every edge case.

## Terms

Use these terms in code, tests, output, and documentation:

### Example

One complete reference agent folder.

Example: `support_agent`.

An example owns its agent code, deterministic support code, scenarios, tests,
README, Livebook, and optional showcase surface.

### Scenario

One causal Jidoka behavior through line.

Example: `controlled_tool_call`.

A scenario is about a Jidoka behavior. It is not a business use case. A business
theme can make the behavior easy to understand, but it does not define the proof.

### Case

One deterministic path or edge inside a scenario.

Examples:

- `allowed_round_trip`;
- `interrupted_and_approved`;
- `not_found_result`.

### Capability

One stable and falsifiable Jidoka guarantee.

Initial capability IDs remain:

- `tool_calling`;
- `tool_observation`;
- `operation_control`;
- `human_review`;
- `snapshot_resume`.

`agent` and `action` are dependencies in this first scenario. Record them under
`uses`. Do not claim that the scenario proves their full public contracts.

### Component

One building block that a case uses but does not prove.

Initial component IDs:

- `agent`;
- `action`.

Keep capability IDs and component IDs in separate registries. `proves` accepts
capability IDs only. `uses` accepts capability IDs or component IDs.

### Uses

A capability or component that a case exercises but does not independently
prove.

### Surface

One way that a developer or user interacts with an example:

- ExUnit;
- CLI;
- Livebook;
- showcase.

A surface is not a proof level.

### Execution Mode

The environment that a case needs.

Initial values:

- `:deterministic`;
- `:external`.

Only `:deterministic` is in scope for this plan.

### ExUnit Result

A raw and versioned machine record from the ExUnit formatter. It contains only
observed test data: the case tag, test location, test name, status, duration, and
failure.

### Case Result

The reporter joins one ExUnit result with one manifest case declaration. The
joined record contains the execution mode, `proves`, `uses`, and agent metadata.
The ExUnit formatter must not author these declared values.

### Proof Report

The stable aggregate of all selected case results and surface gate results.

### Run Coverage

Coverage from passed cases in the current selected run.

### Published Coverage

Coverage from a complete successful full run. Only published coverage can update
the committed generated document.

## Authority Model

Each file or surface must have one clear role.

| Source | Authority |
| --- | --- |
| Manifest | Expected example, scenario, case, and surface declarations |
| ExUnit proof test | Capability pass or fail result |
| Example runner | One useful demonstration execution |
| Livebook | Executable teaching surface |
| Showcase | Optional Phoenix integration surface |
| Checker | Selection, execution, validation, and aggregation |
| `PROVEN_FEATURES.md` | Stable generated view of a successful full proof report |

The manifest must never declare that a capability passed. It declares only which
capabilities a case is expected to prove.

The example runner must never return a successful capability map. It returns a
domain result for demonstration and inspection.

## Target Support Agent Model

Keep one scenario:

```text
controlled_tool_call
```

Its causal path is:

```text
request
  -> Mock LLM tool request
  -> operation control
  -> action or interrupt
  -> operation result
  -> next LLM observation
  -> final result
```

The interrupt branch is:

```text
operation control
  -> hibernated snapshot
  -> pending review
  -> approval
  -> one resumed action execution
  -> next LLM observation
  -> final result
```

### Case 1: `allowed_round_trip`

Expected proof:

- `tool_calling`;
- `operation_control`;
- `tool_observation`.

Uses:

- `agent`;
- `action`.

Required assertions:

1. The Mock LLM requests `lookup_order` with the exact order ID.
2. The operation control runs before the action.
3. The operation control allows the operation.
4. The action runs exactly once.
5. The operation result has the expected operation name, arguments, and output.
6. The next LLM input contains that exact operation result.
7. The operation request, result, and observation have correct correlation.
8. The final answer uses the returned order data.
9. The journal contains two LLM results and one operation result.
10. The event timeline has the required causal order.

### Case 2: `interrupted_and_approved`

Expected proof:

- `operation_control`;
- `human_review`;
- `snapshot_resume`.

Uses:

- `agent`;
- `action`;
- `tool_calling`;
- `tool_observation`.

Required assertions:

1. Authenticated order access causes hibernation.
2. The action has no operation result before approval.
3. An injected action counter is zero before approval.
4. The pending review has the exact operation name, arguments, and reason.
5. Approval resumes the same planned operation.
6. The action counter is exactly one after approval.
7. The resumed result contains exactly one operation result.
8. The action result reaches the next LLM input.
9. The final answer uses the resumed action result.
10. The event timeline shows interrupt, review, approval, operation, observation,
    and completion in the required order.

Do not use a mailbox-only negative assertion as the proof that the action did not
run. Use state, journal, event, and counter invariants.

### Case 3: `not_found_result`

Expected proof:

- `tool_observation`.

Uses:

- `agent`;
- `action`;
- `tool_calling`.

Required assertions:

1. An unknown normalized order ID returns `status: "not_found"`.
2. The operation result reaches the next LLM input without shape loss.
3. The Mock LLM handles missing carrier and ETA values correctly.
4. The final answer clearly states that the order was not found.
5. The final answer asks for the correct order ID.
6. The final answer does not contain blank text such as `with .` or `ETA: .`.

This case protects a real defect in the current example.

## Manifest Version 2

The version 2 manifest must declare example metadata, scenarios, cases, and
surfaces. It must not contain proof status.

Target shape:

```elixir
%{
  version: 2,
  name: :support_agent,
  title: "Support Agent",
  summary: "A deterministic agent that proves a controlled tool-call lifecycle.",
  module: JidokaExamples.SupportAgent.Example,
  agent: JidokaExamples.SupportAgent.Agent,
  scenarios: [
    %{
      id: :controlled_tool_call,
      title: "Controlled Tool Call",
      intent:
        "A model tool request passes through control, execution, observation, and optional review.",
      execution: :deterministic,
      cases: [
        %{
          id: :allowed_round_trip,
          proves: [:tool_calling, :operation_control, :tool_observation],
          uses: [:agent, :action]
        },
        %{
          id: :interrupted_and_approved,
          proves: [:operation_control, :human_review, :snapshot_resume],
          uses: [:agent, :action, :tool_calling, :tool_observation]
        },
        %{
          id: :not_found_result,
          proves: [:tool_observation],
          uses: [:agent, :action, :tool_calling]
        }
      ]
    }
  ],
  surfaces: %{
    livebook: true,
    showcase: %{
      route: "/agents/support",
      live_view: JidokaShowcaseWeb.SupportAgentLive.Index,
      view: JidokaShowcaseWeb.SupportAgentLive.View,
      tests: ["test/support_agent_live_test.exs"]
    }
  }
}
```

Catalog validation must enforce these rules:

- Example, scenario, and case IDs are atoms.
- IDs are unique in their scope.
- Every scenario has at least one case.
- Every case has at least one `proves` capability.
- Every `proves` value exists in the central capability catalog.
- Every `uses` value exists in the capability or component catalog.
- `proves` and `uses` do not overlap in one case.
- Execution mode is known.
- Surface metadata has the required paths and modules.
- All paths remain inside the example or showcase root.
- Every example-owned `lib/`, support, runner, and test module uses the example
  namespace.
- Showcase modules use their declared `JidokaShowcase` or `JidokaShowcaseWeb`
  namespace and remain under declared showcase paths.
- Every declared case maps to exactly one ExUnit proof test.
- Every tagged ExUnit proof test maps to one declared case.

Use two validation layers:

- Portable catalog validation checks manifest data and example-local files. It
  works in a repository checkout and in an installed package.
- Repository surface validation checks showcase files, routes, and tests only
  when the repository contains `showcase/`.

The catalog loader must return manifests and structured errors. It must not raise
during normal Mix project configuration.

## ExUnit Proof Contract

Do not add a test DSL. Use normal ExUnit tests and tags.

Target test shape:

```elixir
defmodule JidokaExamples.SupportAgent.ControlledToolCallTest do
  use ExUnit.Case, async: true

  @moduletag proof_example: :support_agent
  @moduletag timeout: 5_000

  @tag proof_case: {:controlled_tool_call, :allowed_round_trip}
  test "returns a tool observation through the controlled operation path" do
    # Normal ExUnit assertions.
  end
end
```

Rules:

- Do not repeat `proves` in test tags.
- The manifest declares the expected capability mapping.
- A passed tagged test verifies the manifest case.
- A failed, skipped, excluded, timed-out, missing, or duplicated test does not
  prove the case.
- Untagged tests can support the example, but they do not create capability
  coverage.
- Each declared case has exactly one tagged proof test.
- The proof formatter sorts results by example, scenario, and case ID.

The ExUnit formatter must write a raw, versioned result artifact to a unique
temporary path supplied by the checker. Regular `mix test` runs must not leave
proof files in the repository.

Each raw ExUnit result must contain:

```elixir
%{
  schema_version: 1,
  example: :support_agent,
  scenario: :controlled_tool_call,
  case: :allowed_round_trip,
  status: :passed,
  test: %{
    file: "examples/support_agent/test/controlled_tool_call_test.exs",
    line: 12,
    name: "returns a tool observation through the controlled operation path"
  },
  duration_ms: 24,
  failure: nil
}
```

Case-result statuses are:

- `:passed`;
- `:failed`;
- `:skipped`;
- `:excluded`;
- `:timed_out`.

Missing, duplicate, unknown, or malformed case records are reconciliation errors.
They are not case statuses.

After ExUnit completes, the reporter must compare observed case IDs with selected
manifest case IDs. An expected case with no result is missing and proves nothing.
The proof subprocess must not accept user test filters.

The reporter enriches each raw result with the manifest execution mode, `proves`,
`uses`, and agent module. A proof test must execute the agent module from the
selected manifest. A small shared helper passes that module into the case setup,
and the test asserts that the resulting agent identity matches it.

Runtime values such as duration and failure details belong in the temporary JSON
report. Do not put them in committed documentation.

## Target Example Layout

Use this layout for the Support Agent:

```text
examples/support_agent/
├── README.md
├── manifest.exs
├── example.exs
├── support_agent.livemd
├── lib/
│   ├── agent.ex
│   ├── actions/
│   └── controls/
├── support/
│   └── mock_llm.ex
└── test/
    └── controlled_tool_call_test.exs
```

The case declarations stay in `manifest.exs`. The assertions stay in ExUnit. Do
not add one source file only to restate the manifest.

The catalog must discover all files that match
`examples/<example_name>/**/*_test.exs`. It must not require one fixed test file
name. This permits more test files when an example becomes larger.

The README and Livebook remain one-per-example assets. Do not create one README
or Livebook per case.

The example test suite must be self-contained inside packaged paths. Move any
required proof assertion helpers from root `test/support/` to
`examples/_support/`, or remove the dependency. `examples/test_helper.exs` must
not require `test/test_helper.exs`, because the published package does not include
the root `test/` directory.

## Checker Architecture

Split the current checker into clear internal roles. Keep one public Mix task.

### Catalog

The catalog loads and validates manifests. It derives conventional source,
support, test, README, and Livebook paths.

### Planner

The planner takes the catalog, command options, and changed paths. It returns a
stable list of gate data. It performs no external work.

### Executor

The executor runs planned gates. It owns process isolation, timeouts, streamed
output, output limits, and process cleanup.

### Reporter

The reporter merges ExUnit case results and surface gate results. It creates
console output, JSON output, and the candidate generated document.

Suggested non-production support layout:

```text
examples/_support/
├── model.exs
├── ex_unit_formatter.exs
├── planner.exs
├── executor.exs
└── reporter.exs
```

Reserve `_support/` and `guides/` as non-example directories. The catalog must
not treat them as missing-manifest errors.

`examples/check.exs` and `examples/catalog.exs` can remain small entry files that
load these internal modules.

## Command Contract

Keep one public check task:

```bash
mix jidoka.examples.check
mix jidoka.examples.check --example support_agent
mix jidoka.examples.check --changed origin/main
mix jidoka.examples.check --verbose
mix jidoka.examples.check --json
mix jidoka.examples.check --update-proof
```

Do not add a quick mode.

### Focused Check

`--example support_agent` runs every gate that belongs to the Support Agent:

- portable catalog loading, global uniqueness checks, and strict validation for
  the selected example;
- all Support Agent ExUnit files;
- Support Agent proof-result validation;
- Support Agent Livebook code-cell smoke test;
- showcase compile when required;
- Support Agent showcase tests;
- static validation for selected documentation and surface links.

It does not run unrelated guide Livebooks, unrelated showcase tests, or the full
ExDoc build. Those are global gates. The focused check remains complete for its
selected scope.

A focused check reports run coverage. It does not compare or update published
global coverage.

The catalog loader can report unrelated invalid manifests during a focused run,
but an unrelated incomplete manifest must not stop a valid selected example from
running. Errors that affect selection, global uniqueness, or the selected example
remain fatal. A full run treats every catalog error as fatal.

### Changed Check

`--changed REF` selects affected scenario and global gates. It must explain why
each gate was selected.

### Full Check

The command without a selection runs:

- every scenario proof process;
- every scenario Livebook smoke test;
- every standalone guide Livebook smoke test;
- showcase compile once;
- the full showcase test suite once;
- ExDoc once;
- proof-document comparison.

### Proof Update

`--update-proof` is valid only for a full selection.

The checker must:

1. run all required gates;
2. create the candidate document in memory;
3. write a temporary file only after all gates pass;
4. atomically replace `PROVEN_FEATURES.md`;
5. leave the file unchanged after any failure.

A focused or changed run must never update global verified coverage.

Use two full-run paths:

- A normal full check creates the candidate document and compares it with the
  committed document.
- A full `--update-proof` check runs all non-publication gates, then atomically
  publishes the candidate. It does not fail first because the old document is
  different.

## Execution Model

Do not dynamically load and execute many scenarios in the parent checker VM.

Use a fresh OS process for each selected example proof. Run example processes
with bounded concurrency. Start with four workers.

Execution order:

1. Validate the catalog.
2. Build a pure gate plan.
3. Warm the root build once.
4. Run selected ExUnit proof processes.
5. Validate all expected case-result artifacts.
6. Run selected Livebook smoke tests.
7. Run selected showcase gates.
8. Run global documentation gates when the plan requires them.
9. Build the report.
10. Compare or publish generated documentation.

Use `--no-compile` and `--no-deps-check` for worker commands after the warm build
when the command supports those options. This prevents repeated compile locks.

The executor must use a Port-based command runner instead of buffered
`System.cmd/3` execution.

Required command behavior:

- Stream output during `--verbose`.
- Prefix streamed lines with the gate ID.
- Keep normal output short.
- Keep a bounded output tail for failures.
- Preserve partial output after a timeout.
- Record the command and duration.
- Terminate timed-out child processes.
- Keep JSON output free of progress text.

Initial timeout budgets:

| Gate | Timeout |
| --- | ---: |
| One deterministic ExUnit test | 5 seconds |
| One example ExUnit process | 30 seconds |
| One Livebook smoke test | 30 seconds |
| Focused showcase test | 60 seconds |
| Full showcase suite | 120 seconds |
| ExDoc | 120 seconds |

Keep these values in one internal module. Do not add public timeout options in
this work.

Tighter timeouts reduce hang time. They do not make successful tests faster.
Process reuse, warm compilation, and correct gate scoping provide the speed gain.

## Changed-File Impact Rules

Use Git name-status output. Include old and new paths for renames and deletions.

Initial rules:

| Changed path | Required impact |
| --- | --- |
| `examples/<example>/...` | That example |
| Deleted example path | Catalog, proof document, and affected showcase cleanup |
| `examples/guides/<guide>` | That guide only |
| `examples/_support/...` | All proof infrastructure gates |
| `examples/catalog.exs` | All examples and proof documents |
| `examples/check.exs` | All examples and checker meta-tests |
| `examples/registry.exs` | All examples |
| `examples/test_helper.exs` | All example tests |
| `lib/...` | All examples |
| `test/support/...` | All examples that use package test support |
| `scripts/check_livebook.exs` | All Livebook gates |
| `showcase` scenario path | That showcased example |
| Shared `showcase/...` path | All showcased examples and full showcase gate |
| `mix.exs`, `mix.lock`, or `config/...` | All examples and global gates |
| Root or guide documentation | Documentation gate |
| Unrelated path | No affected proof surface |

An empty changed selection is a successful result with a clear message. It must
not claim that scenario proof ran.

## Livebook Contract

The Livebook gate is a code-cell smoke test. Do not call it capability proof.

The runner must:

- evaluate Elixir cells in order;
- preserve binding between cells;
- report the cell number and source line after a failure;
- run each Livebook in an isolated process;
- remove `Mix.install` only in documented project mode;
- run without provider credentials for deterministic examples.

The Support Agent Livebook must teach the same controlled tool-call scenario. It
must include explicit checks for the results that it states. It can contain
duplicate presentation code. It must not define the verified capability list.

Standalone files in `examples/guides/` remain documentation assets. They do not
create scenario capability proof.

## Showcase Contract

The showcase remains a curated surface. It does not need one route for every
future example.

Structured showcase metadata must replace the Boolean-only contract for cataloged
examples. The Support Agent metadata must name its route, LiveView, AgentView,
owned source paths, and focused test paths.

Add one focused Phoenix test that:

- mounts `/agents/support`;
- confirms that the route renders;
- confirms that the page uses `JidokaExamples.SupportAgent.Agent`;
- confirms that the supervised agent is available;
- checks the important source links;
- checks reset behavior without a real provider call.

Focused mode runs showcase compile and the Support Agent showcase test. Full mode
runs showcase compile once and the full showcase suite once.

The existing non-cataloged showcase agents remain an inventory. Do not report
their manual documentation as verified scenario proof during this plan.

## Documentation Contract

Use these responsibilities:

- Scenario README: durable explanation and run instructions.
- ExUnit: verified capability behavior.
- Livebook: executable walkthrough.
- CLI: deterministic demonstration.
- Showcase: optional interactive presentation.
- Generated index: discovery and coverage navigation.

`PROVEN_FEATURES.md` must be generated from a successful full proof report. It
must link each verified capability to:

- example;
- scenario;
- case;
- ExUnit test;
- Livebook;
- optional showcase route.

Do not put local durations, timestamps, or environment values in the committed
generated section.

Relabel any manual showcase table as inventory until each entry has cataloged
proof cases.

Remove strict catalog loading from normal root Mix project configuration.
Discover ExDoc example extras with a safe path list or glob. An incomplete
manifest must not stop `mix deps.get`, `mix format`, or the proof checker from
starting.

Include each scenario README and Livebook in ExDoc. Keep the README as the main
narrative and the Livebook as its executable companion.

## Machine Report

The JSON output must have a stable schema version.

Top-level fields:

```elixir
%{
  schema_version: 1,
  status: :ok,
  selection: %{
    mode: :all,
    examples: [:support_agent],
    reasons: []
  },
  cases: [],
  gates: [],
  coverage: %{}
}
```

Every gate result must contain:

```elixir
%{
  id: :support_agent_exunit,
  scope: :scenario,
  subject: :support_agent,
  status: :ok,
  duration_ms: 120,
  message: nil,
  command: ["mix", "test", "..."]
}
```

Coverage is derived only from passed case results. A surface gate can pass or
fail, but it cannot add a capability.

## Implementation Phases

Each phase must leave a clear handoff for the next model. Do not combine all
phases into one large change.

### Phase 0: Preserve The Baseline

Goal: create tests that describe the current entry commands before the hard cut.

Work:

- Record the current Support Agent command, focused check, and full check output.
- Add a test that confirms no real provider or network capability is selected.
- Add a package-boundary test for production compilation.
- Keep the current working changes intact.

Acceptance criteria:

- The current Support Agent path passes before schema migration.
- The root production build contains no example modules.
- The showcase build contains the Support Agent `lib/` modules only. It does not
  contain Mock LLM, test, proof formatter, or example runner modules.

### Phase 1: Add Version 2 Contracts

Goal: make declarations precise and remove proof status from the manifest.

Work:

- Rename the feature catalog concept to capabilities.
- Add version 2 example, scenario, case, surface, ExUnit-result, case-result,
  gate-result, and proof-report structs.
- Add all manifest validation rules.
- Add `_support/` as a reserved non-example directory.
- Add catalog tests with two temporary valid examples.
- Add invalid ID, duplicate, unknown capability, empty `proves`, overlapping
  `proves` and `uses`, bad path, and bad surface tests.

Acceptance criteria:

- Version 2 contracts and tests exist, but version 1 remains the active path until
  the Phase 3 hard cut.
- The catalog cannot declare pass status.
- Every case has a unique and valid contract.
- Catalog errors name the exact example, scenario, case, and field.
- The implementation does not attempt to run both schemas at the same time.

Suggested commit:

```text
refactor(examples): define versioned proof scenario contracts
```

### Phase 2: Make ExUnit Authoritative

Goal: collect one result for every declared proof case.

Work:

- Add the small ExUnit formatter under `examples/_support/`.
- Load it only for proof-check runs.
- Write the result artifact outside the repository.
- Validate missing, duplicate, unknown, skipped, excluded, failed, and timed-out
  case results.
- Sort asynchronous results before report generation.
- Add formatter and artifact tests.
- Use temporary version 2 manifests in formatter tests. Do not switch the active
  Support Agent manifest in this phase.

Acceptance criteria:

- Exactly one ExUnit result exists for every selected case.
- Only a passed case adds its declared capabilities to verified coverage.
- A scenario runner cannot create a successful proof result.
- Normal `mix test` leaves no proof artifact.

Suggested commit:

```text
test(examples): make ExUnit proof cases authoritative
```

### Phase 3: Migrate And Harden Support Agent

Goal: make the Support Agent the complete reference implementation.

Work:

- Migrate its manifest to version 2.
- Switch the active catalog and proof execution to version 2 in the same change.
- Move proof tests under `examples/support_agent/test/`.
- Add the three tagged cases.
- Replace mailbox-only ordering checks with timeline indexes and state invariants.
- Add an injected exact action counter.
- Fix the not-found Mock LLM response.
- Replace stale date-sensitive wording or data.
- Change `Example.run/1` to one demonstration path with no copied claims.
- Keep the Mock LLM deterministic and local.
- Remove active version 1 loading after the migration passes.

Acceptance criteria:

- One example contains one scenario and three passing cases.
- No capability map is duplicated in the runner or test.
- No version 1 compatibility path remains.
- The not-found answer has no blank carrier or ETA text.
- The approval case proves no action before approval and exactly one action after
  approval.
- No provider key, network request, or recorded fixture is used.

Suggested commit:

```text
refactor(examples): harden support agent proof cases
```

### Phase 4: Split Planning, Execution, And Reporting

Goal: make the checker testable and safe at larger scale.

Work:

- Extract the pure planner.
- Extract the Port-based executor.
- Extract the console, JSON, and document reporter.
- Remove multi-scenario runtime execution from the parent Mix VM.
- Add multiple test-file discovery.
- Add bounded example-process concurrency.
- Add warm-build and no-compile worker behavior.
- Add streamed verbose output and bounded failure tails.
- Add central timeout budgets and child cleanup tests.

Acceptance criteria:

- Gate plans are pure data with stable order.
- A focused check runs no unrelated example or global gate.
- A worker crash or timeout fails one named gate and does not crash the checker.
- Verbose output appears while a command runs.
- JSON output includes durations and no progress text.

Suggested commit:

```text
refactor(examples): isolate and plan proof execution
```

### Phase 5: Harden Livebook And Showcase Surfaces

Goal: verify the selected user surfaces without treating them as capability
proof.

Work:

- Improve sequential Livebook cell evaluation and failure locations.
- Label the gate as a code-cell smoke test.
- Add structured showcase metadata.
- Add the focused Support Agent LiveView test.
- Replace source-text agreement checks with executable checks where possible.
- Keep full showcase execution for the full plan only.

Acceptance criteria:

- A failed Livebook cell names its cell and source line.
- A missing or broken Support Agent route fails its focused gate.
- A wrong agent module fails the focused showcase test.
- Focused mode does not run unrelated showcase tests.
- Livebook and showcase results do not add capability coverage.

Suggested commit:

```text
test(showcase): verify support agent proof surface
```

### Phase 6: Make Publication Transactional

Goal: prevent unverified or partial coverage from entering committed docs.

Work:

- Generate the candidate proof document after all required gates pass.
- Disallow `--update-proof` with focused or changed selection.
- Use document comparison for a normal full check and publication in its place
  for a full update check.
- Write through a temporary file and atomic rename.
- Add capability-to-case and surface links.
- Relabel manual showcase claims as inventory.
- Remove strict catalog evaluation from root Mix project startup.
- Add each scenario README and Livebook to ExDoc through safe discovery.

Acceptance criteria:

- Failed checks do not modify `PROVEN_FEATURES.md`.
- Focused checks cannot update global verified coverage.
- Two successful updates produce no second diff.
- Normal Mix commands work while a manifest is incomplete.
- The generated document contains only stable data.

Suggested commit:

```text
docs(examples): publish verified capability coverage
```

### Phase 7: Harden Changed Selection And CI

Goal: make the proof command an enforced repository contract.

Work:

- Implement and test the changed-file impact table.
- Include rename and deletion paths.
- Validate the Git base before diff work.
- Add selection reasons to console and JSON reports.
- Add a required CI proof job.
- Store the JSON proof report as a CI artifact.
- Keep the full offline check on merge queue and `main`.

Acceptance criteria:

- Every impact rule has a table-driven test.
- A guide-only change runs that guide gate only.
- A Support Agent change runs only its scenario surfaces.
- A core runtime change selects all examples.
- A full CI run checks all scenario, Livebook, showcase, documentation, and
  generated-proof gates.
- CI cannot pass with stale proof documentation.

Suggested commit:

```text
ci(examples): enforce the verified proof model
```

### Phase 8: Remove Old Proof Code And Close Gaps

Goal: leave one proof path and no compatibility debris.

Work:

- Remove the old `Proof` struct and feature-level code.
- Remove runtime claim equality checks.
- Remove the old fixed test-path field.
- Remove obsolete source-text checks.
- Remove duplicate documentation statements.
- Add an end-to-end focused command test and one full command test.
- Remove `examples/` from normal root `test_paths` after the required proof CI job
  exists. Keep checker meta-tests under root `test/`.
- Run package, example, docs, and showcase quality gates.

Acceptance criteria:

- One code path owns proof results.
- No file calls declared coverage a passed result before ExUnit completes.
- No scenario code is part of root production compilation.
- The final focused and full commands pass from a clean build.

Suggested commit:

```text
refactor(examples): remove legacy proof paths
```

## Required Checker Meta-Tests

Use temporary example roots and injected command results where possible. Do not
add a second real example only to test the checker.

Required cases:

- two valid temporary examples;
- multiple test files in one example;
- no test files;
- missing proof test;
- duplicate proof test;
- unknown proof tag;
- passed, failed, skipped, excluded, and timed-out proof tests;
- stable asynchronous result ordering;
- invalid manifest while normal Mix commands still start;
- manifest agent and reported agent mismatch;
- duplicate action, control, support, or helper module;
- compiler warning in example or support code;
- focused and full plans;
- every changed-file rule;
- rename and deletion selection;
- guide-only selection;
- no affected proof surfaces;
- worker exception, exit, timeout, partial output, and cleanup;
- Livebook cell failure and source location;
- missing showcase route;
- wrong showcase agent;
- failed transactional proof update;
- stable JSON schema;
- stable gate order;
- one real focused Support Agent check;
- one real full check.

Most planner, catalog, and reporter tests must not start Mix subprocesses. Keep
the expensive end-to-end tests few and explicit.

## Quality Gates

During implementation, use the smallest complete gate for each phase.

Before each commit:

```bash
mix format --check-formatted
mix test
mix jidoka.examples.check --example support_agent
```

Before final completion:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix quality
mix jidoka.examples.check
```

Also run in `showcase/`:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Dynamic example compilation must fail on compiler warnings. Root compile and
Dialyzer do not compile example code, so the example checker must own this rule.

## Completion Criteria

The proof-model work is complete when all of these statements are true:

- The Support Agent is the only cataloged real example.
- It has one `controlled_tool_call` scenario.
- It has three named deterministic proof cases.
- ExUnit is the only capability-proof authority.
- Every declared case maps to exactly one ExUnit result.
- Failed, skipped, missing, duplicated, or timed-out cases prove nothing.
- Capability coverage is derived from passed case results.
- The runner has no capability claim map.
- `compiled`, `executed`, and `live` are not proof levels.
- CLI, Livebook, and showcase have separate surface results.
- The not-found result is correct and tested.
- Approval has causal and exactly-once assertions.
- Focused checks run all and only relevant gates.
- Full checks run all scenario and global gates.
- Verbose output streams while commands run.
- Timeout failures preserve partial output and clean child processes.
- `--update-proof` is full-run-only and transactional.
- The full checker is a required CI job.
- The normal root test suite does not run all example proof tests a second time.
- The committed proof document is reproducible.
- Normal root Mix commands do not strictly load all manifests.
- Root production compilation contains no example modules.
- Showcase compilation contains only declared example `lib/` modules.
- No generator or scenario DSL was added.

## Risks And Controls

### False semantic claims

A test tag can name a case whose assertions are too weak.

Control: keep capabilities concrete, keep `proves` lists short, and require code
review to compare each case declaration with its assertions.

### ExUnit formatter changes

The formatter uses ExUnit event contracts that can change between supported
Elixir versions.

Control: keep the formatter small and test it on all supported Elixir and OTP
versions.

### Worker process cost

One OS process per example adds startup cost.

Control: warm the build once, use no-compile workers, use bounded concurrency,
and shard the full catalog in CI when the catalog becomes large.

### Incorrect changed-file selection

A missed dependency can omit required proof.

Control: keep impact rules in one table, test every rule, and always run the full
check on the merge queue and `main`.

### Manifest growth

The manifest can become a second implementation language.

Control: keep it to identity, scenario and case declarations, and surface
metadata. Keep execution and assertions in normal Elixir code.

### Livebook confidence

Code-cell evaluation is not the complete Livebook runtime.

Control: name it a smoke test and keep UI claims out of capability coverage.

### Showcase coupling

Shared Phoenix code can affect every showcased example.

Control: run focused route tests for scenario changes and the full showcase suite
for shared changes and full checks.

## Work Sequence

Use this dependency order:

```text
Phase 0 baseline
  -> Phase 1 contracts
  -> Phase 2 ExUnit authority
  -> Phase 3 Support Agent migration
  -> Phase 4 checker execution
  -> Phase 5 surfaces
  -> Phase 6 publication
  -> Phase 7 CI and changed selection
  -> Phase 8 cleanup
```

Do not start additional example migrations during these phases. The completed
Support Agent must first prove that the model is small, strict, clear, and fast.
