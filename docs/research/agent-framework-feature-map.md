# Agent Framework Feature Map

This is the canonical, source-backed roadmap for comparing Jidoka with Mastra,
LangChain/LangGraph, Pydantic AI, the OpenAI Agents SDK, Google ADK,
LlamaIndex/LlamaAgents, and Microsoft AutoGen.

Reviewed against current official documentation on **2026-07-16**. See the
[`agent-framework-source-manifest.md`](agent-framework-source-manifest.md) for
research boundaries and [`../comparisons/README.md`](../comparisons/README.md)
for use-case documents and proof status.

If you are selecting a framework, begin with the
[Agent Framework Selection Guide](../comparisons/framework-selection-guide.md).
This matrix is a deep-diligence and Jidoka-roadmap artifact, not a ranking.
Cells classify documented capability locus and qualifiers; they do not score
quality, reliability, maturity, performance, support, security, portability, or
operating cost.

## How to read the matrix

Competitor cells classify implementation locus, not quality:

| Code | Meaning |
| --- | --- |
| `C` | Core framework/runtime capability |
| `I` | Official integration, companion package, or maintained adapter |
| `H` | Hosted/vendor-managed product capability |
| `A` | Officially documented app-managed pattern |
| `N` | Not established in the bounded review |
| `*` | Material qualifier: partial semantics, beta/experimental, provider-specific, or language-limited |

Jidoka cells use a separate capability state:

| Code | Meaning |
| --- | --- |
| `S` | Shipped public Jidoka capability |
| `P` | Partial or materially narrower capability |
| `A` | App-managed using Jidoka primitives |
| `N` | Not established/product gap |

An atomic cell is one code, optionally followed by `*`. A composite cell joins
two or more atomic cells with `/`: the first is the primary or broadest
documented path and later values are supporting or alternative loci. An `*`
qualifies only the code immediately before it. For example, `C*/A` means a
qualified Core surface plus an app-managed path, while Jidoka `P/A` means a
partial public capability that applications can extend with Jidoka primitives.
`N` is never combined with another code.

These codes are deliberately compact. The linked comparison is the feature's
primary semantic contract and contains its qualifiers and official sources; it
is not necessarily the brief carrying the current Jidoka proof. Proof links
live in the capability/proof audit below.

## Authoring, models, and result contracts

| ID | Atomic feature and primary contract | Mastra | LangChain | Pydantic AI | OpenAI SDK | ADK | LlamaIndex | AutoGen | Jidoka |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `A01` | [Code-first agent definition](../comparisons/15-portable-definitions-context-and-model-configuration.md) | C | C | C | C | C | C | C | S |
| `A02` | [Declarative/data-defined agent spec and serialization](../comparisons/15-portable-definitions-context-and-model-configuration.md) | H* | H* | C | N | C* | N | C | S |
| `A03` | [Dynamic instructions and prompt configuration](../comparisons/15-portable-definitions-context-and-model-configuration.md) | C | C | C | C | C | C | C | P |
| `A04` | [Typed runtime dependency/context injection](../comparisons/15-portable-definitions-context-and-model-configuration.md) | C | C | C | C | C | C | C | S |
| `A05` | [Provider/model abstraction](../comparisons/20-provider-routing-fallback-and-retry.md) | C | I | C | C/I | C/I | I | I | S |
| `A06` | [Dynamic routing, fallback, and model retry](../comparisons/20-provider-routing-fallback-and-retry.md) | C* | C | C | C* | C | A | A | N |
| `A07` | [Typed structured final result](../comparisons/06-bounded-structured-result-repair.md) | C | C | C | C | C* | C | C | S |
| `A08` | [Bounded validation-feedback result repair](../comparisons/06-bounded-structured-result-repair.md) | N | C* | C | N | N | C* | N | S |
| `A09` | [Multimodal model input/output](../comparisons/18-multimodal-voice-and-realtime-agents.md) | C | C | C | C | C* | C* | C | N |

## Execution and continuation

