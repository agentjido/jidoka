# Jidoka Usage Rules

Use these rules when generating Jidoka code or reviewing Jidoka examples.

## Agent DSL

- Define agents with `use Jidoka.Agent`.
- Put core configuration inside `agent :id do ... end`.
- Use `context Zoi.object(...)` for runtime context validation.
- Prefer `context:` at runtime. Do not pass `tool_context:` to Jidoka public APIs.
- Use `character` for structured persona/voice data backed by `jido_character`.
  Use `instructions` for task, policy, and safety instructions.
- Use per-call `character:` only when a request should override the configured
  character for that turn.
- Keep prompts explicit. Jidoka does not automatically inject context into model
  prompts unless instructions, controls, actions, or memory configuration do so.

## Extensions

- Use `tools do` only for direct action modules.
- Use `capabilities do` for Ash resources, MCP sync, web access, skills,
  plugins, subagents, workflow operations, and handoffs.
- Treat generated `tools/0` and `tool_names/0` callbacks as the expanded
  model-callable operation surface. They include direct actions plus generated
  action-backed tools from capabilities.
- Use `controls do` for input, operation, and result policy.
- Use `lifecycle do` for runtime behavior such as memory, compaction, and
  lifecycle hooks. Do not put policy decisions there; use controls.
- Expect controls to run through every normal chat path, including sessions,
  schedules, workflows-as-operations, subagents, and handoffs.
- Use `web :search` for search-only agents and `web :read_only` for search plus
  public page reading. Do not expose raw browser automation for low-risk agents.
- Use `subagent` for manager-pattern delegation inside an agent turn. Do not
  model handoffs or workflow graphs as subagents.
- Use `workflow` inside `capabilities do` when an agent should choose a known
  deterministic process as a model-callable operation.
- Keep workflow declarations out of `tools do`. The workflow module owns the
  deterministic process; the agent workflow entry owns how that process is
  exposed as a model-callable operation.
- Use `handoff` inside `capabilities do` when an agent should transfer future
  conversation ownership to another agent for the same `conversation:`.

## Workflow DSL

- Define deterministic workflows with `use Jidoka.Workflow`.
- Keep workflows as a separate `use Jidoka.Workflow` surface. Do not model a
  multi-step workflow as a single action unless the sequence is intentionally
  opaque to Jidoka.
- Put stable workflow identity and input schema inside `workflow do ... end`.
- Use `steps do` for `action`, `function`, and `agent` steps.
- Use `output from(:step)` at module top level.
- Prefer explicit refs: `input(:key)`, `from(:step)`, `from(:step, :field)`,
  `context(:key)`, and `value(term)`.
- Use workflows when application code owns the sequence and data dependencies.
  Use agents for open-ended LLM turns and subagents for delegated capabilities
  inside one agent turn.
- Workflows may call agents as bounded steps, and agents may expose workflows
  as model-callable operations. Keep the boundary explicit: agents decide
  intent; workflows run fixed processes.
- Keep raw execution-graph concepts out of public Jidoka code. Do not expose
  facts, directives, strategy state, or graph nodes in user-authored workflows.

## Imported Agents

- Use `Jidoka.import_agent/2` or `Jidoka.import_agent_file/2` for JSON/YAML specs.
- Resolve imported action refs, characters, hooks, guardrails, plugins, skills,
  subagents, workflows, and handoffs through explicit `available_*` registries.
  Imported `web` capabilities use built-in modes and do not need a registry.
- Prefer inline `defaults.character` maps that parse through `Jido.Character`
  for portable imported specs; use string character refs only when the
  importing application provides `available_characters`.
- Use `Jidoka.ImportedAgent.Subagent` when an Elixir manager agent delegates to a
  JSON/YAML-authored specialist.

## Support Code

- Keep runnable examples outside the core `lib/` surface.
- Keep demo-only wiring out of `lib/`.
- Prefer simple examples first, then kitchen-sink coverage.

## Runtime Errors

- Public runtime APIs should return `{:ok, value}`, `{:interrupt, interrupt}`,
  `{:handoff, handoff}`, or `{:error, %Jidoka.Error.*{}}`.
- Do not expose raw internal error tuples from chat, workflow, subagent,
  handoff, MCP, memory, hook, or control runtime boundaries.
- Use `Jidoka.format_error/1` when printing errors in docs, demos, and CLIs.
- Preserve low-level causes in `error.details.cause`; do not require users to
  pattern-match on those causes.
