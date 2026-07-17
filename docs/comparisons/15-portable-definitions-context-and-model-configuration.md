# Use Case 15: Portable Definitions, Context, and Model Configuration

**Roadmap status:** Docs ready; dynamic instructions/model routing are partial gaps.

## Comparison contract

An agent has an inspectable definition, accepts trusted typed runtime context
without leaking it to the model by default, can be represented as portable data
where safe, and selects/configures models through a provider-neutral boundary.

Atomic features: `A01` code authoring, `A02` data definitions, `A03` dynamic
instructions, `A04` runtime context, `A05` provider abstraction, and `A06`
routing/fallback.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented surface | Important boundary |
| --- | --- | --- |
| Mastra | Code/file-based agents, dynamic request context, provider/model routing, per-call instructions/models/tools, and a hosted Agent Builder. | Agent Builder configuration and runtime files are not a framework-neutral portable interchange format. |
| LangChain / LangGraph | `create_agent`, middleware-driven prompts/model selection, typed runtime context/state, provider integrations, and hosted Agent Builder/Fleet surfaces. | Hosted configurations are distinct from OSS graph code and are not cross-framework portable specs. |
| Pydantic AI | Generic typed `Agent[DepsT, OutputT]`, dynamic instructions, YAML/JSON Agent Specs, many providers, custom models, and `FallbackModel`. | Data specs can reference trusted code/provider configuration; serialization does not remove that trust boundary. |
| OpenAI Agents SDK | Agent objects support dynamic instructions/prompts, arbitrary local context, per-agent/per-run models, OpenAI-compatible providers, and adapters. | No general declarative portable agent-spec format was established; Python objects/callbacks remain code. |
| Google ADK | Code-first agents, Agent Config, runtime context, `BaseLlm`, model routing, and many model integrations across several languages. | Configuration and feature parity are language/version specific. |
| LlamaIndex | Code-first agents, prompt/config hooks, custom LLM protocol, and a broad integration catalog. | No current portable declarative agent-spec contract was established; routing/fallback is application composition. |
| AutoGen | Code-first/custom agents, component JSON dump/load for agents/teams/models/memory, custom model protocols, and extension clients. | Custom routing functions may not serialize; component configs are AutoGen-specific. |
| Jidoka | Spark DSL and immutable `Agent.Spec`, Zoi context schema, runtime `Jidoka.Context`, provider-neutral LLM capability/model refs, and versioned JSON/YAML import/export registries. | Instructions are primarily definition-time; no first-class dynamic prompt callback or model routing/fallback policy exists. Imported registries remain trusted application code. |

## Jidoka proof target

Round-trip a DSL agent through projection and JSON/YAML import/export, prove
context validation and public/runtime separation, and run the same plan against
two injected model capabilities. Keep dynamic instructions and fallback out of
the proof until public contracts exist.

## Official sources

- [Mastra agents](https://mastra.ai/docs/agents/overview), [request context](https://mastra.ai/docs/server/request-context), [models](https://mastra.ai/models)
- [LangChain agents](https://docs.langchain.com/oss/python/langchain/agents), [models](https://docs.langchain.com/oss/python/langchain/models)
- [Pydantic AI Agent Specs](https://pydantic.dev/docs/ai/core-concepts/agent-spec/), [dependencies](https://pydantic.dev/docs/ai/core-concepts/dependencies/), [models](https://pydantic.dev/docs/ai/models/overview/)
- [OpenAI Agents SDK agents](https://openai.github.io/openai-agents-python/agents/), [context](https://openai.github.io/openai-agents-python/context/), [models](https://openai.github.io/openai-agents-python/models/)
- [Google ADK agents](https://adk.dev/agents/), [models](https://adk.dev/agents/models/)
- [LlamaIndex agents](https://developers.llamaindex.ai/python/framework/module_guides/deploying/agents/)
- [AutoGen component serialization](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/serialize-components.html)
- [Jidoka agent spec](../../guides/agent-spec-contract.md), [import/export](../../guides/import-json-yaml.md)
