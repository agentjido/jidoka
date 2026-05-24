# V3 Baseline Report

Baseline for beadwork epic `jidoka-3di.1` on `main`.

Generated during the V3 clean-surface milestone before implementation work.

## Summary

- Current unit suite: `410 tests, 0 failures`.
- Current coverage run: `72.3%`, below configured `75%` threshold.
- Current docs build: `mix docs --warnings-as-errors` passes.
- Current compile check: `mix compile --warnings-as-errors` passes.
- Current formatter check: `mix format --check-formatted` passes.
- Current xref cycles: `2`.
- Current source/test size: `37,673` total Elixir lines across `lib` and `test`.
- Current support trees intentionally removed from working tree: `dev/`,
  `examples/`, `guides/`, `livebook/`, demo mix task, demo support modules, and
  stale demo/eval tests.

## Public API Baseline

Current top-level `Jidoka` facade exposes these public groups:

- Model helpers: `model_aliases/0`, `model/1`.
- Runtime lifecycle: `start_agent/2`, `stop_agent/2`, `whereis/2`,
  `list_agents/1`.
- Imported agents: `import_agent/2`, `import_agent!/2`, `import_agent_file/2`,
  `import_agent_file!/2`, `encode_agent/2`, `encode_agent!/2`.
- Errors: `format_error/1`.
- Chat turns: `chat/3`, `chat_stream/3`, `start_chat_request/3`,
  `await_chat_request/2`.
- Schedules: `schedule/2`, `schedule_agent/2`, `schedule_workflow/2`,
  `list_schedules/1`, `cancel_schedule/2`, `run_schedule/2`.
- Handoffs: `handoff_owner/1`, `reset_handoff/1`.
- Inspection and debugging: `inspect_agent/1`, `inspect_workflow/1`,
  `inspect_request/1`, `inspect_request/2`, `inspect_trace/1`,
  `inspect_trace/2`, `inspect_compaction/2`.
- Compaction: `compact/2`.
- Internal request helpers still public with `@doc false`:
  `chat_request/3`, `finalize_chat_request/3`.

Current ExDoc module groups:

- Agents: `Jidoka.Agent`, `Jidoka.Agent.SystemPrompt`, `Jidoka.AgentView`,
  `Jidoka.Agent.View`, `Jidoka.ImportedAgent`,
  `Jidoka.ImportedAgent.Subagent`.
- Workflows: `Jidoka.Workflow`.
- Runtime: `Jidoka`, `Jidoka.Session`, `Jidoka.Kino`, `Jidoka.Runtime`,
  `Jidoka.Schedule`, `Jidoka.Schedule.Manager`, `Jidoka.Compaction`,
  `Jidoka.Compaction.Prompt`, `Jidoka.Trace`, `Jidoka.Trace.Event`,
  `Jidoka.Interrupt`, `Jidoka.Handoff`.
- Extensions: `Jidoka.Character`, `Jidoka.Tool`, `Jidoka.Plugin`,
  `Jidoka.Hook`, `Jidoka.Guardrail`, `Jidoka.Web`, `Jidoka.Subagent`,
  `Jidoka.Handoff.Capability`, `Jidoka.MCP`.
- Errors: `Jidoka.Error`.

V3 implication: the public surface still exposes pre-V3 nouns (`Hook`,
`Guardrail`, `Tool`) and should be reviewed under E1, E4, and E5.

## Generated Agent Function Baseline

Generated agents currently expose:

- Runtime entrypoints: `start_link/1`, `chat/3`, `runtime_module/0`.
- Contract metadata: `id/0`, `configured_model/0`, `model/0`,
  `instructions/0`, `character/0`, `context/0`, `context_schema/0`.
