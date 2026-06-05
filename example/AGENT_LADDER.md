# Agent Ladder

The example app should teach Jidoka by adding one meaningful capability at a
time. The current V2 app is intentionally narrow: only the examples that match
today's stable package surface should be runnable.

This document is also the parity map back to the larger Jidoka V1 example set.
When an example needs a Jidoka feature that is not complete yet, keep it here as
a gap instead of adding a half-supported route to the Phoenix app.

## Principles

- Keep runnable examples honest about the package surface that exists now.
- Prefer use cases over feature demos, but make the feature being taught clear.
- Add one capability at a time so a new developer can copy the example.
- Treat missing examples as product gaps, not Phoenix app work.
- Only promote a roadmap example into the app after its Jidoka API is stable.

## Current Runnable V2 Examples

### 1. Support Agent

Status: implemented.

Shows a supervised Jidoka agent with one local `Jidoka.Action`, a durable
session id, a reset button, activity projection, source view, and basic controls.
This covers the old `first_agent` slot, so there is no separate no-tool route.

Primary features:

- `agent do`
- string `instructions`
- `generation`
- `controls do max_turns ... timeout ... end`
- `tools do action ... end`
- supervised Jido process
- LiveView AgentView projection

### 2. Research Agent

Status: implemented.

Adds browser-backed tools, a stronger evidence loop, structured brief output,
and an output control that requires at least one cited source. The agent
searches, reads public pages, then answers with links and a validated
app-facing result.

Primary features:

- `tools do browser :public_web, mode: :read_only end`
- `search_web`
- `read_page` for accessible non-GitHub pages
- `result schema: ...`
- `controls do output ... end`
- tighter run controls for multi-tool turns
- missing-credential handling for `BRAVE_SEARCH_API_KEY`

### 3. Approval Flow Agent

Status: implemented.

Adds human-in-the-loop review before a sensitive side effect. The agent plans a
refund operation, Jidoka hibernates the turn with a pending review snapshot, and
the UI can approve or reject the operation before resume.

Primary features:

- `controls do operation ..., when: ... end`
- `Jidoka.Review.Response`
- hibernate/resume flow
- pending review projection
- review UI for approving or rejecting a planned tool call

### 4. Ash Agent

Status: implemented.

Adds Ash resource-backed tools. The example defines a tiny Ash domain/resource,
uses AshJido to generate Jido actions, and exposes those generated actions
through Jidoka's `tools do ash_resource ... end` DSL.

Primary features:

- `tools do ash_resource ... end`
- AshJido generated Jido actions
- operation context for runtime-only values such as an Ash domain module
- supervised Jido process execution
- source inspection across the Jidoka agent, Ash domain, and Ash resource

### 5. Lead Quality Agent

Status: implemented.

Adds a local multi-tool business flow. The agent enriches a lead, scores the
enriched lead, then returns a structured qualification result that the UI renders
directly.

Primary features:

- multiple `tools do action ... end` entries
- ordered tool sequencing
- `result schema: ...`
- structured app-facing result rendering
- multi-step activity projection

### 6. Memory Agent

Status: implemented.

Adds session-scoped Jidoka memory backed by `jido_memory`. The agent writes a
preference through a tool, then later turns recall memory before prompt assembly.

Primary features:

- `memory %{scope: :session, max_entries: ...}`
- `Jidoka.Memory.Store.JidoMemory`
- `jido_memory` ETS-backed provider runtime
- runtime-only operation context for the memory store
- visible session memory panel

### 7. Knowledge Agent

Status: implemented.

Adds a focused knowledge route for skills plus MCP tools. The agent uses local
skill instructions and a skill action for package knowledge, calls a small MCP
tool for externalized notes, and can add browser evidence when the question
needs live outside context.

Primary features:

- `tools do skill ... end`
- skill-contributed action modules
- `tools do mcp_tools ... end`
- MCP operation source with a local example client
- optional `tools do browser ... end`
- output control requiring cited tool evidence

### 8. Debug Agent

Status: implemented.

Adds a developer-facing route around the inspection APIs. The agent can call
tools that wrap `Jidoka.inspect/1` and `Jidoka.preflight/3`, while the route
also renders a static inspect/preflight preview before any live LLM turn runs.

Primary features:

- `Jidoka.inspect/1` for compiled agent structure
- `Jidoka.preflight/3` for prompt and operation preview without effects
- local debug actions over a fixed target registry
- source inspection for the package inspection modules
- developer-oriented route that does not require external tools to be useful

### 9. Kitchen Sink Agent

Status: implemented.

Combines the stable V2 surface into one route for integration stress testing
and developer inspection. This is not the recommended first example; it exists
so a developer can see how the current pieces compose inside one supervised
agent.

Primary features:

- `context Zoi.object(...)`
- multiple `tools do action ... end` entries
- `tools do ash_resource ... end`
- `tools do browser ... end`
- `tools do skill ... end`
- `tools do mcp_tools ... end`
- `tools do subagent ... end`
- `tools do handoff ... end`
- `tools do workflow ... end`
- `memory %{scope: :session, max_entries: ...}`
- `controls do input ... operation ... output ... end`
- controls as the replacement for V1 lifecycle hooks
- hibernate/resume review for sensitive operations
- `result schema: ...`
- streaming and activity projection
- source inspection across example app and package code