| ID | Atomic feature and primary contract | Mastra | LangChain | Pydantic AI | OpenAI SDK | ADK | LlamaIndex | AutoGen | Jidoka |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `E01` | [Synchronous and asynchronous runs](../comparisons/07-async-streaming-events-limits-and-cancellation.md) | C | C | C | C | C | C | C | S |
| `E02` | [Token, item, and semantic event streaming](../comparisons/07-async-streaming-events-limits-and-cancellation.md) | C | C | C | C | C | C | C | S |
| `E03` | [Parallel tool-call execution with ordered observations](../comparisons/07-async-streaming-events-limits-and-cancellation.md) | C | C | C | C | C* | C* | C | S |
| `E04` | [Run, request, tool-call, token, and timeout limits](../comparisons/07-async-streaming-events-limits-and-cancellation.md) | C | C | C | C | C* | C | C | S |
| `E05` | [Cancellation and terminal cancellation evidence](../comparisons/07-async-streaming-events-limits-and-cancellation.md) | C | C/H | A | C | C | I | C | N |
| `E06` | [Serializable pause/resume state](../comparisons/09-resumable-state-durable-execution-and-replay.md) | C | C | I | C | C | C/A | C/A | S |
| `E07` | [Crash-safe durable execution](../comparisons/09-resumable-state-durable-execution-and-replay.md) | C/I | C/I | I | I | I | I | A | P/A |
| `E08` | [Replay, fork, rewind, or time travel](../comparisons/09-resumable-state-durable-execution-and-replay.md) | C | C | I* | N | C* | A | A | S* |

## Workflow and graph composition

| ID | Atomic feature and primary contract | Mastra | LangChain | Pydantic AI | OpenAI SDK | ADK | LlamaIndex | AutoGen | Jidoka |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `W01` | [Sequential typed steps](../comparisons/02-deterministic-workflow-composition.md) | C | C | C | A | C | C | C* | S |
| `W02` | [Conditional routing and branch selection](../comparisons/02-deterministic-workflow-composition.md) | C | C | C | A | C | C | C* | S |
| `W03` | [Parallel fan-out/fan-in and reduction](../comparisons/02-deterministic-workflow-composition.md) | C | C | C | A | C | C | C* | S |
| `W04` | [Cycles, loops, and dynamically created work](../comparisons/19-teams-group-chat-and-agent-graphs.md) | C | C | C | A | C | C | C* | N |
| `W05` | [Bounded step retry](../comparisons/02-deterministic-workflow-composition.md) | C | C | C | C*/A | C* | C | N | S |
| `W06` | [Workflow/team exposed as one agent tool](../comparisons/02-deterministic-workflow-composition.md) | C | A | A | A | C* | C* | C | S |
| `W07` | [Background and long-running work](../comparisons/17-background-schedules-servers-and-deployment.md) | C | H | I* | I | C | I | A | N |
| `W08` | [Schedules and cron-triggered runs](../comparisons/17-background-schedules-servers-and-deployment.md) | C | H | A | A | H/A | A | A | N |

## Tools, discovery, and protocols

