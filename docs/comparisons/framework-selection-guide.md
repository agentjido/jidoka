# Agent Framework Selection Guide

This guide is the buyer-facing entrance to the Jidoka comparison corpus. Use it
to form a shortlist and identify the evidence still needed for a decision. Use
the [73-feature map](../research/agent-framework-feature-map.md) only after the
application's hard constraints are clear.

Reviewed against current official documentation on **2026-07-16**.

This is not a framework ranking. The research establishes documented
capabilities, implementation locus, material qualifiers, and selected Jidoka
proofs. It does not establish relative API quality, production reliability,
performance, support quality, community strength, compliance, or total cost.

## Five-minute selection path

Start with disqualifiers. A candidate that fails a hard constraint should not
earn its way back through unrelated feature breadth.

| Question | Record before comparing features | Where to inspect |
| --- | --- | --- |
| Which language and runtime will production use? | Exact package, language, and runtime; record a major-version verification as an unknown when the manifest does not pin it | [Ecosystem manifest](../research/agent-framework-source-manifest.md#ecosystem-manifest), [unknown record](#selection-unknown-record) |
| What workload must the framework own? | Consequential tool use, durable workflow, data/RAG, realtime, multi-agent, managed service, or another explicit archetype | [Workload routes](#workload-routes) |
| Which capability loci are acceptable? | Whether Core, official Integration, Hosted, and App-managed implementations are acceptable for each must-have | [Matrix grammar](../research/agent-framework-feature-map.md#how-to-read-the-matrix) |
| Who will operate the missing pieces? | Owner of state, queues, schedules, API, auth, credentials, telemetry, evals, UI, scaling, and deployment | [Ownership bill](#deployable-assembly-ownership-bill) |
| What failure must be safe? | One consequential failure scenario and the required invariant | [Production cross-examination](#production-cross-examination) |
| Which provider or hosted dependencies are acceptable? | Required vendor services, provider-specific tools, and the behavior that must survive a provider change | [Definitions/models](15-portable-definitions-context-and-model-configuration.md), [routing](20-provider-routing-fallback-and-retry.md) |

The output is not a numeric winner. Put each candidate in one of three buckets:

- **eligible** — current evidence satisfies every hard constraint;
- **targeted spike required** — documentation is promising, but a decisive
  behavior or operating boundary must be reproduced locally; or
- **disqualified** — current evidence conflicts with a non-negotiable.

## Ecosystem orientation

These are buyer-routing summaries, not a second research record. The
[source manifest](../research/agent-framework-source-manifest.md#ecosystem-manifest)
owns package/language and product boundaries; linked briefs own semantic claims
and official sources. “Investigate first” is a likely decision boundary, not a
universal disadvantage.

| Ecosystem | Why it may enter a shortlist | Investigate before shortlisting | Canonical evidence |
| --- | --- | --- | --- |
| Mastra | TypeScript team seeking a broad integrated agent, workflow, eval, Server, and Studio surface | Required long-running feature maturity; self-hosted Server/local Studio versus Platform ownership | [Manifest](../research/agent-framework-source-manifest.md#ecosystem-manifest), [deployment](17-background-schedules-servers-and-deployment.md), [devtools](22-ui-protocols-studio-and-developer-tooling.md) |
| LangChain / LangGraph | Python team choosing between a higher-level harness and fine-grained stateful graph orchestration | Required abstraction layer; OSS runtime versus LangSmith product boundary; TypeScript is outside this matrix | [Manifest](../research/agent-framework-source-manifest.md#ecosystem-manifest), [durability](09-resumable-state-durable-execution-and-replay.md), [deployment](17-background-schedules-servers-and-deployment.md) |
| Pydantic AI | Python team prioritizing typed dependencies/results, validation, and composable agents | Core versus Harness, Evals, durable-system integrations, and Logfire; maturity of the exact surface | [Manifest](../research/agent-framework-source-manifest.md#ecosystem-manifest), [structured results](06-bounded-structured-result-repair.md), [evals](11-evaluation-datasets-and-deterministic-testing.md) |
| OpenAI Agents SDK | Python team seeking a lightweight run loop with tools, guardrails, handoffs, sessions, and tracing | Local versus OpenAI-hosted execution; provider-specific degradation; beta/experimental non-core surfaces | [Manifest](../research/agent-framework-source-manifest.md#ecosystem-manifest), [realtime](18-multimodal-voice-and-realtime-agents.md), [routing](20-provider-routing-fallback-and-retry.md) |
| Google ADK | Organization needing multiple language packages, deterministic workflows, or a Google deployment path | Evidence for the exact language; ADK 2.0 workflow scope; core/container deployment versus managed Agent Runtime | [Manifest](../research/agent-framework-source-manifest.md#ecosystem-manifest), [workflows](02-deterministic-workflow-composition.md), [deployment](17-background-schedules-servers-and-deployment.md) |
| LlamaIndex / LlamaAgents | Python team centered on document/data agents, RAG, retrieval, parsing, or extraction | Open-source framework/workflows versus LlamaCloud services; TypeScript is outside this matrix | [Manifest](../research/agent-framework-source-manifest.md#ecosystem-manifest), [memory/RAG](14-memory-compaction-rag-and-knowledge.md), [deployment](17-background-schedules-servers-and-deployment.md) |
| Microsoft AutoGen | Team prioritizing high-level multi-agent patterns or a lower-level event-driven Python/.NET runtime | GraphFlow/distributed-runtime maturity; Studio's prototyping rather than production boundary | [Manifest](../research/agent-framework-source-manifest.md#ecosystem-manifest), [teams/graphs](19-teams-group-chat-and-agent-graphs.md), [devtools](22-ui-protocols-studio-and-developer-tooling.md) |
| Jidoka | Elixir/OTP team valuing explicit effects, deterministic workflows, resumable review, bounded delegation/handoff, and inspectable evidence | Early-beta status, application-owned infrastructure, and any must-have currently classified as a product gap | [Capability audit](../research/agent-framework-feature-map.md#jidoka-capability-and-proof-audit), [disqualification rule](#do-not-shortlist-jidoka-if) |

## Workload routes

Use these as reading routes, not framework recommendations. Mixed applications
may require more than one route.

| Application archetype | Decisive comparisons | Selection question |
| --- | --- | --- |
| Consequential tools with human review | [Approval](01-resumable-tool-approval.md), [controls](08-controls-guardrails-and-operation-safety.md), [durability](09-resumable-state-durable-execution-and-replay.md), [credentials](21-credential-and-sensitive-data-boundaries.md) | Can the runtime stop before the effect, authenticate/authorize the decision outside the model, resume the exact pending work, and recover safely around the completed-effect/checkpoint race? |
| Durable background or scheduled work | [Durability](09-resumable-state-durable-execution-and-replay.md), [observability](10-observability-tracing-usage-and-inspection.md), [deployment](17-background-schedules-servers-and-deployment.md) | Who owns run identity, claims, checkpoints, queues, schedules, reconnectable events, recovery, and deployment? |
| Document, retrieval, or RAG agent | [Memory/RAG](14-memory-compaction-rag-and-knowledge.md), [tools/catalogs](12-dynamic-tools-catalogs-skills-and-extensions.md), [evals](11-evaluation-datasets-and-deterministic-testing.md) | Are ingestion, indexing, retrieval, reranking, memory, and evaluation first-class, official integrations, hosted services, or application code? |
| Realtime voice or multimodal agent | [Realtime](18-multimodal-voice-and-realtime-agents.md), [streaming/cancellation](07-async-streaming-events-limits-and-cancellation.md), [deployment](17-background-schedules-servers-and-deployment.md) | Does the exact language/provider path support the required transport, interruption, tool, approval, session, and deployment semantics? |
| Multi-agent coordination | [Delegation/handoff](03-bounded-delegation-vs-ownership-handoff.md), [teams/graphs](19-teams-group-chat-and-agent-graphs.md), [remote protocols](13-mcp-breadth-and-remote-agent-protocols.md) | Is the need bounded delegation, future-turn ownership, a deterministic graph, group-chat speaker selection, or a distributed runtime? |
| Managed agent platform | [Deployment](17-background-schedules-servers-and-deployment.md), [observability](10-observability-tracing-usage-and-inspection.md), [evals](11-evaluation-datasets-and-deterministic-testing.md), [Studio/UI](22-ui-protocols-studio-and-developer-tooling.md) | Which server, control plane, trace/eval store, Studio, identity, and deployment capabilities are hosted, self-hostable, or absent? |
| Provider-portable application | [Definitions/models](15-portable-definitions-context-and-model-configuration.md), [routing/fallback](20-provider-routing-fallback-and-retry.md), [browser/sandbox](16-browser-code-execution-and-sandboxes.md), [realtime](18-multimodal-voice-and-realtime-agents.md) | Which core behaviors survive a provider change, and which depend on provider-native tools, transports, sandboxes, or hosted state? |
| Elixir/OTP application | [Feature map](../research/agent-framework-feature-map.md), [proof audit](../research/agent-framework-feature-map.md#jidoka-capability-and-proof-audit), and the relevant semantic briefs | Does Jidoka's explicit effect/control model fit the workload, and are every required product gap and application-owned boundary acceptable? |

## Production cross-examination

Do not compress these answers into one “production-ready” label.

1. **The effect succeeded; the checkpoint did not.** What is persisted, who
   claims recovery, what may replay, and what idempotency or reconciliation
   contract prevents a consequential effect from happening twice? Start with
   [durability and replay](09-resumable-state-durable-execution-and-replay.md).
2. **The process or provider disappeared mid-run.** What terminal evidence,
   cancellation state, pending work, and continuation state survive? Inspect
   [streaming and cancellation](07-async-streaming-events-limits-and-cancellation.md).
3. **The service must be operated for years.** Who owns queues, stores,
   schedules, API, auth, upgrades, scaling, and deployment? Inspect
   [background work and deployment](17-background-schedules-servers-and-deployment.md).
4. **A production incident must be reconstructed.** Which local events, traces,
   usage, exports, datasets, and evals are available without a required hosted
   backend? Inspect [observability](10-observability-tracing-usage-and-inspection.md)
   and [evals](11-evaluation-datasets-and-deterministic-testing.md).
5. **A secret or tenant decision crosses the agent boundary.** Where do raw
   credentials, end-user authority, tenant isolation, redaction, and audit live?
   Tool approval is not authentication or authorization. Inspect
   [credential boundaries](21-credential-and-sensitive-data-boundaries.md).
6. **The model provider or deployment locus changes.** Which features degrade,
   disappear, or move into application ownership? Inspect
   [provider routing](20-provider-routing-fallback-and-retry.md).
7. **The chosen route is not the framework headline.** What stability label
   applies to the exact language, package, integration, hosted service, and
   feature being deployed?

If official documentation cannot answer a decisive question, keep the candidate
in **targeted spike required** rather than converting uncertainty into a score.

## Deployable assembly ownership bill

For every shortlisted framework, assign one owner and one locus to each row.
This exposes the system a team must operate or buy; it is not a cost estimate.

| Component | Record |
| --- | --- |
| Agent/workflow runtime | Package, language, process model, and supported version |
| Run identity and checkpoint store | Persistence system, transaction boundary, claim/recovery owner, replay semantics |
| Queue, background runner, and scheduler | Framework, integration, hosted service, or application infrastructure |
| Tool execution and sandbox | Execution host, filesystem/network boundary, credential path, approval policy |
| HTTP/API and UI protocol | Server owner, reconnect semantics, frontend protocol, operator interface |
| Authentication, authorization, and tenancy | Principal source, policy decision point, tenant isolation, audit owner |
| Observability and evaluation | Local event/trace surface, exporter/backend, datasets, scorers, retention owner |
| Deployment and control plane | Self-hosted or managed runtime, scaling, upgrades, rollback, and regional constraints |

## Evidence receipt and decision worksheet

Capability presence, implementation locus, evidence strength, and product
quality are separate facts.

| Evidence level | Meaning in this roadmap |
| --- | --- |
| Official documentation | A publisher-controlled page documents the behavior within the recorded package/language boundary. This is the baseline for competitor cells. |
| Official runnable example | Publisher-controlled code demonstrates the path, but this research has not necessarily executed it. |
| Locally reproduced | The evaluating team exercised the relevant happy path in its environment. |
| Deterministically asserted | Repeatable assertions verify observable semantics. Jidoka **Proven** currently requires deterministic provider-free evidence at this level, not production evidence. |
| Failure-boundary tested | A targeted test reproduces a decisive crash, replay, cancellation, authorization, isolation, or recovery boundary and asserts the required invariant. Do not infer this level from deterministic happy-path proof. |
| Production evidence | The team has application-specific operational evidence. This comparison corpus does not currently claim this level for any framework. |
| Not researched | The decision dimension was outside the bounded review or no adequate evidence was established. It is not proof of absence. |

Copy this row for every must-have:

| Required observable behavior | Atomic IDs | Acceptable locus | Required maturity | Required evidence | Observed evidence | Local spike/failure result | Decision and owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| _Describe behavior, not a marketing label_ | _IDs_ | _C / I / H / A_ | _Stable / preview acceptable / other_ | _Documentation / reproduced / deterministic / failure-tested / production_ | _Current level and links_ | _Pass, fail, or not run_ | _Eligible, spike, or disqualified_ |

Evidence below the required level places a candidate in **targeted spike
required**, even when official documentation establishes feature presence.

## Do not shortlist Jidoka if

For every must-have, look up its atomic ID in the
[Jidoka capability and proof audit](../research/agent-framework-feature-map.md#jidoka-capability-and-proof-audit):

- **Product gap** or **Excluded** disqualifies Jidoka unless the team explicitly
  changes the requirement or accepts ownership of a separately designed
  replacement.
- **App-managed boundary** requires a named application/infrastructure owner and
  an accepted operating design.
- **Proof needed** or **Partial proof** does not automatically disqualify Jidoka,
  but it remains **targeted spike required** until the buyer's required evidence
  level is met.

The audit is authoritative; do not copy its current ID inventory into a buyer
decision record. Follow each ID to its comparison brief for the semantic
contract and current boundary.

## Selection unknown record

The complete global research-scope boundary is owned by the
[source manifest](../research/agent-framework-source-manifest.md#selection-facts-boundary).
For a particular decision, copy one row per shortlist-reversing unknown. Do not
infer a favorable answer from feature breadth or official positioning.

| Candidate | Unknown | Current status | Source requirement | Acceptance threshold | Owner | Decision date | Bucket impact | Resolution |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| _Framework/assembly_ | _Fact that could reverse the shortlist_ | _Not researched / stale / conflicting_ | _Required primary source or local experiment_ | _Pass/fail condition_ | _Name/team_ | _YYYY-MM-DD_ | _Spike or disqualify if unresolved_ | _Open or evidence link_ |