The V2 Kitchen Sink intentionally does not demonstrate dynamic system prompts
or plugins. Instructions remain a plain string, and extension/capability
composition should move through explicit Jidoka extension points or operation
sources instead of a plugin DSL.

## V1 Example Parity Map

| V1 Example | Intended Use Case | V2 Status | Gap To Close Before Rebuilding |
| --- | --- | --- | --- |
| `first_agent` | Smallest possible chat agent | Covered by Support Agent | Keep as docs/API material unless a no-tool route becomes useful for onboarding. |
| `ticket_classifier` / `structured_output` | Typed result, validation, repair | Core exists; example removed from app | Stabilize result-schema prompting, repair telemetry, and a compact structured-result UI. |
| `support_agent` / `support_triage` | Ticket lookup, routing, support policy | Partially covered by Support Agent | Add richer ticket fixtures, input controls, routing outputs, and reusable support guard controls. |
| `approval_flow` | Human-in-the-loop approval before side effects | Implemented as Approval Flow Agent | Durable review storage and audit-log persistence remain core package gaps, but the runnable flow is present. |
| `research_brief` | Source-backed research brief | Covered by expanded Research Agent | Source ranking is still simple; stronger browser failure handling remains useful. |
| `knowledge_agent` | Skills, MCP tools, web lookup | Implemented | Future versions can connect to real MCP servers and richer knowledge stores. Do not revive V1 plugins as a first-class DSL concept. |
| `ash_agent` | Ash resource expansion into tools | Implemented | Larger Ash examples can add auth, policy, tenancy, and relationships later. |
| `data_analyst` | Multi-tool analysis over local data | Deferred | Add a stable multi-tool synthesis pattern and decide whether parallel split/reduce/accumulate belongs in Jidoka. |
| `lead_qualification` | Enrich, score, and qualify a lead | Implemented | Future versions can add richer fixtures, routing controls, and CRM write-back. |
| `meeting_followup` | Extract action items from notes with safe commitments | Deferred | Needs document/text ingestion and output controls for unsupported commitments. |
| `feedback_synthesizer` | Batch feedback loading and theme grouping | Deferred | Needs collection-oriented inputs, reducer-style tool behavior, and structured synthesis outputs. |
| `invoice_extraction` | Document loading and strict extraction | Deferred | Needs file/document tool surfaces, upload path in the app, and stricter schema repair loops. |
| `document_intake` | Load and route documents | Deferred | Same document/file ingestion gap plus routing result controls. |
| `incident_triage` | Alert classification plus workflow investigation | Deferred | Needs workflow-facing API decisions, escalation controls, and richer durable state. |
| `workflow_agent` / `workflow` | Deterministic workflow tool and schedules | Partially covered by Kitchen Sink | Workflow-as-tool exists; defer a standalone route until public workflow API and scheduling semantics are clearer. |
| `delegation_agent` / `orchestrator` | Subagents, handoffs, imported agent specs | Partially covered by Kitchen Sink | Subagents and handoffs exist; defer a standalone route until ownership semantics and imported-spec parity are stronger. |
| `pr_reviewer` | Load diff, detect findings, enforce review quality | Deferred | Needs repository/diff tools, structured finding output, and review-specific output controls. |
| `debug_agent` / `trace` | Request inspection and trace inspection | Implemented as Debug Agent | Trace UX can still get richer, but inspect/preflight are now represented in the app. |
| `chat` | General chat plus hooks/guardrails/plugins | Do not port directly | Hooks are now controls/events; plugins are not a V2 DSL goal. Split remaining surfaces into focused examples. |
| `kitchen_sink` | Everything at once | Implemented against stable V2 features | Needs stricter evidence validation so it cannot claim a feature ran unless operation results prove it. |

## Recommended Parity Order

1. Harden Kitchen Sink evidence validation so structured output must match observed operation results.
2. Expanded memory: add declarative capture/retrieve/inject policy beyond the current session recall/write path.
3. Delegation: rebuild `delegation_agent` after subagents, handoffs, and imported-agent parity are designed.
4. Workflow and scheduling: rebuild `workflow_agent` only after the public workflow stance is settled.
5. Multi-tool local analysis: rebuild `data_analyst` after collection-oriented inputs are clearer.
6. Document ingestion: rebuild `document_intake`, then `invoice_extraction`.
7. PR review: keep this for later regression coverage after repository/diff tools exist.

## Current Focus

The V2 example app now proves the current spine across nine use cases: DSL agent
definition, agent context, Jido supervision, local actions, browser tools, Ash
resource tools, skills, MCP tools, structured results, controls,
hibernate/resume review, session memory, inspect/preflight, streaming, activity
projection, and source inspection.

The next examples should be pulled from the parity order only after the
underlying Jidoka feature is stable enough to teach without caveats. The next
gap is not a new route; it is making Kitchen Sink proof semantics stricter.
