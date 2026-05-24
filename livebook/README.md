# Jidoka LiveBooks

This folder is the runnable onboarding path for new Jidoka users. Each notebook
should teach one capability through a small, complete example that can be run in
a fresh LiveBook session.

## Template Notes

- Keep each notebook focused on one learning outcome.
- Start with a short "what you will build" paragraph, then get to runnable code
  quickly.
- Include a "Run in Livebook" badge near the top that points at the raw GitHub
  URL for the notebook.
- Use a single setup cell with `Mix.install/2`, `:kino`, and `:jidoka` loaded
  from GitHub with a full tested commit `ref`. Avoid `branch: "main"` in
  committed notebooks so LiveBook dependency caching stays predictable.
- If a notebook depends on an API that has not been pinned yet, `branch: "main"`
  is acceptable as a short-lived bridge; replace it with the landing commit ref
  before release docs are cut.
- Call `Jidoka.Kino.setup/1` after dependencies install, then use
  `Jidoka.Kino.start_or_reuse/2` for stable agent IDs.
- Use `Jidoka.Kino.compaction/2` when a notebook demonstrates summary
  compaction, so users can inspect the latest snapshot without reading raw
  state.
- Put deterministic inspection and direct tool/workflow calls before provider
  backed chat cells. Provider-backed cells should use LiveBook secrets such as
  `ANTHROPIC_API_KEY` and fail with a friendly note when the secret is missing.
- Use `Jidoka.Kino.chat/3` when a cell should show both the user-facing result
  and the useful execution trace.
- Prefer Markdown output through `Jidoka.Kino.table/3` or `Kino.Markdown` for
  trace tables. Avoid fragile JavaScript-backed widgets for core tutorial
  output.
- Keep examples source-readable. Avoid committing LiveBook generated section
  placeholders or stamp metadata when syncing from a running session.
- Before landing a notebook, test both the source file and a fresh session from a
  temporary copy so stale outputs and cached dependencies do not hide problems.

## Current Notebooks

Each notebook is independently runnable and starts from a portable GitHub
dependency setup.

| Notebook | Focus |
| --- | --- |
| `01_hello_agent.livemd` | Minimal agent definition, inspection, startup, and chat. |
| `02_tools_and_context.livemd` | Deterministic tools and runtime context. |
| `03_workflows_and_imports.livemd` | Workflow execution, workflow-as-tool behavior, and JSON imports. |
| `04_errors_inspection_debugging.livemd` | Structured errors, formatted messages, inspection, and traces. |
| `05_hooks_and_guardrails.livemd` | Before/after hooks and input guardrails. |
| `06_memory.livemd` | Conversation memory capture, retrieval, and context injection. |
| `07_characters_and_instructions.livemd` | Compile-time characters, instructions, and per-turn character overrides. |
| `08_subagents.livemd` | Manager-controlled specialist agents as tool-like capabilities. |
| `09_handoffs.livemd` | Conversation ownership transfer and handoff owner reset. |
| `10_skills_and_load_paths.livemd` | Module skills, runtime `SKILL.md` load paths, and allowed tool narrowing. |
| `11_mcp_tool_sync.livemd` | MCP endpoint registration, prefixed sync, and bounded sync failures. |
| `12_web_tools.livemd` | Search/read-only web capabilities and private-network safety checks. |
| `13_plugins.livemd` | Plugin-published tools merged into an agent registry. |
| `14_ash_resources.livemd` | Ash resource tool expansion, actor checks, and domain context. |
| `15_imported_agents_deep_dive.livemd` | JSON/YAML imported agents with explicit registries. |
| `16_workflow_patterns.livemd` | Function steps, context refs, debug output, and workflow failures. |
| `17_evals.livemd` | Deterministic eval cases and optional provider-backed checks. |
| `18_phoenix_liveview_consumer.livemd` | `Jidoka.AgentView` as the Phoenix LiveView boundary. |
| `19_production_checklist.livemd` | Provider, runtime, context, guardrail, and inspection pre-flight checks. |
| `20_kitchen_sink.livemd` | Advanced capstone that composes the main Jidoka features in one support-router scenario. |
| `21_structured_output.livemd` | Agent-level typed output, validation, repair, imported specs, and optional provider chat. |
| `22_codebase_agent_harness_spike.livemd` | Live OpenCode harness spike for a Sherlock-style codebase agent wrapped as a Jidoka tool. |

## Acceptance Checklist

- `Mix.install/2` resolves in a fresh LiveBook session.
- `Jidoka.Kino` is available after setup.
- `Jidoka.Kino.compaction/2` renders in notebooks that enable compaction.
- Provider cells either succeed with the configured secret or show a friendly
  missing-secret result.
- Trace output renders without horizontal-only log dumps or widget JavaScript
  errors.
- The notebook source has no generated LiveBook stamp metadata.
