# Agent Framework Source Manifest

This manifest records the bounded official-documentation review used by the
Jidoka comparison roadmap. The review cutoff is **2026-07-16**.

Claim-level links live beside the comparison they support in
[`../comparisons/`](../comparisons/README.md). This file records discovery
roots, product boundaries, review coverage, and freshness so a future refresh
can reproduce the research rather than treating one date as a permanent claim.
Prospective adopters should begin with the
[Agent Framework Selection Guide](../comparisons/framework-selection-guide.md).

## Evidence policy

Only publisher-controlled documentation and project-controlled API references
are used for framework claims. Tutorials, examples, and integration catalogs
are valid evidence when the framework publishes them, but their implementation
locus remains visible.

| Locus | Meaning |
| --- | --- |
| Core | Implemented by the open-source package or its documented runtime. |
| Official integration | Maintained companion package, adapter, or provider integration. |
| Hosted | Vendor-managed product or control plane; self-hosted variants remain qualified. |
| App-managed | Officially documented composition pattern whose persistence, policy, or runtime belongs to application code. |
| Not established | Not found within the bounded official-doc review. It is not a claim of impossibility. |

Preview, beta, experimental, provider-specific, language-limited, and local-dev
features retain those qualifiers even when their locus is Core.

## Evidence granularity

The maintained provenance unit is one ecosystem row inside one comparison
brief. The brief's atomic IDs name the claims being compared, its ecosystem row
states the supported surface and boundary, and its same-ecosystem source line
collectively supports that row. The consolidated matrix points to the primary
brief for each ID.

This deliberately avoids duplicating every source into a 73-by-7 claim table.
If any source changes materially, revalidate the entire ecosystem row in that
brief and every atomic ID declared by the brief; do not update only one matrix
cell from an ambiguous source list. Dates below record ecosystem-wide navigation
review, while each brief records its claim-row review date.

## Selection-facts boundary

This review systematically covers feature semantics, implementation locus,
material maturity/language/provider qualifiers, official positioning, and the
package/language boundary named below. It does **not** systematically compare
package versions/release lines unless a row explicitly says so, license
compatibility, governance, release health, maintenance depth, commercial
support, community quality, pricing, compliance, performance, production
reliability, migration cost, or total operating cost.

Feature-level Hosted loci and documented product boundaries **are** researched.
Whether a complete production assembly requires a hosted service—and its
pricing, data residency, contractual terms, and operating consequences—is not
systematically compared.

Those adoption facts must use a separate dated methodology and primary sources.
Until that work exists, record them as **Not researched** rather than inferring
an answer from feature breadth, a project's reputation, or a hosted product's
availability.

## Ecosystem manifest