- Structured result metadata: `output/0`, `output_schema/0`.
- Lifecycle/state metadata: `schedules/0`, `compaction/0`, `memory/0`.
- Capability metadata: `skills/0`, `skill_load_paths/0`, `mcp_tools/0`,
  `web/0`, `subagents/0`, `workflows/0`, `handoffs/0`, `plugin_modules/0`,
  `plugin_names/0`, `tools/0`, `ash_resources/0`.
- Pre-V3 lifecycle metadata: `hooks/0`, `before_turn_hooks/0`,
  `after_turn_hooks/0`, `interrupt_hooks/0`, `guardrails/0`,
  `input_guardrails/0`, `output_guardrails/0`, `tool_guardrails/0`.

V3 implication: generated functions need a naming pass after the DSL nouns are
finalized. In particular, `output` versus `result`, `tool` versus `action`, and
hooks/guardrails versus controls are unresolved.

## DSL Baseline

Current agent DSL extension sections:

- `agent`
- `defaults`
- `capabilities`
- `lifecycle`
- `schedules`
- `memory`
- legacy top-level sections: `tools`, `skills`, `plugins`, `subagents`,
  `hooks`, `guardrails`

Current `agent` section:

- Options: `id`, `model`, `system_prompt`, `description`, `schema`.
- Nested section: `output`.
- Current docs still describe `model` and `system_prompt` as legacy placement.

Current `defaults` section:

- Options: `model`, `instructions`, `character`.

Current `capabilities` entities:

- `tool`
- `ash_resource`
- `mcp_tools`
- `skill`
- `load_path`
- `plugin`
- `web`
- `subagent`
- `workflow`
- `handoff`

Current lifecycle surface:

- Hooks: before turn, after turn, interrupt.
- Guardrails: input, output, tool.
- Compaction and memory live under lifecycle-related code paths, with memory also
  represented by top-level DSL compatibility code.

Current workflow DSL:

- Standalone `use Jidoka.Workflow`.
- Steps include tool/action, function, and agent-style steps.

V3 implication: E1 should delete the legacy sections, move agent-owned config
inside `agent :id do ... end`, and make controls the single public policy noun.

## Feature-To-Test Matrix

| Feature | Current test coverage | Baseline status |
| --- | --- | --- |
| Agents | `agent_basics_test`, `dsl_validation_test`, `system_prompt_test`, fixtures | Covered, but DSL nouns are pre-V3. |
| Chat turns | `runtime_error_normalization_test`, `chat_stream_test`, `public_api_test` | Covered for normal and streaming paths. |
| Sessions | `session_test`, `agent_view_test`, `schedule_test`, handoff tests | Covered as addressing, not persistence. |
| Context | `context_memory_test`, `agent_basics_test`, `session_test` | Covered; needs V3 mental-model refinement. |
| Typed results | `output_test`, imported agent tests | Covered; naming still says `output`. |
| Actions / tools | `tools_plugins_test`, `skills_mcp_test`, `ash_resource_test`, workflow capability tests | Covered unevenly; action/tool naming unresolved. |
| Controls | `guardrails_test`, `hooks_test`, `hook_guardrail_contract_test`, runtime error tests | Covered under old hook/guardrail nouns. |
| Human-in-the-loop | `interrupt_test`, `session_test`, guardrail/handoff tests | Partially covered through interrupts and approvals. |
| Credential brokering | No first-class tests. | Gap. Requires E6 design and redaction tests. |
| Debugging | `debug_summary_test`, `inspection_test`, `kino_test`, `trace_test` | Covered; needs first-class docs and redaction pass. |
| Observability standards | `trace_test` plus telemetry-adjacent runtime tests | Partial. Needs correlation-field tests across all feature paths. |
| Memory | `memory_test`, `context_memory_test`, `trace_test` | Covered; coverage and docs need review. |
| Compaction | `compaction_test` | Covered; line coverage near threshold but module is large. |
| Streaming and AgentView | `chat_stream_test`, `agent_view_test`, `agent_view_contract_test` | Covered; naming and UI docs need V3 pass. |
| Schedules | `schedule_test` | Covered; needs schedule-placement decision for V3 DSL. |
| Workflows | `workflow_test`, `workflow_validation_test`, `workflow_runtime_unit_test`, `workflow_capability_test`, `workflow_spike_test` | Covered; terminology and action integration need review. |
| Subagents and handoffs | `subagents_test`, `subagent_unit_test`, `handoffs_test`, trace tests | Covered; human-in-loop cross-boundary tests are a gap. |
| Tool integrations | `skills_mcp_test`, `web_capability_test`, `ash_resource_test`, plugin tests | Covered unevenly; live MCP test is tagged. |
| Imported agents | `imported_agent_test`, `imported_agent_validation_test` | Heavily covered; largest test file and likely refactor target. |
| Durability and graduation | No direct durable runtime tests. | Gap. Should stay docs/contract unless V3 creates a persistence layer. |
| Testing | Current suite is broad, but coverage threshold fails. | Gap. E17 should rebuild example smoke tests after DSL freeze. |