| ID | Atomic feature and primary contract | Mastra | LangChain | Pydantic AI | OpenAI SDK | ADK | LlamaIndex | AutoGen | Jidoka |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `T01` | [Schema-derived function/action tools](../comparisons/12-dynamic-tools-catalogs-skills-and-extensions.md) | C | C | C | C | C | C | C | S |
| `T02` | [Dynamic tool filtering and per-run availability](../comparisons/12-dynamic-tools-catalogs-skills-and-extensions.md) | C | C | C | C | C | N | C | P |
| `T03` | [Tool catalog search and progressive discovery](../comparisons/12-dynamic-tools-catalogs-skills-and-extensions.md) | C | C | I* | H | I/H | A | C | S |
| `T04` | [Skills, capabilities, toolsets, and extension bundles](../comparisons/12-dynamic-tools-catalogs-skills-and-extensions.md) | C | I/A | C/I | C/H | C | I | I | S |
| `T05` | [Pre-execution tool approval](../comparisons/01-resumable-tool-approval.md) | C | C | C | C | C* | A | C/A | S |
| `T06` | [Idempotency, deduplication, and at-least-once effects](../comparisons/08-controls-guardrails-and-operation-safety.md) | A | C/A | I/A | I/A | A | A | N | S |
| `T07` | [MCP client tool consumption](../comparisons/04-mcp-client-tool-consumption.md) | C | I | C | C/H | I | I | I | S |
| `T08` | [MCP resources, prompts, elicitation, and sampling](../comparisons/13-mcp-breadth-and-remote-agent-protocols.md) | C | I | C | C* | N | N* | I* | N |
| `T09` | [MCP server exposure](../comparisons/13-mcp-breadth-and-remote-agent-protocols.md) | C | H | C | N | A | I | N | N |
| `T10` | [A2A, ACP, and remote-agent protocols](../comparisons/13-mcp-breadth-and-remote-agent-protocols.md) | C/I | H/I | I* | N | C* | N | N | N |
| `T11` | [Web search, page reading, and browser automation](../comparisons/16-browser-code-execution-and-sandboxes.md) | C/I | I | C* | C/H | I | A | I | S* |
| `T12` | [Code, shell, patch, and computer-use tools](../comparisons/16-browser-code-execution-and-sandboxes.md) | C/I | I | I | C/H | C/I | C/A | C/I | N |
| `T13` | [RAG and retrieval as an agent capability](../comparisons/14-memory-compaction-rag-and-knowledge.md) | C/I | C/I | C/A | H | C/H | C | I/A | N |
| `T14` | [Credential references, auth, and credential brokering](../comparisons/21-credential-and-sensitive-data-boundaries.md) | C* | H* | A | A/H | C | A | A | N |

## Multi-agent semantics

| ID | Atomic feature and primary contract | Mastra | LangChain | Pydantic AI | OpenAI SDK | ADK | LlamaIndex | AutoGen | Jidoka |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `M01` | [Manager-owned bounded delegation](../comparisons/03-bounded-delegation-vs-ownership-handoff.md) | C | C/A | C/I | C | C | C | C | S |
| `M02` | [Future-turn ownership handoff](../comparisons/03-bounded-delegation-vs-ownership-handoff.md) | N | C/A | A | C | C | C | C | S |
| `M03` | [Group chat, team, swarm, and speaker selection](../comparisons/19-teams-group-chat-and-agent-graphs.md) | C* | A | I* | H* | C | C | C | N |
| `M04` | [Deterministic multi-agent graph](../comparisons/19-teams-group-chat-and-agent-graphs.md) | C | C | C | A | C | C | C* | P |
| `M05` | [Subagent context isolation and projection](../comparisons/03-bounded-delegation-vs-ownership-handoff.md) | C | C/A | C/I | C | C | C | C | S |
| `M06` | [Remote/distributed agent runtime](../comparisons/13-mcp-breadth-and-remote-agent-protocols.md) | C | H | I* | H* | C/H | I | I* | N |

## Sessions, memory, and knowledge

| ID | Atomic feature and primary contract | Mastra | LangChain | Pydantic AI | OpenAI SDK | ADK | LlamaIndex | AutoGen | Jidoka |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `S01` | [Conversation/session history](../comparisons/05-session-history-vs-scoped-memory-continuity.md) | C | C | C/A | C | C | C | C | P |
| `S02` | [Thread/checkpoint workflow state](../comparisons/09-resumable-state-durable-execution-and-replay.md) | C | C | I | C | C | C/A | C/A | S |
| `S03` | [Long-term semantic/fact memory](../comparisons/14-memory-compaction-rag-and-knowledge.md) | C | C | I | C* | C/H | C | C/I | S* |
| `S04` | [Scoped and namespaced memory](../comparisons/14-memory-compaction-rag-and-knowledge.md) | C | C | I | C* | C | C | C/I | S |
| `S05` | [Context compaction and summarization](../comparisons/14-memory-compaction-rag-and-knowledge.md) | C | C | C/I | C/H | C | C | C | N |
| `S06` | [Pluggable persistence and memory stores](../comparisons/14-memory-compaction-rag-and-knowledge.md) | C/I | C/I | I/A | C/I/H | C/H | C | I/A | P |
| `S07` | [Knowledge ingestion, embedding, and indexing](../comparisons/14-memory-compaction-rag-and-knowledge.md) | C/I | C/I | C/A | H | I/H | C | I/A | N |

