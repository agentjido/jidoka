# Glossary

This guide is an alphabetical reference for the vocabulary used across the
Jidoka docs, source, and tests. Each entry gives a short definition, the
module that owns the contract, and the guide that explains the concept in
context. Use it as a lookup when a term appears in another guide and you want a
one-line anchor before reading further.

## When To Use This

- Use this guide when a term in another Jidoka guide or doctring needs a
  precise definition.
- Use this guide as a starting point for navigating module-level docs: every
  row links to the canonical module.
- Do not use this guide as a tutorial. The terms here assume you have already
  read [Getting Started](getting-started.md).

## Prerequisites

- A working install of `:jidoka` and the ability to open module docs with
  `h Jidoka.<Module>` in IEx.
- Familiarity with [Getting Started](getting-started.md) so the term shapes
  (spec, plan, harness, turn) are not new.

## Concepts

Three concept buckets organize every term in this guide:

1. **Authoring**: how an agent is defined. Examples: Agent, DSL, Import,
   Instructions, Spec, Tool.
2. **Data contracts**: immutable values that flow through the runtime.
   Examples: Plan, Turn.Request, Turn.Result, Effect.Intent, Snapshot, Event.
3. **Execution**: process- or capability-side machinery that interprets data.
   Examples: Harness, Runtime, Capability, AgentServer, Memory.Store.

The diagram below shows how the most central terms relate inside a single
turn.

```diagram
╭───────────╮   ╭────────────╮   ╭──────────╮   ╭────────────╮
│ DSL/Import│──▶│ Agent.Spec │──▶│ Turn.Plan│──▶│  Harness   │
╰───────────╯   ╰────────────╯   ╰──────────╯   ╰─────┬──────╯
                                                      │
                            ╭─────────────────────────┴──────────────────────╮
                            ▼                                                ▼
                      ╭───────────╮                                    ╭──────────╮
                      │ Capability│ ⇄ Effect.Intent / Effect.Result ⇄  │ Journal  │
                      ╰───────────╯                                    ╰──────────╯
                            │
                            ▼
                      ╭────────────╮            ╭──────────────╮
                      │ Turn.Result│   or       │  Snapshot    │
                      ╰────────────╯            ╰──────────────╯
```

## How To Read An Entry

Each row in the table follows the same shape:

- **Term**: the canonical name as it appears in source, tests, and docs.
- **Definition**: one paragraph; precise rather than friendly.
- **Module**: the implementation home. Backtick-link to open the module doc.
- **Guide**: the guide that introduces the term in context (when one exists).

Aliases are spelled out where they are common. For example, `Spec` is shorthand
for [`Jidoka.Agent.Spec`](`Jidoka.Agent.Spec`); the row lives under `Agent.Spec`
with `Spec` listed as an alias.

## Glossary

