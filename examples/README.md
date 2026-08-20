# Jidoka Examples

Each folder under `examples/` is one complete deterministic reference agent.
It owns the agent code, scenario code, metadata, ExUnit tests, command runner,
README, and Livebook. Example modules compile only in the test environment and
are not part of the production Jidoka application.

## Start Here

If you have not used Jidoka, start with
[`guides/getting-started.md`](../guides/getting-started.md). Then use these
examples in order:

1. **Getting Started** - learn one agent, prompt, and `chat/3` result.
2. **Support Agent** - add one complete tool call and approval flow.
3. **Governed Tools** - add skills, catalog discovery, bounded browser tools,
   and deterministic evals.
4. **Warranty Claim** - add typed context, model policy, media, and results.
5. **Durable Refund** - add asynchronous, observable, and durable runtime behavior.
6. **Workflow Composition** - add a complete graph, agent nodes, loops, background runs,
   and schedules.
7. **Durable Incident Recovery Commander** - combine parallel subagents,
   nested reviews, a suspended workflow, durable recovery, fallback, and replay.

The agent, action, control, instruction, and YAML files are application
patterns. The scenario, optional scripted model, command runner, test, and
manifest files make the examples deterministic and are not required in
production.

`ScriptedLLM` is a model test double. It returns known decisions without a
provider or network request. Production code normally uses the model declared
by the agent or supplies a runtime model policy; it does not pass
`ScriptedLLM` as `:llm`.

The small `loader.exs` file only starts examples outside the test environment.
It keeps the Spark compile order out of each command runner and Livebook. Mix
compiles the same source files normally when it runs the example tests.

## Run Examples

```bash
mix run examples/getting_started/example.exs
mix run examples/support_agent/example.exs
mix run examples/warranty_claim/example.exs
mix run examples/durable_refund/example.exs
mix run examples/workflow_composition/example.exs
mix run examples/incident_recovery_commander/example.exs
```

## Test Examples

The root `mix test` command runs the example tests with the rest of the suite.
Use standard ExUnit tags for focused runs:

```bash
mix test --only example:support_agent
mix test --only tool_calling
mix test examples/durable_refund/test/execution_and_continuation_test.exs --trace
mix test --only example:incident_recovery_commander
```

The YAML manifest lists the aggregate features for an example. Tags on each
ExUnit test show the exact features that the scenario verifies.

The first three feature-inventory sections are a closed milestone. Run their
focused provider-free parity proofs with:

```bash
mix test --include parity test/parity
```

## First Three Sections

All 25 features have product code, deterministic tests, public guides, and an
executable example path.

| ID | Contract | Example coverage |
| --- | --- | --- |
| A01 | Code-first agent definition | Getting Started and Warranty Claim: `code_first_authoring` |
| A02 | Data-defined agent spec and serialization | Warranty Claim: `data_defined_authoring` |
| A03 | Dynamic instructions | Warranty Claim: `dynamic_instructions` |
| A04 | Typed context injection | Warranty Claim: `typed_context` |
| A05 | Provider/model abstraction | Getting Started and Warranty Claim: `provider_model_abstraction` |
| A06 | Routing, fallback, and model retry | Warranty Claim: `model_routing` |
| A07 | Typed structured result | Warranty Claim: `structured_results` |
| A08 | Bounded result repair | Warranty Claim: `result_repair` |
| A09 | Multimodal input and output | Warranty Claim: `multimodal_content` |
| E01 | Synchronous and asynchronous runs | Getting Started: `synchronous_execution`; Durable Refund: `async_execution` |
| E02 | Token and semantic event streaming | Durable Refund: `event_streaming` |
| E03 | Parallel tools with ordered observations | Durable Refund: `parallel_tool_calling` |
| E04 | Execution limits | Durable Refund: `execution_budgets` |
| E05 | Cancellation evidence | Durable Refund: `cancellation` |
| E06 | Serializable pause and resume | Support Agent: `serializable_pause_resume` |
| E07 | Crash-safe durable execution | Durable Refund: `crash_recovery` |
| E08 | Data replay and safe forks | Durable Refund: `data_only_replay`, `safe_session_fork` |
| W01 | Sequential typed steps | Workflow Composition: `sequential_typed_steps` |
| W02 | Conditional routing | Workflow Composition: `conditional_routing` |
| W03 | Parallel fan-out and ordered fan-in | Workflow Composition: `parallel_fan_out` |
| W04 | Bounded loops and dynamic work | Workflow Composition: `bounded_dynamic_loops` |
| W05 | Bounded step retry | Workflow Composition: `bounded_step_retry` |
| W06 | Workflow exposed as one agent tool | Workflow Composition: `workflow_tool` |
| W07 | Reconnectable background work | Workflow Composition: `background_runs` |
| W08 | One-time and cron schedules | Workflow Composition: `scheduled_runs` |