## Safety, policy, and human control

| ID | Atomic feature and primary contract | Mastra | LangChain | Pydantic AI | OpenAI SDK | ADK | LlamaIndex | AutoGen | Jidoka |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `G01` | [Input guardrails/controls](../comparisons/08-controls-guardrails-and-operation-safety.md) | C | C | I | C | C | A | C | S |
| `G02` | [Output/result guardrails/controls](../comparisons/08-controls-guardrails-and-operation-safety.md) | C | C | I | C | C | A | C | S |
| `G03` | [Tool/operation policy boundary](../comparisons/08-controls-guardrails-and-operation-safety.md) | C | C | C/I | C | C | A | C | S |
| `G04` | [Suspend/resume human review](../comparisons/01-resumable-tool-approval.md) | C | C | C | C | C* | C/A | C/A | S |
| `G05` | [Sensitive-data redaction and trace policy](../comparisons/21-credential-and-sensitive-data-boundaries.md) | I | C/H | C/I | C | A/I | A | A | S |
| `G06` | [Sandbox and execution permissions](../comparisons/16-browser-code-execution-and-sandboxes.md) | C/I | I/H | I | C/H | I | A | I | N |

## Observability, evaluation, and testing

| ID | Atomic feature and primary contract | Mastra | LangChain | Pydantic AI | OpenAI SDK | ADK | LlamaIndex | AutoGen | Jidoka |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `O01` | [Lifecycle events and hooks](../comparisons/07-async-streaming-events-limits-and-cancellation.md) | C | C | C | C | C | C | C | S |
| `O02` | [Local inspection, preflight, debug, and visualization](../comparisons/10-observability-tracing-usage-and-inspection.md) | C/I | C/H | C/H | C | C | I/H | C/I | S |
| `O03` | [Hierarchical traces, spans, sinks, and export](../comparisons/10-observability-tracing-usage-and-inspection.md) | C/I | H/I | C | C/H | C | I | C | P |
| `O04` | [Usage, token, duration, and cost accounting](../comparisons/10-observability-tracing-usage-and-inspection.md) | C | C/I | C | C | C | C | C | S |
| `O05` | [Deterministic behavioral evaluation](../comparisons/11-evaluation-datasets-and-deterministic-testing.md) | C | H/I | I | H | C | C | N | S |
| `O06` | [Datasets and repeatable experiments](../comparisons/11-evaluation-datasets-and-deterministic-testing.md) | C/H | H | I | H | C | C | N | P |
| `O07` | [LLM judges, custom scorers, and trajectory evaluation](../comparisons/11-evaluation-datasets-and-deterministic-testing.md) | C | H/I | I | H | C/H | C* | N | P |
| `O08` | [Online evals, trace scoring, and feedback](../comparisons/11-evaluation-datasets-and-deterministic-testing.md) | C/H | H | I | H | I/H | I/H | N | N |

## Runtime, deployment, and developer experience

| ID | Atomic feature and primary contract | Mastra | LangChain | Pydantic AI | OpenAI SDK | ADK | LlamaIndex | AutoGen | Jidoka |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `R01` | [Long-lived/process-hosted agent runtime](../comparisons/17-background-schedules-servers-and-deployment.md) | C | H/I | A | A/C* | C | I | C | S |
| `R02` | [HTTP/API agent server](../comparisons/17-background-schedules-servers-and-deployment.md) | C | H/I | A/I* | A | C | I | A | N |
| `R03` | [Managed deployment/control plane](../comparisons/17-background-schedules-servers-and-deployment.md) | H/I | H | I* | I/H | H | H | N | N |
| `R04` | [Studio, playground, and local developer UI](../comparisons/22-ui-protocols-studio-and-developer-tooling.md) | I/H | H | C/H | C* | C | I/H | I* | P |
| `R05` | [UI projection or event protocol](../comparisons/22-ui-protocols-studio-and-developer-tooling.md) | C/I | C/H | C | C* | C | I | C* | S |
| `R06` | [Realtime voice/audio agent runtime](../comparisons/18-multimodal-voice-and-realtime-agents.md) | I | A/I | N | C/H | C* | N | N | N |
| `R07` | [Provider-free tests and deterministic model/tool doubles](../comparisons/11-evaluation-datasets-and-deterministic-testing.md) | C | C | C | A | C | C | I | S |