| Term | Definition | Module | Guide |
| --- | --- | --- | --- |
| Action | Jidoka's thin wrapper over `Jido.Action`. An action is the canonical implementation of a tool: a module with a name, description, parameter schema, and `run/2` callback. Actions are turned into operations at compile time. | [`Jidoka.Action`](`Jidoka.Action`) | [Agent DSL](agent-dsl.md) |
| Agent | The author-facing concept of a Jidoka agent: a Spark DSL module that compiles to an immutable spec. An agent is not a process; it is a definition that can be planned, run, hosted, or imported. | [`Jidoka.Agent`](`Jidoka.Agent`) | [Agent DSL](agent-dsl.md) |
| Agent.Spec | Immutable definition data for one agent (id, model, instructions, generation, controls, operations, context schema, result schema, memory policy, metadata). DSL modules and JSON/YAML imports both compile to this struct. Alias: `Spec`. | [`Jidoka.Agent.Spec`](`Jidoka.Agent.Spec`) | [Agent DSL](agent-dsl.md) |
| AgentServer | The Jido process that hosts a Jidoka agent. Turns sent to a process arrive as `jidoka.turn.run` signals and are dispatched into the same harness as direct calls. | [`Jido.AgentServer`](`Jido.AgentServer`) | [Runtime And Harness](runtime-and-harness.md) |
| AgentSnapshot | Serializable semantic snapshot used for hibernate/resume. Contains the schema version, snapshot id, agent id, cursor, and turn state. Snapshots are pure data and safe to persist. Alias: `Snapshot`. | [`Jidoka.Runtime.AgentSnapshot`](`Jidoka.Runtime.AgentSnapshot`) | [Runtime And Harness](runtime-and-harness.md) |
| AgentView | Surface-neutral UI projection of an agent's status, last result, pending interrupts, and event tail. Used by LiveView, CLI, channels, and tests; never holds a pid or provider client. | [`Jidoka.AgentView`](`Jidoka.AgentView`) | [Runtime And Harness](runtime-and-harness.md) |
| Capability | A runtime function injected into the harness for a single turn. The bundle currently has two slots: `llm` and `operations`. Capabilities are what make turns either deterministic (fakes) or live (ReqLLM, Jido actions). | [`Jidoka.Runtime.Capabilities`](`Jidoka.Runtime.Capabilities`) | [Runtime And Harness](runtime-and-harness.md) |
| Checkpoint | The named phase boundary at which the runtime is allowed to hibernate. Configured per turn through the `checkpoint:` option; possible phases include `:after_prompt`, `:before_effect`, `:review`, and `:wait`. | [`Jidoka.Turn.Cursor`](`Jidoka.Turn.Cursor`) | [Runtime And Harness](runtime-and-harness.md) |
| Context | Caller-supplied per-turn map merged into the turn request. Validated against the spec's `context_schema` before the workflow runs. Context is data only; it never contains processes or clients. | [`Jidoka.Turn.Request`](`Jidoka.Turn.Request`) | [Agent DSL](agent-dsl.md) |
| Control | A policy module attached to a spec at one of three boundaries: input, operation, or output. Controls return `:allow`, `{:block, reason}`, or `{:interrupt, reason}` and run in the runtime shell. | [`Jidoka.Control`](`Jidoka.Control`) | [Controls](controls.md) |
| DSL | The Spark-based authoring surface used by `use Jidoka.Agent`. Provides the `agent`, `controls`, and `tools` sections plus compile-time verifiers. | [`Jidoka.Agent`](`Jidoka.Agent`) | [Agent DSL](agent-dsl.md) |
| Effect | The umbrella name for anything the runtime has to ask the outside world to do (currently `:llm` and `:operation`). Effects are described by intents and observed through results. | [`Jidoka.Effect.Intent`](`Jidoka.Effect.Intent`) | [Runtime And Harness](runtime-and-harness.md) |
| Effect.Intent | The durable data description of one external effect (kind, payload, idempotency key). Intents are written to the journal before any capability is called. | [`Jidoka.Effect.Intent`](`Jidoka.Effect.Intent`) | [Runtime And Harness](runtime-and-harness.md) |
| Effect.Journal | Intent/result map that makes the loop replayable. The interpreter records an intent before calling a capability and short-circuits any intent that already has a recorded result. | [`Jidoka.Effect.Journal`](`Jidoka.Effect.Journal`) | [Runtime And Harness](runtime-and-harness.md) |
| Effect.Result | Normalized result of an interpreted effect (status, output, metadata). One result is written per intent id. | [`Jidoka.Effect.Result`](`Jidoka.Effect.Result`) | [Runtime And Harness](runtime-and-harness.md) |
| Eval | A small deterministic eval runner that packages an agent, request, and assertions. It runs through `Jidoka.Harness` rather than introducing a parallel runtime. | [`Jidoka.Eval`](`Jidoka.Eval`) | [Runtime And Harness](runtime-and-harness.md) |
| Event | Neutral harness data emitted by turn transitions (turn started, prompt assembled, effect started, control allowed, approval requested, etc.). Events feed traces, streams, and `AgentView`. | [`Jidoka.Event`](`Jidoka.Event`) | [Runtime And Harness](runtime-and-harness.md) |
| Generation | Provider-neutral generation parameters on a spec (temperature, max_tokens, top_p, etc.). Defaults come from `Jidoka.Config.default_generation/0`. | [`Jidoka.Agent.Spec.Generation`](`Jidoka.Agent.Spec.Generation`) | [Agent DSL](agent-dsl.md) |
| Handoff | Durable routing data that records which agent should own future turns for a conversation. Different from a subagent call, which delegates one bounded task inside a turn. | [`Jidoka.Handoff`](`Jidoka.Handoff`) | [Runtime And Harness](runtime-and-harness.md) |
| Harness | The named execution boundary around the Jidoka kernel. Owns `run_turn/3`, `resume/2`, request normalization, capability normalization, memory wiring, and session/store integration. | [`Jidoka.Harness`](`Jidoka.Harness`) | [Runtime And Harness](runtime-and-harness.md) |
| Hibernate | The act of pausing a turn at a checkpoint and emitting an `AgentSnapshot` instead of a `Turn.Result`. Used for human review pauses and externally driven resumes. | [`Jidoka.Runtime.AgentSnapshot`](`Jidoka.Runtime.AgentSnapshot`) | [Runtime And Harness](runtime-and-harness.md) |
| Idempotency | Per-operation policy that tells the runtime how to treat repeated effects. Valid values: `:pure`, `:idempotent`, `:dedupe`, `:reconcile`, `:unsafe_once`. `:unsafe_once` requires approval or a matching operation control. | [`Jidoka.Agent.Spec.Operation`](`Jidoka.Agent.Spec.Operation`) | [Controls](controls.md) |
| Import | The runtime that parses JSON/YAML into an `Agent.Spec`. Imports never call `String.to_atom/1` on input; module and schema refs are resolved through caller-provided registries. | [`Jidoka.Import`](`Jidoka.Import`) | [Agent DSL](agent-dsl.md) |
| Inspection | Internal module that powers `Jidoka.inspect/1` and `Jidoka.preflight/3`. Returns stable, human-readable projections of agents, plans, turns, and snapshots. | [`Jidoka.Inspection`](`Jidoka.Inspection`) | [Getting Started](getting-started.md) |
| Instructions | The system-prompt-shaped string attached to a spec. Skills and memory contributions can extend instructions at runtime; the stored value is still data. | [`Jidoka.Agent.Spec`](`Jidoka.Agent.Spec`) | [Agent DSL](agent-dsl.md) |
| Jido | The underlying process/agent framework that owns supervision, registries, signals, and action runtime. Jidoka treats Jido as a hosting and tool runtime; it does not embed Jido logic in the turn spine. | [`Jido`](`Jido`) | [Runtime And Harness](runtime-and-harness.md) |
| Jidoka | The package itself: a data-first agent harness that compiles authored agents to a `Spec`, plans them into a `Turn.Plan`, and runs them through a thin harness. | [`Jidoka`](`Jidoka`) | [Getting Started](getting-started.md) |
| LLM | The language-model capability slot. The runtime treats the model as an effect; an LLM capability is a 2-arity function over `(intent, journal)` returning a typed decision. | [`Jidoka.Runtime.Capabilities`](`Jidoka.Runtime.Capabilities`) | [Live LLM Tool Loop](live-llm-tool-loop.md) |
| LLMDecision | Typed decision returned by an LLM effect. Either `:final` (with content and optional structured result), `:operation` (one operation call), or `:operations` (an ordered batch of operation calls). | [`Jidoka.Effect.LLMDecision`](`Jidoka.Effect.LLMDecision`) | [Live LLM Tool Loop](live-llm-tool-loop.md) |
| MCP | Operation source for tools exposed by a Model Context Protocol server. Compiles MCP tool descriptors into `Agent.Spec.Operation` data plus an operation capability that invokes the MCP transport. | [`Jidoka.Operation.Source`](`Jidoka.Operation.Source`) | [Agent DSL](agent-dsl.md) |
| Memory | Visible agent memory: entries recalled into prompts or context, optionally captured from completed turns. The spec stores policy; runtime stores live behind the `Memory.Store` behaviour. | [`Jidoka.Memory`](`Jidoka.Memory`) | [Runtime And Harness](runtime-and-harness.md) |
| Memory.Store | Behaviour for pluggable memory backends. A store implements `recall/2`, `write/2`, and `list_entries/1`. The store is supplied per run, not baked into the spec. | [`Jidoka.Memory.Store`](`Jidoka.Memory.Store`) | [Runtime And Harness](runtime-and-harness.md) |
| Operation | A model-callable unit (name, description, idempotency, metadata, optional parameters schema). Operations are how tools, MCP, browser, workflows, and subagents reach the model in a single shape. | [`Jidoka.Agent.Spec.Operation`](`Jidoka.Agent.Spec.Operation`) | [Agent DSL](agent-dsl.md) |
| Operation.Source | Behaviour and compiler that normalize executable surfaces (actions, MCP, browser, workflows) into operation data plus one operation capability. | [`Jidoka.Operation.Source`](`Jidoka.Operation.Source`) | [Agent DSL](agent-dsl.md) |
| Output | A control boundary that runs against the model's final assistant content before it leaves the harness. Used for safety filters, redaction, and post-validation. | [`Jidoka.Agent.Spec.Controls.Output`](`Jidoka.Agent.Spec.Controls.Output`) | [Controls](controls.md) |
| Plan | Shorthand for `Turn.Plan`. The compiled, executable contract derived from a spec. | [`Jidoka.Turn.Plan`](`Jidoka.Turn.Plan`) | [Runtime And Harness](runtime-and-harness.md) |
| Preflight | `Jidoka.preflight/3`. Assembles the prompt, tool metadata, memory contributions, and request normalization without calling an LLM. The cheapest way to validate wiring. | [`Jidoka.Inspection`](`Jidoka.Inspection`) | [Getting Started](getting-started.md) |
| Projection | Stable inspection map produced by `Jidoka.project/1`. Projections omit Zoi schemas, LLMDB structs, and Spark metadata while keeping the semantic shape useful for traces, golden tests, and UI rendering. | [`Jidoka.Projection`](`Jidoka.Projection`) | [Runtime And Harness](runtime-and-harness.md) |
| Request | Shorthand for `Turn.Request`. Input for one agent turn: input string, request id, agent state, context, and metadata. | [`Jidoka.Turn.Request`](`Jidoka.Turn.Request`) | [Getting Started](getting-started.md) |
| Result | Shorthand for `Turn.Result`. The value `turn/3` returns on success: content, optional structured `value`, agent state, journal, and events. | [`Jidoka.Turn.Result`](`Jidoka.Turn.Result`) | [Structured Results](structured-results.md) |
| Resume | The act of continuing from an `AgentSnapshot`. The same harness runs as a fresh turn; callers supply the same capabilities plus any required approval response. | [`Jidoka.Harness`](`Jidoka.Harness`) | [Runtime And Harness](runtime-and-harness.md) |
| ReqLLM | The third-party provider client used to make live model calls. Jidoka wraps ReqLLM behind a small adapter that emits typed `LLMDecision` values. | [`Jidoka.Runtime.ReqLLM`](`Jidoka.Runtime.ReqLLM`) | [Live LLM Tool Loop](live-llm-tool-loop.md) |
| Review | The collection of structs and runtime helpers that model human-in-the-loop pauses (`Review.Request`, `Review.Response`, `Review.Interrupt`). | [`Jidoka.Review`](`Jidoka.Review`) | [Controls](controls.md) |
| Runic | The pure workflow engine that owns the turn spine. Jidoka compiles its phases into a Runic workflow so transitions stay deterministic and inspectable. | [`Runic.Workflow`](`Runic.Workflow`) | [Runtime And Harness](runtime-and-harness.md) |
| Runtime | The shell modules under `Jidoka.Runtime.*` that implement capabilities, controls, signals, and the turn runner. Effectful by design, kept around the pure core. | [`Jidoka.Runtime.TurnRunner`](`Jidoka.Runtime.TurnRunner`) | [Runtime And Harness](runtime-and-harness.md) |
| Session | The ergonomic facade for durable multi-turn state. Delegates to `Jidoka.Harness.Session` for the underlying data shape. | [`Jidoka.Session`](`Jidoka.Session`) | [Runtime And Harness](runtime-and-harness.md) |
| Skill | A Jido.AI skill referenced by an agent. Skills contribute prompt instructions and any actions published by the skill manifest; those actions are executed through the standard Jido action operation path. | [`Jidoka.Skill`](`Jidoka.Skill`) | [Agent DSL](agent-dsl.md) |
| Snapshot | See `AgentSnapshot`. | [`Jidoka.Runtime.AgentSnapshot`](`Jidoka.Runtime.AgentSnapshot`) | [Runtime And Harness](runtime-and-harness.md) |
| Source | See `Operation.Source`. | [`Jidoka.Operation.Source`](`Jidoka.Operation.Source`) | [Agent DSL](agent-dsl.md) |
| Spark | The DSL framework used to build the Jidoka agent DSL. Provides sections, entities, verifiers, formatter support, and source-aware errors. | [`Spark.Dsl.Extension`](`Spark.Dsl.Extension`) | [Agent DSL](agent-dsl.md) |
| Spec | See `Agent.Spec`. | [`Jidoka.Agent.Spec`](`Jidoka.Agent.Spec`) | [Agent DSL](agent-dsl.md) |
| Store | See `Memory.Store` or `Jidoka.Harness.Store` depending on context: harness stores persist sessions and snapshots, memory stores persist memory entries. | [`Jidoka.Harness.Store`](`Jidoka.Harness.Store`) | [Runtime And Harness](runtime-and-harness.md) |
| Stream | Request-scoped helper for observing `Jidoka.Event` values as a turn runs. Callers opt in with `stream_to: pid` or `on_event: fun`. | [`Jidoka.Stream`](`Jidoka.Stream`) | [Runtime And Harness](runtime-and-harness.md) |
| Subagent | A bounded delegation to another agent for one task inside the current turn. Different from a handoff, which permanently changes conversation ownership. | [`Jidoka.Agent.Spec.Operation`](`Jidoka.Agent.Spec.Operation`) | [Agent DSL](agent-dsl.md) |
| Tool | The author-facing name for a model-callable capability. In Jidoka, tools are normally `Jidoka.Action` modules and compile to `Operation` data. | [`Jidoka.Action`](`Jidoka.Action`) | [Agent DSL](agent-dsl.md) |
| Trace | Projection helpers that turn events into a compact, sequence-stable timeline. Useful for debugging and golden tests. | [`Jidoka.Trace`](`Jidoka.Trace`) | [Runtime And Harness](runtime-and-harness.md) |
| Turn | One model/tool cycle: assemble prompt, plan model effect, apply model result, plan operation effects, apply operation results. The harness runs one turn per `turn/3` call. | [`Jidoka.Turn.Plan`](`Jidoka.Turn.Plan`) | [Getting Started](getting-started.md) |
| Turn.Plan | The executable plan compiled from a spec. Holds the spec, workflow profile, `max_model_turns`, timeout, and phase list. Still pure data. | [`Jidoka.Turn.Plan`](`Jidoka.Turn.Plan`) | [Runtime And Harness](runtime-and-harness.md) |
| Turn.Result | The final app-facing result of one turn: content, optional structured `value`, agent state, journal, and events. | [`Jidoka.Turn.Result`](`Jidoka.Turn.Result`) | [Structured Results](structured-results.md) |
| Turn.State | The ephemeral, in-flight data value the workflow threads through each phase. Hibernation snapshots the state at a checkpoint; resume rebuilds the runner from that snapshot. | [`Jidoka.Turn.State`](`Jidoka.Turn.State`) | [Runtime And Harness](runtime-and-harness.md) |
| Unsafe Once | Idempotency level for operations whose effects must not be replayed. Spec validation requires approval or a matching operation control before such an operation can ship in a plan. | [`Jidoka.Agent.Spec.Operation`](`Jidoka.Agent.Spec.Operation`) | [Controls](controls.md) |
| Workflow | An application-owned deterministic process exposed to an agent as a single model-callable operation. Callback workflows implement `run/2`; DSL workflows declare `workflow do`, `steps do`, and `output` and compile to `Jidoka.Workflow.Spec`. | [`Jidoka.Workflow`](`Jidoka.Workflow`) | [Workflows](workflows.md) |