A02 is complete inside the versioned Jidoka document format. E07 is complete
for the documented single-node durable contract and application-owned store
extension. E08 means data-only replay and lineage-aware forks from safe
snapshots; it does not mean arbitrary state editing or effect re-execution.

## Existing Capability Proof Coverage

The same example suite now provides executable evidence for all 23 features
that had product code but no grouped example proof. Complete features prove
their shipped contract. Partial and bounded features prove only the named
boundary.

| ID | Shipped boundary | Example coverage |
| --- | --- | --- |
| G01 | Input controls | Support Agent: `input_controls` |
| G02 | Output controls | Support Agent: `output_controls` |
| G03 | Operation policy | Support Agent: `operation_policy` |
| G05 | Trace redaction policy | Durable Refund: `trace_redaction` |
| M04 | Static agent workflow composition (partial) | Workflow Composition: `static_multi_agent_workflow` |
| O01 | Ordered lifecycle events | Support Agent: `lifecycle_events` |
| O02 | Local inspection and effect-free preflight | Getting Started: `local_inspection` |
| O03 | Local sequence-stable trace sink (partial) | Durable Refund: `local_trace_sink` |
| O04 | Usage and cost aggregation | Durable Refund: `usage_accounting` |
| O05 | Deterministic behavioral evals | Governed Tools: `deterministic_evals` |
| O06 | Repeatable cases grouped by application code (partial) | Governed Tools: `repeatable_eval_cases` |
| O07 | Public trajectory assertions (partial) | Governed Tools: `trajectory_assertions` |
| R01 | Process-hosted agent | Durable Refund: `process_hosted_agent` |
| R04 | Development-only Kino evidence (partial) | Governed Tools: `local_developer_notebook` |
| R05 | Stable UI projection | Support Agent: `ui_projection` |
| R07 | Provider-free capability injection | Getting Started: `provider_free_testing` |
| S02 | Serializable checkpoint state | Durable Refund: `checkpoint_state` |
| T01 | Schema-derived action tool | Governed Tools: `schema_derived_tools` |
| T02 | Static tool narrowing (partial) | Governed Tools: `static_tool_narrowing` |
| T03 | Progressive catalog discovery | Governed Tools: `catalog_discovery` |
| T04 | Skill prompt and action bundle | Governed Tools: `skill_bundle` |
| T06 | Effect idempotency and completed-result reuse | Durable Refund: `effect_idempotency` |
| T11 | Read-only allowlisted browser tools (bounded) | Governed Tools: `read_only_browser_tools` |

Run all Livebooks without their standalone `Mix.install` calls:

```bash
mix run scripts/check_livebooks.exs -- --project examples/*/*.livemd guides/livebooks/*.livemd
```

## Example Layout

```text
examples/<name>/
├── README.md
├── manifest.yaml
├── example.exs
├── <name>.livemd
├── lib/
│   ├── agent.ex
│   ├── scenario.ex
│   ├── scripted_llm.ex  # optional for multi-step model behavior
│   ├── actions/
│   ├── controls/
│   └── scenarios/       # optional for examples with several workflows
└── test/
    └── <scenario>_test.exs
```

## Choose An Example

| Example | Level | Read it to learn |
| --- | --- | --- |
| Getting Started | Beginner | Agent definition, preflight, and one text answer |
| Support Agent | Intermediate | Tools, controls, approval, serialized pause, and resume |
| Governed Tools | Advanced | Skills, catalogs, bounded browser tools, evals, and Kino evidence |
| Warranty Claim | Advanced | Data authoring, typed results, media, fallback, and repair |
| Durable Refund | Expert | Async work, traces, usage, process hosting, recovery, and forks |
| Workflow Composition | Expert | Typed graphs, agent nodes, branches, loops, background work, and schedules |
| Durable Incident Recovery Commander | Stress | Parallel subagents, nested approvals, suspended workflows, DETS restart, fallback, and replay |

Use Getting Started for the smallest complete agent. Use the Support Agent for
a controlled tool flow. Use Governed Tools for bounded capability composition
and local quality evidence. Use the Warranty Claim for agent authoring, model
policy, structured results, and multimodal content. Use the Durable Refund
Agent for asynchronous execution, cancellation, traces, usage, process hosting,
durable recovery, and safe session forks. Use Workflow Composition for
deterministic business graphs, bounded agent nodes, runtime-created work,
reconnectable jobs, and cron triggers. Use the Durable Incident Recovery
Commander to test the combined durable orchestration boundary.