## Coverage Baseline

Command: `mix test --cover`.

Result:

- Test result: `410 tests, 0 failures`.
- Coverage result: `72.3%`.
- Configured threshold: `75%`.
- Command exit status: failed because coverage is below threshold.

Lowest or strategically important coverage areas:

- `lib/jidoka/agent/capabilities/ash_resources.ex`: `5.8%`.
- Verifiers: `verify_memory`, `verify_guardrails`, `verify_hooks`,
  `verify_plugins`, `verify_skills`, `verify_subagents`, `verify_tools` are
  mostly below `25%`.
- Web tool modules: `search_web` `0.0%`, `snapshot_url` `16.6%`,
  `read_page` `25.0%`.
- `lib/jidoka/imported_agent/runtime/subagent.ex`: `0.0%`.
- `lib/jidoka/workflow/codegen.ex`: `0.0%`.
- `lib/jidoka/plugin.ex`: `38.1%`.
- `lib/jidoka/agent_view.ex`: `45.0%`.
- `lib/jidoka/schedule/executor.ex`: `55.9%`.
- `lib/jidoka/schedule/manager.ex`: `58.3%`.
- `lib/jidoka/session.ex`: `60.2%`.

V3 implication: coverage should not be lifted by brittle internal tests. E17/E18
should raise coverage through public contract tests and feature smoke tests after
the DSL surface settles.

## Xref And File Size Baseline

Command: `mix xref graph --format cycles`.

Result:

- 2 cycles found.

Cycle 1:

- Length: 24 modules, 7 export dependencies.
- Areas involved: chat, compaction, session, imported agents, workflow runtime,
  subagent runtime, handoff/workflow capabilities, MCP/skill capability code,
  inspection/debug.
- V3 implication: capability/runtime/imported-agent boundaries are tangled and
  should be simplified during E4, E7, E12, E13, E14, and E15.

Cycle 2:

- Length: 3 modules.
- Modules: `Jidoka`, `Jidoka.Schedule.Executor`, `Jidoka.Schedule.Manager`.
- V3 implication: schedule execution should not call through the top-level
  facade if it can call the underlying chat/workflow modules directly.

Largest files by line count:

- `test/jidoka/imported_agent_test.exs`: `911`.
- `lib/jidoka/compaction.ex`: `790`.
- `test/support/jidoka_tool_plugin_subagent_fixtures.ex`: `715`.
- `test/jidoka/imported_agent_validation_test.exs`: `504`.
- `lib/jidoka/capability/handoff/runtime.ex`: `504`.
- `lib/jidoka/capability/subagent/runtime/executor.ex`: `500`.
- `lib/jidoka/workflow/definition.ex`: `487`.
- `lib/jidoka/lifecycle/memory.ex`: `487`.
- `test/jidoka/compaction_test.exs`: `478`.
- `lib/jidoka/imported_agent/io/codec.ex`: `476`.
- `lib/jidoka/trace/collector.ex`: `471`.
- `lib/jidoka/session.ex`: `468`.
- `lib/jidoka/agent/runtime/view.ex`: `467`.
- `test/jidoka/subagents_test.exs`: `463`.
- `lib/jidoka/imported_agent/schema/validator.ex`: `458`.
- `lib/jidoka/error/normalize.ex`: `456`.
- `lib/jidoka/output/runtime.ex`: `444`.
- `lib/jidoka/imported_agent/schema/schema.ex`: `443`.
- `lib/jidoka/inspection/debug.ex`: `435`.
- `lib/jidoka/agent_view.ex`: `429`.

