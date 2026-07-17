# Agent Framework Comparison Roadmap

This directory is the living, use-case-level roadmap for demonstrating where
Jidoka matches, partially matches, or intentionally differs from other agent
frameworks.

## Choose how to use this corpus

| Goal | Start here | What the route answers |
| --- | --- | --- |
| Select an agent framework | [Agent Framework Selection Guide](framework-selection-guide.md) | Hard constraints, workload routes, ecosystem orientation, production gates, ownership, evidence strength, and explicit unknowns |
| Plan Jidoka parity work | [Jidoka roadmap status model](#jidoka-roadmap-status-model), [comparison catalog](#comparison-catalog), and [priority score table](../research/agent-framework-feature-map.md#priority-scoring) | Which Jidoka behaviors are proven, need proof, or require product work, and what to showcase next |
| Audit a specific behavior | [Comparison catalog](#comparison-catalog) and [atomic feature map](../research/agent-framework-feature-map.md) | Observable semantics, capability locus, qualifiers, official sources, Jidoka boundaries, and available executable evidence |
| Refresh the research | [Source manifest](../research/agent-framework-source-manifest.md) and [maintenance rules](#maintenance-rules) | Review boundaries, provenance, bounded negative findings, and invalidation rules |

The detailed feature map is an evidence appendix, not a buyer scorecard.
Feature breadth does not establish production reliability, API quality,
performance, support, security, portability, or operating cost. Competitor
cells record official-documentation findings; Jidoka **Proven** requires
deterministic executable evidence. Neither is production evidence.

The canonical atomic feature inventory and consolidated matrix live in
[`../research/agent-framework-feature-map.md`](../research/agent-framework-feature-map.md).
The documentation-tree review boundary lives in
[`../research/agent-framework-source-manifest.md`](../research/agent-framework-source-manifest.md).

## Jidoka roadmap status model

| Status | Meaning |
| --- | --- |
| Proven | A deterministic, provider-free parity test exercises the public Jidoka contract. |
| Partial proof | A deterministic test characterizes a materially narrower Jidoka contract. |
| Docs ready | The comparison contract and official-source review are complete; no parity proof has been built yet. |
| Product gap | The comparison is researched, but Jidoka lacks a required public capability. |
| Excluded | The feature is intentionally outside Jidoka's current strategy. |

Capability and proof status are deliberately separate. A shipped API can still
need a better showcase, and a documented competitor feature can remain a
Jidoka product gap.

The feature map assigns each atomic ID one primary semantic contract. An ID may
also appear in additional catalog rows when another use case supplies related
context or executable evidence. The feature-level capability/proof audit is
authoritative; catalog statuses describe whole comparison briefs.

## Comparison catalog

Reviewed against current official documentation on 2026-07-16.

| No. | Comparison | Atomic feature IDs | Status |
| --- | --- | --- | --- |
| 01 | [Resumable tool approval](01-resumable-tool-approval.md) | `T05`, `G04`, `E06` | Proven |
| 02 | [Deterministic workflow composition](02-deterministic-workflow-composition.md) | `E03`, `W01`-`W03`, `W05`, `W06` | Proven |
| 03 | [Bounded delegation versus ownership handoff](03-bounded-delegation-vs-ownership-handoff.md) | `M01`, `M02`, `M05` | Proven |
| 04 | [MCP client tool consumption](04-mcp-client-tool-consumption.md) | `T07` | Proven |
| 05 | [Session history versus scoped memory continuity](05-session-history-vs-scoped-memory-continuity.md) | `S01`, `S03`, `S04`, `S06` | Partial proof |
| 06 | [Bounded structured-result repair](06-bounded-structured-result-repair.md) | `A07`, `A08` | Proven |
| 07 | [Async streaming, events, limits, and cancellation](07-async-streaming-events-limits-and-cancellation.md) | `E01`-`E05`, `O01` | Docs ready; cancellation gap |
| 08 | [Controls, guardrails, and operation safety](08-controls-guardrails-and-operation-safety.md) | `G01`-`G04`, `T06` | Docs ready |
| 09 | [Resumable state, durable execution, and replay](09-resumable-state-durable-execution-and-replay.md) | `E06`-`E08`, `S02` | Docs ready; durability gap |
| 10 | [Observability, tracing, usage, and inspection](10-observability-tracing-usage-and-inspection.md) | `O01`-`O04` | Docs ready; export gap |
| 11 | [Evaluation, datasets, and deterministic testing](11-evaluation-datasets-and-deterministic-testing.md) | `O05`-`O08`, `R07` | Docs ready; eval-platform gaps |
| 12 | [Dynamic tools, catalogs, skills, and extensions](12-dynamic-tools-catalogs-skills-and-extensions.md) | `T01`-`T04` | Docs ready |
| 13 | [MCP breadth and remote-agent protocols](13-mcp-breadth-and-remote-agent-protocols.md) | `T08`-`T10`, `M06` | Product gap |
| 14 | [Memory, compaction, RAG, and knowledge](14-memory-compaction-rag-and-knowledge.md) | `S03`-`S07`, `T13` | Docs ready; compaction/RAG gaps |
| 15 | [Portable definitions, context, and model configuration](15-portable-definitions-context-and-model-configuration.md) | `A01`-`A06` | Docs ready; routing gap |
| 16 | [Browser, code execution, and sandboxes](16-browser-code-execution-and-sandboxes.md) | `T11`, `T12`, `G06` | Docs ready; sandbox gap |
| 17 | [Background work, schedules, servers, and deployment](17-background-schedules-servers-and-deployment.md) | `W07`, `W08`, `R01`-`R03` | Product gap beyond process hosting |
| 18 | [Multimodal, voice, and realtime agents](18-multimodal-voice-and-realtime-agents.md) | `A09`, `R06` | Product gap |
| 19 | [Teams, group chat, and agent graphs](19-teams-group-chat-and-agent-graphs.md) | `M03`, `M04`, `M06`, `W04` | Docs ready; team-runtime gap |
| 20 | [Provider routing, fallback, and retry](20-provider-routing-fallback-and-retry.md) | `A05`, `A06` | Product gap beyond provider abstraction |
| 21 | [Credential and sensitive-data boundaries](21-credential-and-sensitive-data-boundaries.md) | `T14`, `G05`, `G06` | Docs ready; credential-broker gap |
| 22 | [UI protocols, Studio, and developer tooling](22-ui-protocols-studio-and-developer-tooling.md) | `R04`, `R05`, `O02` | Docs ready; Studio/protocol gaps |

## Recommended showcase order

The [priority score table](../research/agent-framework-feature-map.md#priority-scoring)
is the canonical ordering for unproven comparisons. The next proof wave follows
that order, using table order to break ties:

1. async streaming and lifecycle events (`07`);
2. input/output/operation controls (`08`);
3. local trace, redaction, usage, and debug inspection (`10`);
4. governed catalog discovery and skill-scoped tools (`12`);
5. portable definitions, context, and model configuration (`15`);
6. snapshot, session, and data-only replay boundaries (`09`); and
7. deterministic eval cases and provider-free tests (`11`).

If a dependency or strategy decision overrides this score-based order, record
the reason in both this list and the score table rather than allowing two
independent priority lists to drift.

The remaining documents should guide product prioritization before example
work. In particular, durable crash recovery, MCP server/protocol breadth,
compaction/RAG, sandboxed execution, scheduling/deployment, realtime voice,
general team runtimes, provider fallback, credential brokering, and a Studio
surface must not be presented as parity until their product gaps are resolved.

## Maintenance rules

- Use official, publisher-controlled documentation for framework claims.
- Date each review and qualify preview, beta, hosted, paid, language-specific,
  provider-native, and application-managed behavior.
- Treat "Not established" as a bounded research result, never as proof that a
  framework cannot support the feature.
- Split semantic collisions into distinct feature IDs before adding a row.
- Before committing a roadmap refresh, verify that every matrix ID appears
  exactly once in the Jidoka capability/proof audit, that its linked brief
  declares the ID, and that the catalog indexes that brief.
- Validate local Markdown targets on every change. Recheck external official
  sources during each affected ecosystem refresh; HTTP reachability alone does
  not prove that a page still supports the adjacent claim.
- Do not promote a comparison to Proven from model-authored prose. Require a
  deterministic assertion over public results, operations, journals, events,
  snapshots, memory, ownership, traces, or stable projections.
- When an official page moves or changes materially, mark the dependent claim
  for revalidation before changing scores or public parity claims.

## Roadmap maintenance backlog

This research wave is Markdown-only. The following integrity work is recorded
for a later implementation change:

1. Add a provider-free ExUnit test or Mix task in normal CI that verifies the
   73-ID matrix, valid cell codes, exactly one Jidoka audit disposition per ID,
   catalog/brief coverage, required headings/dates, and local link targets.
2. Add a scheduled external-link check that retries transient publisher errors,
   distinguishes rate limiting or bot blocking from missing pages, and reports
   the comparison document that depends on each failed URL.
3. Keep semantic claim and qualifier revalidation as a human research step;
   link reachability cannot prove that a page still supports an adjacent claim.
