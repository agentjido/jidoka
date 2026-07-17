# Use Case 12: Dynamic Tools, Catalogs, Skills, and Extensions

**Roadmap status:** Docs ready.

## Comparison contract

An agent derives callable tool schemas from typed host definitions, starts with
a small prompt surface, changes tool availability from trusted runtime context,
progressively discovers large catalogs, composes reusable tool/instruction
bundles, and executes only a bounded allowlisted set.

Atomic features: `T01` schema-derived function/action tools, `T02` dynamic
availability, `T03` progressive discovery, and `T04`
skills/capabilities/toolsets/extensions.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented surface | Important boundary |
| --- | --- | --- |
| Mastra | `createTool` uses validated input/output schemas; tool selection, request-context configuration, `ToolSearchProcessor`, skills, AgentController modes, MCP registries, and workspace skills extend that base. | Dynamic discovery must still enforce execution policy and credential scope outside model choice. |
| LangChain / LangGraph | Typed functions/coroutines become tools; middleware filters or registers them at runtime; Deep Agents adds skills, subagents, memory, context offload, and sandbox backends. | Skills are an application/harness pattern; LangSmith/Fleet catalogs are hosted surfaces. |
| Pydantic AI | Function signatures and docstrings produce validated schemas; toolsets aggregate/filter/prefix/rename/transform tools; `prepare` mutates or hides definitions; capabilities bundle tools/instructions/hooks. | Generic semantic catalog ranking is not the same thing as toolset composition. |
| OpenAI Agents SDK | `function_tool` derives a schema from a Python function; `is_enabled` controls tools per run; hosted tool search and deferred namespaces load large tool surfaces; sandbox agents add skills. | Hosted tool search executes in OpenAI infrastructure and is a different locus from local function tools. |
| Google ADK | Function tools inspect typed functions; stateful toolsets filter using readonly context, identity, and permissions; Skills, plugins, Agent Search, and API registries extend discovery. | Registry integrations and hosted discovery are not core tool execution. |
| LlamaIndex | `FunctionTool` derives metadata from sync/async functions; ToolSpec bundles and query engines compose richer tool surfaces. | A first-class dynamic per-turn availability API was not established; applications assemble tool lists. |
| AutoGen | `FunctionTool` wraps typed functions; Workbench shares state/resources and discovers tools at model-call iterations; MCP and extensions add remote/provider capabilities. | Workbench discovery does not by itself implement semantic ranking or an authorization broker. |
| Jidoka | Operation sources compile typed action definitions and their schemas; skills narrow allowed tools; governed catalogs expose query/describe/execute over hidden read-only actions. | Tool source compilation is trusted host code. Catalog discovery does not authorize arbitrary actions or reveal raw credentials. |

## Jidoka proof target

Show that an action's public input schema reaches the model-facing tool
definition, the initial model sees only three catalog operations,
search/describe does not execute hidden business actions, the final Lua plan
can call only the selected allowlist within call/parallel/timeout bounds, and a
skill narrows its visible tools without changing operation semantics.

## Official sources

- [Mastra tools](https://mastra.ai/docs/agents/using-tools), [processors](https://mastra.ai/docs/agents/processors), [skills](https://mastra.ai/docs/agents/skills)
- [LangChain tools](https://docs.langchain.com/oss/python/langchain/tools), [agents](https://docs.langchain.com/oss/python/langchain/agents), [Deep Agents](https://docs.langchain.com/oss/python/deepagents/overview)
- [Pydantic AI function tools](https://pydantic.dev/docs/ai/tools-toolsets/tools/), [toolsets](https://pydantic.dev/docs/ai/tools-toolsets/toolsets/), [capabilities](https://pydantic.dev/docs/ai/core-concepts/capabilities/)
- [OpenAI tools](https://openai.github.io/openai-agents-python/tools/)
- [Google ADK function tools](https://adk.dev/tools/function-tools/), [custom tools](https://adk.dev/tools-custom/), [skills](https://adk.dev/skills/)
- [LlamaIndex agent tools](https://developers.llamaindex.ai/python/framework/module_guides/deploying/agents/tools/)
- [AutoGen tools](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/components/tools.html), [workbench](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/components/workbench.html)
- [Jidoka skill/workflow/subagent tools](../../guides/skill-workflow-subagent-tools.md), [operation sources](../../guides/operation-source-contracts.md)