## Jidoka capability and proof audit

The matrix is not a raw scorecard. For Jidoka, the important question is what
evidence exists and what should happen next.

| Disposition | Feature IDs | Current evidence or required action |
| --- | --- | --- |
| Proven | `A07`, `A08`, `E03`, `E06`, `W01`, `W02`, `W03`, `W05`, `W06`, `T05`, `T07`, `M01`, `M02`, `M05`, `G04` | Proof briefs: [01 approval](../comparisons/01-resumable-tool-approval.md), [02 workflows](../comparisons/02-deterministic-workflow-composition.md), [03 delegation/handoff](../comparisons/03-bounded-delegation-vs-ownership-handoff.md), [04 MCP client](../comparisons/04-mcp-client-tool-consumption.md), and [06 result repair](../comparisons/06-bounded-structured-result-repair.md). Deterministic tests live in `test/parity/`; `E06` proof is specifically approval continuation. |
| Partial proof | `S01`, `S03`, `S04`, `S06` | [Comparison 05](../comparisons/05-session-history-vs-scoped-memory-continuity.md) characterizes explicit state carry and memory scope; ordinary sessions do not auto-inject a full prior transcript and in-memory stores are not production durability. |
| Proof needed | `A01`, `A02`, `A03`, `A04`, `A05`, `E01`, `E02`, `E04`, `E08`, `T01`, `T02`, `T03`, `T04`, `T06`, `T11`, `M04`, `S02`, `G01`, `G02`, `G03`, `G05`, `O01`, `O02`, `O03`, `O04`, `O05`, `O06`, `O07`, `R01`, `R04`, `R05`, `R07` | Public APIs exist; add focused provider-free proofs before publishing parity claims. Some are intentionally narrower than competitor surfaces. |
| Product gap | `A06`, `A09`, `E05`, `E07`, `W04`, `W07`, `W08`, `T08`, `T09`, `T10`, `T12`, `T13`, `T14`, `M03`, `M06`, `S05`, `S07`, `G06`, `O08`, `R02`, `R03`, `R06` | Requires product design/implementation or an explicit strategic exclusion before showcase work. |
| App-managed boundary | Durable stores, authentication/authorization, cluster ownership routing, effect result persistence, production queues, provider credentials | Jidoka exposes contracts and extension points but must not claim ownership of application infrastructure. |

## Priority scoring

Parity priority is reproducible from five visible factors:

- prevalence (`P`): number of competing ecosystems documenting the feature,
  normalized 1-5;
- developer value (`V`): value to a typical production agent application;
- demo clarity (`D`): how clearly deterministic evidence can show the behavior;
- Jidoka readiness (`R`): current public capability and proof proximity; and
- demonstration cost (`C`): relative implementation/proof effort.

`Parity total = P + V + D + R - C`.

