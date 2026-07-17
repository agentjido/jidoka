# Use Case 07: Async Streaming, Events, Limits, and Cancellation

**Roadmap status:** Docs ready; Jidoka cancellation is a product gap.

## Comparison contract

A caller starts an agent asynchronously, consumes token and semantic lifecycle
events, observes tool progress in order, enforces explicit run budgets, and can
cancel outstanding work with a typed terminal state that cannot later be
mistaken for success.

Atomic features: `E01` synchronous/async runs, `E02` streaming, `E03` parallel
tool calls, `E04` run limits, `E05` cancellation, and `O01` lifecycle events.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented surface | Important boundary |
| --- | --- | --- |
| Mastra | `generate()`/`stream()` expose tokens, steps, tool calls/results, and usage. Background tasks add progress, filtered reconnectable streams, cancellation, suspend, and resume. | Background-task cancellation belongs to the long-running-agent surface, not every ordinary in-process call. |
| LangChain / LangGraph | Agents and graphs stream values, updates, messages, custom events, checkpoints, tasks, and debug data. LangGraph fault policies bound retries/timeouts; Agent Server owns durable run cancellation. | OSS task cancellation and hosted Agent Server cancellation have different persistence guarantees. |
| Pydantic AI | Sync/async runs stream text, partial structured data, raw agent/tool events, and graph nodes. Usage limits bound requests, tokens, tools, and concurrency. | Cancellation is ordinary async/application control; a framework-owned typed persisted cancellation result was not established. |
| OpenAI Agents SDK | Sync, async, streamed, and batched runners expose raw response events, semantic run items, nested-agent events, cancellation, and `max_turns`. | Provider stream cancellation and durable integration cancellation may have different cleanup/side-effect guarantees. |
| Google ADK | Runner events cover agent/model/tool activity; runtime APIs support streaming and canceling invocations. | Capability and event parity varies by SDK language and selected runtime. |
| LlamaIndex / LlamaAgents | Workflows stream typed custom events and run concurrent workers; the workflow server adds async runs, status, streaming, and cancellation. | Server cancellation is an official package surface, not the same as the core in-process workflow handler. |
| AutoGen | `run_stream()` yields agent/model/tool events, token chunks, and a terminal result; Core uses cancellation tokens through message/tool execution. | Cancellation semantics depend on each agent/tool honoring the token and do not constitute durable rollback. |
| Jidoka | `chat_async/3`, `stream/2`, and `await/2` expose request-scoped events; turn controls bound loops/timeouts and operation batches preserve observation order. | No public cancellation API currently produces a typed canceled `Turn.Result` or terminal cancellation event. |

## Jidoka proof target

A future parity test should prove token deltas, semantic event order, one
terminal event, exact turn/timeout limits, ordered observations from deliberately
out-of-order parallel tools, and cleanup of the request handle. Cancellation
must remain a blocked assertion until a public contract exists.

## Official sources

- [Mastra agents](https://mastra.ai/docs/agents/overview), [background tasks](https://mastra.ai/docs/long-running-agents/background-tasks)
- [LangChain streaming](https://docs.langchain.com/oss/python/langchain/streaming), [LangGraph streaming](https://docs.langchain.com/oss/python/langgraph/streaming)
- [Pydantic AI agents and usage limits](https://pydantic.dev/docs/ai/core-concepts/agent/)
- [OpenAI Agents SDK streaming](https://openai.github.io/openai-agents-python/streaming/), [running agents](https://openai.github.io/openai-agents-python/running_agents/)
- [Google ADK runtime](https://adk.dev/runtime/), [cancel runs](https://adk.dev/runtime/cancel/)
- [LlamaAgents workflow deployment](https://developers.llamaindex.ai/python/llamaagents/workflows/deployment/)
- [AutoGen agents](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/agents.html)
- [Jidoka streaming guide](../../guides/streaming.md)
