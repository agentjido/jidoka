# Jidoka Feature Map

This is a planning document for ordering Jidoka's README, guides, Livebooks,
and examples during the DSL V2 refactor.

## Feature Inventory

After "Your First Agent," Jidoka's feature surface breaks down into these
groups:

- **Core turn model:** chat turns, sessions, streaming.
- **Agent contract:** model, instructions, context, result.
- **Runtime inputs:** context maps, context schemas, characters.
- **Operation surface:** actions, Ash actions, web tools, MCP tools,
  skills, plugins, catalogs.
- **Runtime controls:** input controls, operation controls, result controls,
  interrupts, approvals.
- **Human-in-the-loop:** approval and interruption flows expressed through
  controls rather than a separate policy system.
- **Credential brokering:** authenticated tool calls carry credential
  references while a broker, proxy, sidecar, or connect layer injects the real
  credential after the LLM/tool-planning boundary, so raw secrets stay out of
  prompts, transcripts, tool arguments, traces, and model logs.
- **State helpers:** memory, compaction, and a clear durability graduation path.
- **Orchestration:** workflows, bounded subagent delegation, and conversation
  handoffs.
- **Runtime integration:** shared runtime, app-owned runtime, UI projections
  through `AgentView`, and Phoenix integration.
- **Operations:** structured errors, first-class debugging, local inspection,
  tracing, observability standards, and Kino/Livebook views.
- **Portability:** imported JSON/YAML agents.
- **Automation:** schedules.
- **Testing:** provider-free tests, action tests, result tests, workflow tests,
  live evals.

## Vocabulary

Jidoka should keep state-like words narrow:

- **Context** is caller-provided runtime data for a turn. It may be a naked map
  or a Zoi-validated contract. It is how the host app supplies actor, tenant,
  account, ticket, credential references, and other request-scoped facts.
- **Agent state** is internal process state owned by the running runtime agent.
  It tracks requests, strategy state, latest compaction snapshots, and other
  implementation details. Users should not reach for agent state just to pass
  app data into a turn.
- **Memory** recalls facts across turns or from an external store. It is not a
  replacement for required context; if a tool needs `account_id`, the caller
  should pass it explicitly.
- **Memory configuration** belongs to the agent contract in the V3 DSL because
  it describes how that agent keeps continuity. The public turn surface should
  not grow separate `remember`/`recall` helpers; manual memory writes and
  searches belong to the configured memory store or lower-level runtime, while
  Jidoka exposes memory through agent metadata, request inspection, and traces.
- **Memory execution** has two separate phases. Retrieval runs before the model
  turn and can inject recalled records as prompt instructions or as runtime
  context; a retrieval failure fails the request because the agent was
  configured to depend on that memory. Capture runs after a completed turn and
  records user/assistant turn facts; capture failures are surfaced in request
  metadata and traces without changing the already completed result. Namespace
  modes are `:per_agent`, `{:shared, name}`, and `{:context, key}`.
- **Compaction** reduces the provider-facing transcript window by summarizing
  older conversation context. It does not delete the original thread and should
  not be taught as memory.
- **Compaction configuration** is agent-owned runtime behavior. V3 keeps the
  strategy narrow: `:auto` compacts before a long turn crosses the message
  threshold, `:manual` compacts only through `Jidoka.compact/2`, and `:off`
  disables the feature. The public manual surface is intentionally read/write
  small: `Jidoka.compact/2` creates a new summary snapshot and
  `Jidoka.inspect_compaction/2` reads the latest snapshot. Request
  transformation uses that snapshot to trim the provider-facing window while
  preserving the canonical thread.
- **Result** is the app-facing final value from a turn. Typed results validate
  that value before callers receive it.
- Public DSL/docs should say **result**. Internal modules may retain `Output`
  where they bridge raw model/provider output into that app-facing result.
- **Subagent** means bounded delegation: the parent agent asks a specialist
  agent to handle one task and receives a result back in the same turn. Future
  turns still belong to the parent conversation owner.