| Comparison | P | V | D | R | C | Total | Disposition |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 07 Async streaming/events | 5 | 5 | 5 | 5 | 2 | 18 | Next proof; keep cancellation as a gap |
| 08 Controls/guardrails/safety | 5 | 5 | 5 | 5 | 2 | 18 | Next proof |
| 10 Observability/inspection | 5 | 4 | 5 | 5 | 2 | 17 | Next proof; qualify lack of OTel export |
| 12 Dynamic tools/catalogs/skills | 5 | 4 | 5 | 5 | 2 | 17 | Next proof |
| 15 Definitions/context/models | 5 | 5 | 4 | 4 | 2 | 16 | Prove existing surface; leave routing gap |
| 09 Resume/durability/replay | 5 | 5 | 4 | 4 | 3 | 15 | Prove current boundary; do not overclaim crash safety |
| 11 Evals/testing | 4 | 4 | 4 | 4 | 2 | 14 | Prove local evals; separate platform gaps |
| 22 UI/devtools | 5 | 3 | 5 | 4 | 3 | 14 | Prove AgentView/Kino boundary |
| 14 Memory/compaction/RAG | 5 | 5 | 4 | 3 | 4 | 13 | Prove memory; plan compaction/RAG gaps |
| 21 Credential/sensitive data | 4 | 5 | 4 | 3 | 4 | 12 | Prove trace redaction; design broker separately |
| 19 Teams/agent graphs | 4 | 4 | 4 | 2 | 4 | 10 | Product decision before proof |
| 20 Provider routing/fallback | 4 | 4 | 4 | 1 | 3 | 10 | Product gap |
| 16 Browser/code/sandbox | 4 | 4 | 4 | 2 | 5 | 9 | Prove narrow browser tools only |
| 13 MCP breadth/protocols | 4 | 4 | 4 | 1 | 5 | 8 | Product gap |
| 17 Background/deployment | 4 | 4 | 4 | 1 | 5 | 8 | Product gap beyond process hosting |
| 18 Realtime voice | 3 | 3 | 5 | 1 | 5 | 7 | Defer or exclude |

## Differentiation ranking

Differentiation uses strategic fit (`S`), distinctiveness (`X`), proof strength
(`P`), readiness (`R`), and cost (`C`): `S + X + P + R - C`.

| Comparison | S | X | P | R | C | Total | Why it matters |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 01 Resumable approval | 5 | 5 | 5 | 5 | 2 | 18 | Signed snapshots, review cursor, effect journal, targeted resume |
| 03 Delegation versus ownership | 5 | 4 | 5 | 5 | 2 | Explicitly separates bounded child work from future-turn routing |
| 02 Deterministic workflows | 5 | 3 | 5 | 5 | 2 | Ordered fan-in and exact retry bounds through the effect boundary |
| 12 Governed catalogs | 5 | 4 | 4 | 4 | 3 | Progressive discovery without loading a large hidden tool set into the prompt |
| 10 Local inspection/replay | 5 | 4 | 4 | 4 | 3 | Stable projections and data-only replay are provider-independent evidence |
| 21 Credential boundary | 5 | 5 | 2 | 1 | 5 | Strategically strong, but raw credential brokering is not implemented |

## Ordered capability-gap backlog

1. Add cancellation with a typed terminal result and inspectable event trail.
2. Define the durable-execution boundary: persistent checkpoints, claims,
   recovery, completed-effect handling, and crash semantics.
3. Add OpenTelemetry-compatible spans/export without weakening local events and
   stable projections.
4. Expand evals into datasets, repeated experiments, trajectory assertions,
   custom scorers, and optional online evaluation.
5. Decide MCP resources/prompts/server scope and whether Jidoka adopts A2A or
   ACP through core or companion packages.
6. Add transcript compaction and decide the RAG/knowledge-ingestion boundary.
7. Add provider routing/fallback/retry policy above the current model adapter.
8. Define sandboxed filesystem/shell/code execution as a companion boundary.
9. Decide whether schedules, background runs, and an HTTP agent server belong
   in Jidoka or the surrounding Jido ecosystem.
10. Decide whether multimodal and realtime voice are strategic or excluded.
11. Add a general team/group-chat runtime only if workflows, delegation, and
    handoffs cannot cover the target use cases cleanly.
12. Design credential references/brokering without exposing secrets to prompts,
    tool arguments, transcripts, or traces.
13. Keep AgentView/Kino as the local evidence surface; consider a Studio only
    after the underlying runtime features and protocol contracts stabilize.

## Invalidation rules

- A moved or materially changed official page stales only its dependent cells.
- A hosted feature cannot be promoted to Core because its UI appears alongside
  the open-source docs.
- Serializable state is not automatically durable execution.
- Tool approval is not authentication or authorization.
- A session identifier is not durable memory.
- A passing model response is not proof that a tool, handoff, memory write,
  checkpoint, or workflow step actually ran.
- Proven Jidoka status requires deterministic evidence through public results,
  journals, events, snapshots, stores, ownership records, traces, or stable
  projections.