| Ecosystem | Package/language boundary | Docs channel and access | Discovery roots | Reviewed on |
| --- | --- | --- | --- | --- |
| Mastra | Mastra TypeScript framework, official packages, Server/Studio, and Mastra Platform where separately labeled | Current public docs/reference/models/guides | [docs index](https://mastra.ai/llms.txt), [docs](https://mastra.ai/docs), [reference](https://mastra.ai/reference), [models](https://mastra.ai/models), [guides](https://mastra.ai/guides) | 2026-07-16 |
| LangChain / LangGraph | Python LangChain and LangGraph OSS, Deep Agents official harness, official integrations, and LangSmith where separately labeled; official TypeScript packages are outside the current matrix boundary | Current public OSS and LangSmith docs | [LangChain](https://docs.langchain.com/oss/python/langchain/overview), [LangGraph](https://docs.langchain.com/oss/python/langgraph/overview), [Deep Agents](https://docs.langchain.com/oss/python/deepagents/overview), [integrations](https://docs.langchain.com/oss/python/integrations/providers), [docs index](https://docs.langchain.com/llms.txt) | 2026-07-16 |
| Pydantic AI | Python Pydantic AI core, Pydantic Graph, Pydantic AI Harness, Pydantic Evals, official durable/UI integrations, and Logfire where separately labeled | Current public docs | [docs index](https://ai.pydantic.dev/llms.txt), [core](https://pydantic.dev/docs/ai/overview/), [Harness](https://pydantic.dev/docs/ai/harness/), [Graph](https://pydantic.dev/docs/ai/graph/graph/), [Evals](https://pydantic.dev/docs/ai/evals/evals/) | 2026-07-16 |
| OpenAI Agents SDK | OpenAI Agents SDK for Python plus official SDK integrations; OpenAI-hosted tools, traces, sandboxes, vector stores, and evals remain Hosted | Current public SDK and OpenAI developer docs | [docs index](https://openai.github.io/openai-agents-python/llms.txt), [SDK docs](https://openai.github.io/openai-agents-python/), [developer docs](https://developers.openai.com/) | 2026-07-16 |
| Google ADK | ADK core across Python, TypeScript, Go, Java, and Kotlin where documented; language gaps are retained; Google Cloud runtimes remain Hosted | Current public ADK docs, API reference, integrations, and deployment docs | [docs index](https://adk.dev/llms.txt), [docs](https://adk.dev/), [API reference](https://adk.dev/api-reference/), [integrations](https://adk.dev/integrations/), [ADK 2.0](https://adk.dev/2.0/), [deployment](https://adk.dev/deploy/) | 2026-07-16 |
| LlamaIndex / LlamaAgents | Python LlamaIndex framework, open-source LlamaAgents Workflows, official workflow packages, and LlamaAgents Cloud where separately labeled; official TypeScript framework packages are outside the current matrix boundary | Current public framework, workflow, and cloud docs | [docs index](https://developers.llamaindex.ai/llms.txt), [framework](https://developers.llamaindex.ai/python/framework/), [LlamaAgents](https://developers.llamaindex.ai/python/llamaagents/overview/), [workflows](https://developers.llamaindex.ai/python/llamaagents/workflows/), [Agent Builder](https://developers.llamaindex.ai/python/llamaagents/cloud/builder/) | 2026-07-16 |
| Microsoft AutoGen | Python AgentChat plus Python/.NET Core interoperability, `autogen-ext`, experimental GraphFlow/distributed runtime, and AutoGen Studio where separately labeled | Stable public user guides and API reference; dev pages used only when stable navigation points to an experimental feature | [stable docs](https://microsoft.github.io/autogen/stable/), [AgentChat](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/index.html), [Core](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/index.html), [extensions](https://microsoft.github.io/autogen/stable/user-guide/extensions-user-guide/index.html), [Studio](https://microsoft.github.io/autogen/stable/user-guide/autogenstudio-user-guide/index.html), [API](https://microsoft.github.io/autogen/stable/reference/index.html) | 2026-07-16 |
| Jidoka | This repository's Elixir/OTP V2 public facade, guides, stable projections, tests, and examples | Local source at the current branch revision | [`lib/jidoka.ex`](../../lib/jidoka.ex), [`guides/`](../../guides), [`test/`](../../test) | 2026-07-16 local audit |

## Navigation coverage

Every ecosystem was reviewed against the same taxonomy. A check means the
navigation branch was reviewed, not that every framework supports the feature.

| Taxonomy branch | Mastra | LangChain | Pydantic AI | OpenAI SDK | ADK | LlamaIndex | AutoGen |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Agent authoring, models, context, structured I/O | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Run loop, streaming, limits, cancellation | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Workflow/graph control flow and retry | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Checkpoints, resume, replay, durable execution | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Tools, dynamic discovery, approvals, protocols | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Multi-agent delegation, handoff, teams, runtime | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Sessions, memory, compaction, RAG | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Guardrails, security, sandbox boundaries | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Events, tracing, usage, observability | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Evals, datasets, experiments, test doubles | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Server, deployment, Studio/UI/devtools | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Browser, code execution, multimodal, voice | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

## Product-boundary notes

- Mastra Server and local Studio are official runtime surfaces; Mastra Platform
  storage and management remain hosted when the docs require that service.
- LangGraph checkpointing is OSS Core. LangSmith tracing, evaluation, Studio,
  Agent Server, cron, A2A, MCP server, and deployment are hosted/self-host
  platform surfaces, not LangGraph-core checkmarks.
- Pydantic AI Harness and Pydantic Evals are official packages but are not
  silently attributed to the minimal `pydantic-ai` run loop. Logfire is hosted.
- OpenAI hosted tools, vector stores, trace dashboards, trace grading, managed
  containers, and provider execution are distinct from locally executed SDK
  adapters.
- ADK's core resume contract is at-least-once; DBOS, Dapr, Restate, and
  Temporal provide stronger official-integration durability. Agent Runtime is
  hosted.
- LlamaIndex core context serialization is not automatic durable checkpoint
  storage. DBOS, the workflow server, and LlamaAgents Cloud are separate loci.
- AutoGen AgentChat state serialization is not a durable workflow engine.
  `autogen-ext` model/tool/runtime implementations and Studio are kept separate
  from Core.

## Bounded not-established register

These are useful negative research results as of the cutoff date. They must be
revalidated before being repeated after documentation changes.

| Ecosystem | Not established in the reviewed boundary |
| --- | --- |
| Mastra | A named durable future-turn ownership-handoff primitive; LangGraph-style pending-write recovery; a documented deterministic task-replay discipline. |
| LangChain / LangGraph | OSS-core MCP server or A2A client abstraction; core-owned browser or provider-neutral voice runtime; Mastra-style durable judged goals. |
| Pydantic AI | Bidirectional realtime/telephony runtime; first-party GUI/browser automation; package-owned deployment control plane; full graph-state restore from Harness step persistence. |
| OpenAI Agents SDK | Native declarative graph engine; SDK-owned MCP server; generic embedding/vector-store abstraction; bounded model-mediated result repair; general application server/deployer. |
| Google ADK | Model-agnostic realtime voice runtime; generic browser agent; first-class MCP server abstraction independent of an MCP SDK recipe; exactly-once effects in core resume; equal features across every language. |
| LlamaIndex / LlamaAgents | First-class dynamic per-turn tool availability; automatic core workflow checkpointer; A2A; dedicated agent-trajectory eval harness; native realtime voice or browser agent; unified guardrail policy API. |
| AutoGen | Workflow-level retry policy; native durable workflow/checkpoint engine; MCP server; A2A; integrated general trajectory/eval suite; production agent-server/deployment product; production-grade Studio hosting. |

## Refresh procedure

1. Re-open the ecosystem discovery roots and compare their relevant navigation
   branches with this manifest.
2. Revisit every claim-specific link in the affected comparison documents.
3. Preserve the old feature ID when semantics are unchanged. If a feature must
   split or merge, deprecate the old ID and name its successors.
4. Mark moved, unreachable, contradictory, or materially changed sources as
   needing revalidation before updating the consolidated matrix.
5. Refresh only the affected ecosystem/date. Do not advance the whole manifest
   because one framework was checked.
