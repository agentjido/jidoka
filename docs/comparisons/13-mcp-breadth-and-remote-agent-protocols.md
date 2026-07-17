# Use Case 13: MCP Breadth and Remote-Agent Protocols

**Roadmap status:** Product gap beyond MCP client tools.

## Comparison contract

An agent consumes MCP tools plus richer MCP capabilities, can expose local
tools/workflows through MCP, and can discover, invoke, stream, resume, and cancel
remote agents through a standard agent protocol with explicit trust boundaries.

Atomic features: `T08` MCP resources/prompts/elicitation/sampling, `T09` MCP
server exposure, `T10` A2A/ACP, and `M06` remote/distributed agent runtime.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented protocol surface | Important boundary |
| --- | --- | --- |
| Mastra | MCP client/server covers tools, resources, prompts, elicitation, registries, and MCP Apps; A2A client/server covers cards, tasks, artifacts, streaming, cancellation, resubscription, and signatures; ACP is an integration. | Server, remote-agent, and UI trust/authentication boundaries are separate from local tool calling. |
| LangChain / LangGraph | Official MCP adapters cover tools/resources/prompts/elicitation; Deep Agents exposes ACP; LangSmith Agent Server exposes MCP and A2A endpoints. | MCP/A2A servers are Agent Server platform capabilities, not OSS LangGraph core. |
| Pydantic AI | MCP clients cover tools, resources, instructions, metadata, sampling, elicitation, and auth; FastMCP recipes expose Pydantic agents; Harness exposes ACP. | ACP is coding-harness oriented, and FastMCP server composition depends on the MCP SDK. |
| OpenAI Agents SDK | Local and hosted MCP clients support tools, prompts, filtering, approvals, caching, metadata, and multiple transports. | No SDK-owned MCP server or A2A/ACP remote-agent abstraction was established. |
| Google ADK | `McpToolset` consumes MCP tools; MCP server exposure is an MCP SDK recipe; experimental A2A can expose or consume agents. | A2A and feature parity are language/version gated; MCP server is app-managed. |
| LlamaIndex / LlamaAgents | MCP tools are an official integration and conversion helpers expose tools/workflows through FastMCP. | A2A was not established; rich MCP resource/prompt consumption is narrower than the leading clients. |
| AutoGen | `McpWorkbench` supports tools and qualified resource/prompt/sampling behavior; Core has an experimental distributed gRPC runtime. | No first-class MCP server or A2A adapter was established; gRPC is an AutoGen runtime protocol, not A2A. |
| Jidoka | MCP sources discover and invoke remote tools through the standard operation/effect boundary. | No public MCP resources/prompts/elicitation/sampling, MCP server, A2A/ACP, agent cards/tasks, or distributed agent runtime. |

## Roadmap questions

- Should MCP server/A2A support live in Jidoka, Jido, or companion packages?
- Which capabilities can cross the functional-core/effect-shell boundary as
  typed intents/results without embedding transport lifecycle into the turn?
- How are tenant identity, credentials, approvals, streaming, cancellation,
  task persistence, and remote trust represented?

## Official sources

- [Mastra MCP](https://mastra.ai/docs/mcp/overview), [A2A](https://mastra.ai/docs/agents/a2a), [ACP](https://mastra.ai/docs/agents/acp)
- [LangChain MCP](https://docs.langchain.com/oss/python/langchain/mcp), [Agent Server A2A](https://docs.langchain.com/langsmith/server-a2a), [Deep Agents ACP](https://docs.langchain.com/oss/python/deepagents/acp)
- [Pydantic AI MCP client](https://pydantic.dev/docs/ai/mcp/client/), [MCP server](https://pydantic.dev/docs/ai/mcp/server/), [ACP](https://pydantic.dev/docs/ai/harness/acp/)
- [OpenAI Agents SDK MCP](https://openai.github.io/openai-agents-python/mcp/)
- [Google ADK MCP](https://adk.dev/tools-custom/mcp-tools/), [A2A](https://adk.dev/a2a/)
- [LlamaIndex MCP](https://developers.llamaindex.ai/python/framework/module_guides/mcp/llamaindex_mcp/)
- [AutoGen MCP](https://microsoft.github.io/autogen/stable/reference/python/autogen_ext.tools.mcp.html), [distributed runtime](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/framework/distributed-agent-runtime.html)
- [Jidoka MCP tools](../../guides/mcp-tools.md)
