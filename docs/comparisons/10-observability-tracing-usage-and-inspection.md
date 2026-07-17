# Use Case 10: Observability, Tracing, Usage, and Inspection

**Roadmap status:** Docs ready; Jidoka OpenTelemetry export is partial.

## Comparison contract

A developer can inspect the exact agent contract before execution, follow
model/tool/workflow lifecycle evidence, account for usage, redact sensitive
fields, persist or export traces, and debug a completed or interrupted request.

Atomic features: `O01` events, `O02` inspection/preflight, `O03` traces/export,
and `O04` usage/cost accounting.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented surface | Important boundary |
| --- | --- | --- |
| Mastra | Hierarchical agent/workflow/tool/model/processor spans, structured logs, duration/token/cost metrics, feedback, sampling, Studio, OTel, and many exporters. | Platform storage/UI and external exporters are distinct from core trace generation. |
| LangChain / LangGraph | Stream/debug modes expose state activity; LangSmith adds automatic and framework-neutral tracing, dashboards, alerts, Studio, and OTel export. | Most trace storage/analysis is LangSmith hosted or self-hosted, not LangGraph core. |
| Pydantic AI | OTel-native instrumentation emits model/tool spans, metrics, and usage to any compatible backend; Logfire adds hosted inspection. | Logfire is hosted, while instrumentation/export is core. |
| OpenAI Agents SDK | Built-in traces cover runner, agent, model, function, guardrail, handoff, and audio spans; custom processors can export elsewhere. | The default dashboard is hosted and sensitive-data capture must be configured deliberately. |
| Google ADK | Runtime events plus OpenTelemetry traces/logs/metrics and Cloud Trace integrations; local UI exposes events/state/tool/model traces. | Language/runtime feature support varies. |
| LlamaIndex / LlamaAgents | Core instrumentation and workflow step-state events combine with official OTel, Phoenix, Langfuse, and Opik integrations. | Backends are integrations; the core dispatcher is the stable local hook. |
| AutoGen | Structured event logging and OTel semantic spans cover agent runtime, model, and tools. | A full hosted observability/evaluation platform is not part of AutoGen core. |
| Jidoka | Stable inspection/preflight/projection APIs, sequence-stable event timelines, trace sampling/redaction, caller-provided sinks, usage, request debug summaries, and data-only replay. | Partial: no official OTel span/export adapter currently maps this evidence into an external observability backend. |

## Jidoka proof target

Preflight must make no capability call. A real provider-free tool turn should
then prove exact prompt/tool/result evidence, usage totals, stable event order,
sampling, redaction, sink delivery, completed-request debug data, and replay
diagnostics. Keep OTel export labeled as a product gap.

## Official sources

- [Mastra observability](https://mastra.ai/docs/observability/overview), [integrations](https://mastra.ai/docs/observability/integrations/overview)
- [LangChain observability](https://docs.langchain.com/oss/python/langchain/observability), [LangSmith observability](https://docs.langchain.com/langsmith/observability)
- [Pydantic AI observability](https://pydantic.dev/docs/ai/integrations/logfire/)
- [OpenAI Agents SDK tracing](https://openai.github.io/openai-agents-python/tracing/)
- [Google ADK observability](https://adk.dev/observability/)
- [LlamaAgents workflow observability](https://developers.llamaindex.ai/python/llamaagents/workflows/observability/)
- [AutoGen tracing](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tracing.html)
- [Jidoka inspection](../../guides/inspection-and-preflight.md), [tracing and events](../../guides/tracing-and-events.md)
