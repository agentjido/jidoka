# Use Case 20: Provider Routing, Fallback, and Retry

**Roadmap status:** Product gap beyond model/provider abstraction.

## Comparison contract

An application can select a model dynamically from trusted state, fall back
across providers after classified failures, retry transient model calls to an
explicit bound with backoff, and record which model/provider handled each
attempt without duplicating tool effects.

Atomic features: `A05` provider abstraction and `A06` routing/fallback/retry.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented model surface | Important boundary |
| --- | --- | --- |
| Mastra | Unified `provider/model` routing, provider catalog/gateways, per-call dynamic model configuration, and long-running-agent model modes. | Generic ordered fallback semantics are less explicit than model addressing/routing. |
| LangChain | Broad provider integrations, model profiles, dynamic model middleware, model fallback/retry middleware, rate limiting, and caching. | Provider adapters and LangSmith gateway/hosted configuration are separate loci. |
| Pydantic AI | Broad model/provider abstraction, custom models, `FallbackModel`, HTTP retry, capabilities, and provider profiles. | Model fallback/retry is different from output-validation or tool retry. |
| OpenAI Agents SDK | Per-agent/per-run models, custom providers and adapters, plus bounded `ModelRetrySettings` with backoff/jitter/classifiers. | Ordered cross-provider fallback is application/provider composition; model retry must not replay completed tools. |
| Google ADK | Gemini plus LiteLLM/custom `BaseLlm`, model routing, and provider integrations. | Routing and provider breadth vary by language/provider. |
| LlamaIndex | Custom LLM protocol and many model integrations. | A first-class framework fallback/routing policy was not established; applications compose models. |
| AutoGen | `ChatCompletionClient`, extension clients, caching, and Semantic Kernel integration. | Fallback/routing remains application/model-client composition. |
| Jidoka | `LLMDB.Model` references and injected ReqLLM-compatible capabilities keep the turn provider-neutral and testable. | No public dynamic routing policy, fallback list, transient-error classifier, model-call retry/backoff, circuit breaker, or per-attempt model audit. |

## Roadmap questions

The design must keep model retries outside completed tool effects and distinguish
provider transport retry, rate-limit retry, fallback, output repair, tool retry,
and whole-turn retry. Attempt events should expose model/provider, classifier,
delay policy, usage, and terminal failure without exposing credentials.

## Official sources

- [Mastra models](https://mastra.ai/models), [request context](https://mastra.ai/docs/server/request-context)
- [LangChain models](https://docs.langchain.com/oss/python/langchain/models), [middleware](https://docs.langchain.com/oss/python/langchain/middleware/built-in)
- [Pydantic AI models](https://pydantic.dev/docs/ai/models/overview/), [fallback model API](https://pydantic.dev/docs/ai/api/models/fallback/)
- [OpenAI Agents SDK models](https://openai.github.io/openai-agents-python/models/)
- [Google ADK models](https://adk.dev/agents/models/)
- [LlamaIndex models](https://developers.llamaindex.ai/python/framework/module_guides/models/)
- [AutoGen models](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/models.html)
- [Jidoka configuration](../../guides/configuration.md), [runtime capabilities](../../guides/runtime-capabilities-internals.md)