## Common Patterns

- **Look up before you read.** When another guide uses a term you have not
  seen, find the row here first; the linked module doc is usually one line of
  context away.
- **Prefer canonical names.** Use `Agent.Spec` instead of `Spec` in code
  comments and PR descriptions so search across the codebase stays reliable.
- **Keep aliases stable.** `Snapshot`, `Spec`, `Plan`, `Request`, and `Result`
  are the common short forms; everything else should use the full name.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| A term in a doctring is not in this table. | The term is application-level vocabulary, not Jidoka vocabulary. | Confirm by searching `lib/jidoka` for the term. If it is internal Jidoka vocabulary, add a row here. |
| A linked module raises `function not found`. | The module was renamed or moved. | Run `mix compile` and search `lib/` for the new home, then update the row. |
| Two guides use the term differently. | One guide is stale. | Pick the meaning that matches the current module doc and open an issue against the stale guide. |

## Reference

Top-level modules referenced throughout this glossary:

- [`Jidoka`](`Jidoka`) - the public facade.
- [`Jidoka.Agent`](`Jidoka.Agent`) and [`Jidoka.Agent.Spec`](`Jidoka.Agent.Spec`) - authoring and spec data.
- [`Jidoka.Turn.Plan`](`Jidoka.Turn.Plan`), [`Jidoka.Turn.Request`](`Jidoka.Turn.Request`), [`Jidoka.Turn.Result`](`Jidoka.Turn.Result`), [`Jidoka.Turn.State`](`Jidoka.Turn.State`) - turn data contracts.
- [`Jidoka.Effect.Intent`](`Jidoka.Effect.Intent`), [`Jidoka.Effect.Journal`](`Jidoka.Effect.Journal`), [`Jidoka.Effect.Result`](`Jidoka.Effect.Result`), [`Jidoka.Effect.LLMDecision`](`Jidoka.Effect.LLMDecision`) - effect boundary.
- [`Jidoka.Harness`](`Jidoka.Harness`), [`Jidoka.Runtime.TurnRunner`](`Jidoka.Runtime.TurnRunner`), [`Jidoka.Runtime.Capabilities`](`Jidoka.Runtime.Capabilities`) - execution shell.
- [`Jidoka.Runtime.AgentSnapshot`](`Jidoka.Runtime.AgentSnapshot`), [`Jidoka.Review`](`Jidoka.Review`) - hibernation and review.

## Related Guides

- [Getting Started](getting-started.md) - the smallest end-to-end Jidoka flow.
- [Agent DSL](agent-dsl.md) - full DSL surface, imports, and operation sources.
- [Workflows](workflows.md) - deterministic workflow modules exposed as tools.
- [Controls](controls.md) - input/operation/output policy and approvals.
- [Structured Results](structured-results.md) - typed `Turn.Result.value`.
- [Runtime And Harness](runtime-and-harness.md) - sessions, snapshots, effects, memory.
- [Live LLM Tool Loop](live-llm-tool-loop.md) - running against a real provider.
- [Troubleshooting](troubleshooting.md) - common errors and diagnostic order.