- **Handoff** means conversation ownership transfer: the current agent routes
  future turns for a conversation to another agent until the handoff is reset.
  It is not just a longer subagent call.

## Operation Boundary

Jidoka should not support inline action or workflow definitions inside the
agent DSL for V3. Agents reference named action modules and named workflow
modules. Workflow modules may define their own ordered steps, but the agent
contract should stay focused on which operations are available, not on embedding
their implementation.

## Topic DAG

```mermaid
graph TD
    A["Your First Agent"] --> B["Chat Turns"]
    A --> C["Sessions"]

    B --> D["Typed Results"]
    B --> E["Streaming"]
    C --> F["Runtime Context"]

    F --> G["Context Schema"]
    F --> H["Characters"]
    F --> I["Memory"]
    I --> J["Compaction"]

    D --> K["Result Controls"]
    G --> L["Input Controls"]

    B --> M["Actions"]
    F --> M
    M --> N["Operation Controls"]
    K --> HI["Human In The Loop"]
    L --> HI
    N --> HI
    N --> AH["Credential Brokering"]
    HI --> AH
    C --> AH
    M --> O["Ash Actions"]
    M --> P["Web Tools"]
    M --> Q["MCP Tools"]
    M --> R["Skills"]
    M --> S["Plugins"]
    M --> T["Catalogs / Connect"]
    T --> AH
    AH --> P
    AH --> Q

    M --> U["Workflows"]
    U --> V["Workflow As Agent Tool"]

    M --> W["Subagents (bounded delegation)"]
    C --> W
    W --> X["Handoffs (ownership transfer)"]
    C --> X

    C --> Y["Schedules"]
    U --> Y
    C --> AJ["Durability / Runtime Storage"]

    B --> Z["Debugging"]
    Z --> AA["Inspection"]
    M --> AA
    AA --> AB["Tracing"]
    AB --> AO["Observability Standards"]
    AO --> AP["GenAI / OTLP Backends"]
    AB --> AC["Kino / Livebook Debugging"]

    C --> AD["UI Projection (AgentView)"]
    E --> AD
    AD --> AE["Phoenix / UI Integration"]

    A --> AF["Imported Agents"]
    M --> AF
    W --> AF
    U --> AF

    D --> AG["Testing Agents"]
    M --> AG
    U --> AG
    N --> AG
```

## Teaching Order

1. **Your First Agent:** define an agent and run `Jidoka.chat/2`.
2. **Sessions:** identity, multi-turn context, pipe syntax.
3. **Context:** pass runtime facts safely.
4. **Typed Results:** make replies useful to application code.
5. **Actions:** let the agent do deterministic work.
6. **Controls:** input, operation, result boundaries.
7. **Human-in-the-Loop:** pause risky inputs, operations, or results for review.
8. **Credential Brokering:** authenticated tools use credential references
   without exposing raw secrets to the model.
9. **Debugging:** inspect prompts, requests, runtime state, and traces locally.
10. **Observability Standards:** connect structured telemetry to OpenTelemetry
    GenAI-compatible backends.
11. **Memory:** recall useful prior facts.
12. **Compaction:** keep long sessions usable.
13. **Streaming + UI Projection:** build UI-facing agents with `AgentView`.
14. **Schedules:** run agents without a user prompt.
15. **Workflows:** deterministic multi-step processes.
16. **Subagents + Handoffs:** bounded specialist delegation, then conversation
    ownership transfer.
17. **Tool Integrations:** Ash, web, MCP, skills, plugins, catalogs.
18. **Imported Agents:** portable specs and registries.
19. **Durability + Graduation:** move from Jidoka session addressing to durable
    runtime storage, hibernate/thaw, checkpoints, and thread journals.
20. **Testing:** contract, action, result, workflow, and live checks.

## Canonical Table Of Contents

Use this sequence for the README feature map, guides, Livebooks, and example
sets:

1. Agents
2. Chat turns
3. Sessions
4. Context
5. Typed results
6. Actions
7. Controls
8. Human-in-the-loop
9. Credential brokering
10. Debugging
11. Observability standards
12. Memory and compaction
13. Streaming and UI projections
14. Schedules
15. Workflows
16. Subagents and handoffs
17. Tool integrations
18. Imported agents
19. Durability and graduation
20. Testing

## README Shape

The README should cover:

1. What Jidoka is.
2. Your first agent.
3. Session-aware chat.
4. One medium example that combines context, one action, and one control.
5. A concise feature list.
6. Runtime model and install notes.
7. Debugging and observability as a development-to-production bridge.
8. Durability and graduation into the full runtime.

Avoid a kitchen-sink agent in the README. Save that for advanced guides or
Livebooks.

## Credential Brokering Notes

Credential brokering should be treated as a security and integration topic, not
as a general prompt feature.

The model should know that an authenticated operation exists and may know a
credential reference, vault id, connection id, or provider name. It should not
receive the raw credential value. At execution time, a broker, proxy, sidecar,
or integration runtime attaches the real credential to the outbound request.

V3 contract:

- Jidoka owns the credential reference data model via `%Jidoka.Credential{}`.
- Jidoka accepts credential references in session context, runtime context, and
  tool arguments.
- Jidoka rejects raw secret-looking keys such as `api_key`, `token`, `password`,
  and `client_secret` before prompts or tool calls.
- Controls can match credential metadata such as provider, tenant, scope, risk,
  and confirmation requirement.
- Traces and inspection surfaces record sanitized credential metadata, not
  credential values.
- The host app or integration layer owns vault lookup, OAuth refresh, tenant
  routing, request signing, and outbound credential injection.

Execution shape:

1. The caller places a credential reference in session context or tool
   arguments.
2. The agent plans an authenticated operation using only reference metadata.
3. Operation controls allow, block, or interrupt based on the operation and
   credential metadata.
4. The broker/proxy/connect layer resolves the reference inside the application
   boundary and signs or authorizes the outbound request.
5. Jidoka receives the operation result and traces sanitized credential usage.

This matters most for:

- web/API tools that call third-party services
- MCP servers that require bearer tokens or OAuth
- catalog-backed integrations such as `jido_connect`
- user-scoped sessions where the selected credential depends on tenant, actor,
  account, or conversation context
- audit trails where the app needs to know which credential lease was used
  without exposing the secret

Deferred design questions:

- Whether a future DSL should add a dedicated `credentials do ... end` block or
  keep credential references entirely in context and tool metadata.
- Whether catalog/connect integrations should standardize additional reference
  fields beyond provider, account, actor, tenant, scopes, lease, risk, and audit
  metadata.
- Whether the application broker contract should be formalized as a Jido shared
  behavior once more integrations exist.

External references:

- [Credential Brokering for AI Agents, Explained](https://infisical.com/blog/credential-brokering-for-ai-agents)
- [21st Credential Vaults](https://21st.dev/community/blog/credential-vaults)
- [Microsoft Entra Agent ID sidecar local development](https://learn.microsoft.com/en-us/entra/agent-id/sidecar-local-development)

## Tool Integration Audit

The V3 integration surface should stay boring: every integration either
expands into named action-backed operations, contributes prompt/runtime metadata
for those operations, or remains outside core Jidoka behind an explicit
extension boundary.

| Integration | Current Jidoka boundary | Safety and test posture | V3 decision |
| --- | --- | --- | --- |
| Direct actions | `tools do action MyAction end` registers deterministic `Jidoka.Action` or compatible action modules. | Compile-time schema/name validation and duplicate operation-name checks; provider-free action and inspection tests exist. | Core. This is the base operation contract all other integrations should reduce to. |
| Ash resources | `ash_resource MyResource` expands AshJido-generated resource actions into normal operation modules. | Requires valid Ash resources, generated actions, one Ash domain, and actor context when needed; provider-free Ash expansion and context tests exist. | Core adapter, but keep it thin. Rich Ash policy/data behavior belongs to Ash and AshJido. |
| Web tools | `web :search` and `web :read_only` expose a small read-only subset of browser-backed tools. | Blocks local/private URLs including DNS-resolved private hosts, clamps result sizes, truncates content, and rejects unsupported modes; provider-free URL/sizing/conflict tests exist. | Core, intentionally narrow. Interactive browsing, sessions, clicks, typing, and JS execution stay out of the Jidoka DSL. |
| MCP tools | `mcp_tools endpoint: ...` syncs MCP server tools into a running agent before a turn. | Runtime endpoint registration is idempotent, conflict-aware, and failure-normalized; sync metadata and failures are observable without crashing the turn. | Core protocol bridge. Server lifecycle, auth, and remote tool implementation stay with the host app or MCP layer. |
| Skills | `skill MySkill`, `skill "name"`, and `load_path "..."` add skill prompt text and narrow allowed tools. | Module skills are compile-time validated; runtime skills can be loaded from app-owned paths and can restrict `allowed_tools`; provider-free request-transformer tests exist. | Core, but load paths are an app boundary. Jidoka should not fetch arbitrary remote skill bundles. |
| Plugins | `plugin MyPlugin` merges plugin-provided action-backed operations into the same tool registry. | Plugin names, required callbacks, tool modules, and duplicate operation names are validated; provider-free plugin tests exist. | Core extension point for small Jidoka-shaped bundles. Large service integrations should graduate to companion packages. |
| Catalog / connect layer | No first-class core implementation yet; current docs describe the desired scalable discovery boundary. | Credential references and controls already provide the security vocabulary, but catalog search/ranking/execution is not in core. | Companion-package boundary for now. Jidoka should define the agent-facing contract later, not load hundreds of tools into every prompt. |

Audit conclusion for E14: direct actions, Ash, web, MCP, skills, and plugins all
fit the same mental model today. Catalog/connect is the one intentionally
deferred surface: it should become a metadata-rich discovery and execution
contract, likely backed by companion packages such as service integration
libraries, rather than a large built-in registry inside Jidoka.

### Integration Buckets

Use these buckets when deciding whether a tool integration belongs in Jidoka:

| Bucket | Definition | Current contents | Rule |
| --- | --- | --- | --- |
| Core | Small, safe-by-default adapters that compile or sync into normal named operations and can be tested without live services. | Direct actions, AshJido resource actions, read-only web tools, MCP sync bridge, skill prompt/tool narrowing, plugin wrapper, credential references. | Keep in Jidoka when the behavior is generic, narrow, and mostly dependency-light. |
| Extension | App-owned or library-owned modules that use Jidoka contracts but are not baked into the base DSL. | Local `Jidoka.Action` modules, local `Jidoka.Plugin` modules, app MCP endpoint registrations, app skill load paths, imported-agent allowlist registries. | Jidoka validates and runs them; the app owns lifecycle, auth, deployment, and service semantics. |
| External package | Broad integration families with their own dependency, credential, rate-limit, policy, or service lifecycle. | Service catalogs, `jido_connect` style connectors, OAuth/vault brokers, interactive browser automation, remote agent protocols, large dynamic tool registries. | Ship as companion packages or host-app code. Jidoka should expose a stable contract instead of absorbing the implementation. |

This split keeps the beginner DSL small while preserving an upgrade path:
developers can start with core operations, graduate repeated app patterns into
extensions, and move broad service surfaces into external packages without
changing the agent turn model.

### Provider-Free Testability

Every core integration should have a test path that does not require live LLM
providers or third-party network services.

| Integration | Provider-free verification path |
| --- | --- |
| Direct actions | Unit tests validate action metadata, schemas, duplicate names, inspection, and failure normalization with local action modules. |
| Ash resources | Unit tests expand local AshJido fixtures and verify actor/domain context injection without external data stores. |
| Web tools | Unit tests validate URL safety, DNS-private host rejection, result clamps, truncation, and capability conflicts without starting browser tools. |
| MCP tools | Unit tests use fake sync modules for metadata/error paths and a local filesystem stdio endpoint for end-to-end sync. |
| Skills | Unit tests validate module skills, runtime skill load paths from local fixtures, prompt injection, and `allowed_tools` narrowing. |
| Plugins | Unit tests validate local plugin modules and merged plugin actions without live services. |
| Catalog / connect layer | No core runtime yet. Future tests should use in-memory catalog fixtures and fake brokers before any service-backed connector tests. |

### Catalog Discovery Contract

Catalogs are the scalable answer for large tool surfaces. The key invariant is
simple: do not put hundreds or thousands of tool schemas in the model prompt.
Give the agent one small discovery operation, let deterministic catalog code
find relevant candidates, then expose only a bounded selected set.

Recommended V3 contract:

1. **Prompt surface:** the agent sees a compact catalog-search operation and
   instructions for when to use it. The full catalog is never rendered into the
   system prompt.
2. **Search input:** the model supplies a small query payload such as
   `query`, `intent`, `domain`, `required_inputs`, `credential_provider`,
   `risk`, and `max_results`.
3. **Catalog engine:** app or companion-package code searches indexed action
   metadata with deterministic filters and ranking. This can use keyword,
   metadata, capability tags, embeddings, or service-specific indexes, but it
   should not require an LLM to choose candidates.
4. **Candidate output:** search returns a capped list of operation cards:
   stable id, name, short description, capability tags, input schema summary,
   auth/credential requirements, risk, version, and source package.
5. **Execution:** the runtime either registers the selected candidates for the
   current request or invokes one through a generic catalog executor with the
   selected operation id and arguments.
6. **Controls and credentials:** operation controls run after candidate
   selection and before execution. Credential brokers resolve references inside
   the application boundary, not in the model prompt.
7. **Tracing:** traces record the search query summary, candidate ids, selected
   operation id, credential reference metadata, and execution result metadata,
   not full catalog payloads or secrets.

Operational guardrails:

- cap search results by default, for example 5 to 10 candidates
- cap schema/detail size in returned cards
- prefer stable operation ids over generated prompt names
- require an allowlisted executor for imported or remote catalog entries
- keep service-specific clients, auth, rate limits, and retries in companion
  packages or host-app code

This lets Jidoka support 100, 1,000, or 100,000 available operations without
turning the system prompt into a registry dump. Jidoka's role is the agent-facing
contract; the action/catalog package owns indexing and the integration package
owns service execution.

## Ecosystem Scan

Scanned on 2026-05-24 from Hex package search for `agent`, `LLM`, and adjacent
LLM/agent packages. Many `agent` results are OTP `Agent`, monitoring agents, or
user-agent parsers; the list below focuses on packages that materially overlap
with AI agent authoring, runtime, tools, orchestration, observability, memory,
or integration.

Sources:

- [Hex `agent` search](https://hex.pm/packages?search=agent&sort=recent_downloads)
- [Hex `LLM` search](https://hex.pm/packages?search=LLM&sort=recent_downloads)
- [Jido ecosystem](https://jido.run/ecosystem/jido)
- [Jido observability](https://hexdocs.pm/jido/observability.html)
- [Jido.AI observability basics](https://hexdocs.pm/jido_ai/observability_basics.html)
- [ReqLLM telemetry](https://hexdocs.pm/req_llm/telemetry.html)
- [OpenTelemetry GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [Langfuse OpenTelemetry integration](https://langfuse.com/integrations/native/opentelemetry)

### Relevant Package Groups

| Group | Packages | Feature signal |
| --- | --- | --- |
| Agent runtime / harness | `jido`, `alloy`, `adk`, `adk_ex`, `sagents`, `agens`, `nous`, `condukt`, `agentic`, `legion`, `swarm_ai`, `llm_agent`, `gen_agent`, `normandy`, `omni_agent` | Agents, sessions, tools, model abstraction, OTP process ownership, multi-agent orchestration |
| Graph / workflow orchestration | `lang_ex`, `phlox`, `jido_composer`, `lux`, `spooks`, `magus`, `shifts`, `synaptic` | Nodes, edges, conditional routing, state reducers, checkpoints, interrupts, human-in-the-loop, replay/resume |
| Tool contracts / tool registry | `altar`, `jido_action`, `llm_toolkit`, `lang_schema`, `ex_mcp`, `langchain_mcp`, `mcpixir` | Typed tool definitions, schema conversion, MCP clients/servers, tool discovery and dispatch |
| Sessions / stateful conversation | `agent_session_manager`, `omni_agent`, `adk_ex`, `rag_ex`, `phoenix_llm_chat` | Multi-provider sessions, persistent or branching conversations, session stores, conversation-to-provider projection |
| Structured output / schemas | `instructor`, `ash_baml`, `simplify_baml`, `lang_schema`, `json_remedy`, `omni`, `normandy` | Schema-driven LLM output, JSON repair, provider schema adaptation, type-safe prompt contracts |
| Controls / guardrails / approvals | `llm_guard`, `sagents`, `omni_agent`, `phlox`, `lang_ex` | Prompt-injection detection, data-leak prevention, middleware, approval gates, human-in-the-loop interrupts |
| Observability / tracing / evals | `agent_obs`, `aitrace`, `langfuse`, `aludel`, `tribunal`, `deep_eval_ex`, `vial_llm`, `braintrust` | Agent-loop instrumentation, OpenTelemetry/OpenInference, traces, eval workbenches, prompt/eval tracking |
| Memory / context systems | `jido_memory`, `jido_gralkor`, `gralkor_ex`, `mnemosyne`, `recollect`, `contexa`, `cortexa`, `comm_bus` | Conversation memory, semantic memory, knowledge graphs, context assembly, versioned context workspaces |
| UI / streaming / debug | `ag_ui_ex`, `sagents_live_debugger`, `phoenix_streamdown`, `phoenix_llm_chat`, `codex_sdk` | Agent UI protocol, LiveView debugging, streaming markdown, session/chat components |
| Tool integrations | `ash_ai`, `ash_agent`, `jido_browser`, `ex_mcp`, `agent_workshop`, `jido_connect` | Ash actions, browser automation, MCP, backend-agnostic orchestration, catalog-backed integrations |
| Protocols / interoperability | `a2a`, `a2a_elixir_sdk`, `acpex`, `agent_client_protocol`, `ex_mcp`, `ag_ui_ex` | A2A, ACP, MCP, AG-UI, remote agent exposure and consumption |

### Feature Comparison

| Jidoka topic | Ecosystem coverage | Implication for Jidoka |
| --- | --- | --- |
| Agents | Strong. Jido, Alloy, ADK, Sagents, Nous, Normandy, Omni Agent all center this. | Keep Jidoka's value as the cleanest Elixir authoring layer over Jido, not a second runtime. |
| Chat turns | Strong. Most frameworks expose a turn/run/call primitive. | Keep `Jidoka.chat/3` as the primary primitive; avoid API proliferation. |
| Sessions | Strong and often process-backed or store-backed. | Jidoka's plain `Session` descriptor is distinctive; document clearly as addressing, not durability. |
| Context | Common but often implicit. | Make context explicit and schema-able; this is a beginner-friendly differentiator. |
| Typed results | Strong across Instructor/BAML/schema packages, less consistently tied to agents. | Keep as a first-class agent contract, but teach it after context. |
| Actions | Universal. Strong packages emphasize typed contracts. | Use `action` language in V2; let the underlying action layer own execution contracts where possible. |
| Controls | Present as middleware, guardrails, approvals, or interrupts. | `controls` is a strong unifying noun if it stays simple: input, operation, result. |
| Human-in-the-loop | Strong in graph/workflow packages and approval-oriented agent systems. | Make it a named feature built from controls and interrupts, not a separate runtime. |
| Credential brokering | Emerging; not obviously first-class in Elixir agent packages yet. | Add as planned integration/security topic. Likely belongs near tools, controls, catalogs, and connect-style integrations. |
| Debugging | Strong need across LiveView/debugger packages, but often tool-specific. | Treat debugging as a first-class local developer loop: inspect request, prompt, trace, state, and view projections. |
| Observability standards | Strong. The foundation already emits structured telemetry and can project model calls into OpenTelemetry GenAI spans. | Position Jidoka traces as the local debugging view over standards-friendly telemetry, not a competing standard. |
| Memory and compaction | Strong but fragmented. Many packages focus on memory; fewer pair it with prompt-window compaction. | Preserve both as separate concepts: memory recalls facts, compaction manages provider-facing context. |
| Streaming and UI projections | Strong around UI packages and LiveView-specific tooling. | Teach the beginner concept as a UI projection; keep `AgentView` as the concrete adapter from agent runtime to Phoenix/UI surfaces, with streaming as a prerequisite concept. |
| Schedules | Common in long-running personal/ops agents, less central in libraries. | Keep first-class schedules; they are valuable for OTP-native agents. |
| Workflows | Very strong in graph/workflow packages. | Jidoka should keep workflows deterministic and app-owned; do not make every beginner learn graphs. |
| Subagents and handoffs | Strong in multi-agent frameworks and protocol packages. | Teach after workflows/tools; subagents return control to the parent, while handoffs route future turns to a new owner. |
| Tool integrations | Strong and growing. MCP, Ash, browser, catalogs appear repeatedly. | Use catalogs/connect as the scalable integration story; avoid listing 100 tool modules in prompts. |
| Imported agents | Less common as JSON/YAML specs; protocols cover remote agents. | Keep imported agents as portability, with allowlisted registries as a safety boundary. |
| Durability | Strong in lower-level runtimes and graph systems via checkpoints, journals, persistence, and resume. | Do not pretend `Jidoka.Session` is durable; teach the graduation path into durable runtime storage and instance managers. |
| Testing | Present in eval packages, less often in agent DSLs. | Make testing a full onboarding topic: contract tests, action tests, workflow tests, trace assertions, optional evals. |

### Gaps And Reframed Features

1. **Durable sessions and branching transcripts.** Several runtimes and graph
   systems emphasize persistence, branching, checkpointing, and resume. Jidoka
   should not hide this behind `Session`: the first story is graduation to
   durable runtime storage, hibernate/thaw, checkpoints, and thread journals.
2. **Human-in-the-loop as a named concept.** Controls can already interrupt or
   approve. The product gap is naming and teaching it explicitly as
   human-in-the-loop, especially for risky tools and final results.
3. **Protocol surface.** A2A, ACP, MCP, and AG-UI show that agent
   interoperability is becoming a distinct topic. Jidoka should decide which are
   first-class versus delegated to companion packages.
4. **Catalog and credential brokering boundary.** Tool catalogs and credential
   brokering belong together: the agent discovers a capability, controls decide
   whether it may run, and a broker/connect layer injects credentials.
5. **Observability standards are inherited, not missing.** Jidoka should document
   that it is built on a foundation that emits structured telemetry, preserves
   correlation IDs, and can bridge model calls into OpenTelemetry GenAI spans
   for OTLP backends.
6. **Debugging as first-class DX.** Debugging should be distinct from production
   observability: local inspection, traces, prompt previews, AgentView, and
   Livebook/Kino views should be the normal way to understand a run.
7. **Memory ownership.** Memory packages are fragmented. Jidoka docs should be
   precise about what owns memory, how it is inspected, and how it differs from
   compaction and context.

### Table Of Contents Adjustments

The canonical table of contents has been updated based on the ecosystem scan:

1. Add **Human-in-the-loop** directly after **Controls** because approvals and
   interrupts are a core control outcome.
2. Keep **Credential brokering** directly after human-in-the-loop because
   authenticated tools are where security questions become concrete.
3. Split **Debugging** from **Observability standards**. Debugging is the local
   developer loop; observability is the production telemetry/export story.
4. Add **Durability and graduation** so users understand when `Session` stops
   being enough and durable runtime storage should take over.