V3 implication: several feature epics should include file decomposition work,
but only when the feature is actively being reshaped.

## Docs, Examples, And Livebook Baseline

Current working tree has zero files under:

- `dev/`
- `examples/`
- `guides/`
- `livebook/`

These support trees are intentionally removed for the V3 refactor. Current docs
source is the package README plus ExDoc extras:

- `README.md`
- `CHANGELOG.md`
- `CONTRIBUTING.md`
- `LICENSE`
- `usage-rules.md`

Command: `mix docs --warnings-as-errors`.

Result: passes.

V3 implication: docs/examples/Livebooks should be rebuilt after Gate A and Gate
B, not restored from the old support trees.

## Live Provider And Deterministic Test Baseline

Default ExUnit config excludes `llm_eval: true`.

Current explicit live-style tag:

- `test/jidoka/skills_mcp_test.exs:248` uses `@tag :mcp_live`.

Current provider/environment touchpoints in tests:

- `test/jidoka/kino_test.exs` manipulates `ANTHROPIC_API_KEY` and
  `LB_ANTHROPIC_API_KEY`, but includes missing-provider tests and does not
  require live model calls.
- `test/jidoka/public_api_test.exs` sets model aliases.
- MCP sync tests use fake sync modules except for the tagged live MCP case.

V3 implication: live checks should remain tagged smoke tests. Feature correctness
must be proven through deterministic provider-free tests.

## Support Trees Staying Deleted

Keep these deleted while the V3 surface is being reshaped:

- `dev/jidoka_consumer`
- `examples`
- `guides`
- `livebook`
- `lib/jidoka/demo*`
- `lib/mix/tasks/jidoka.ex`
- stale demo/eval/example tests removed with those support trees

Rationale: all of these encode pre-V3 terminology or teaching order. Restoring
them now would multiply refactor work.

## Release Gate

V3 beta should not be considered releasable until:

- Gate A through Gate E in `MILESTONE_V3.md` are closed.
- `mix format --check-formatted` passes.
- `mix compile --warnings-as-errors` passes.
- `mix test` passes.
- `mix test --cover` meets or intentionally revises the configured threshold.
- `mix docs --warnings-as-errors` passes.
- `mix doctor --raise` passes or documented package-doc exceptions are accepted.
- `mix xref graph --format cycles` is clean or remaining cycles are documented.
- Every canonical example rebuilt in E17 has a smoke test.
- Any live provider tests are tagged and not required for normal CI.
- Any deferred credential, catalog, or durability work has an explicit contract
  and follow-up issue.

## V3 Decision Log

- V3 is a clean-surface milestone. No compatibility aliases for discarded alpha
  APIs or DSL shapes.
- `Jidoka.chat/3` remains the public turn primitive unless E2 proves a better
  smaller surface.
- `Jidoka.Session` remains conversation addressing, not durable storage.
- Controls are the intended public policy noun; hooks and guardrails are
  candidates for deletion, renaming, or private implementation.
- Credential brokering must prove the no-secret-leak invariant before shipping
  any execution behavior.
- Durability is a graduation path unless a separate persistence implementation
  is created and tested.
- Old support trees stay deleted until the V3 DSL and core runtime freeze.
