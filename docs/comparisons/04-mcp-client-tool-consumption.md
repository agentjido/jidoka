# Use Case 04: MCP Client Tool Consumption

## Comparison contract

An agent runtime discovers a remote MCP tool through a client integration,
exposes that tool to the model with its remote argument schema, maps the
model-selected local name back to the remote tool name, and returns a successful
remote result as an ordinary tool observation. A remote failure must remain a
typed runtime failure and must not become a successful model observation.

This comparison treats five properties as distinct:

1. tool discovery is explicit and produces a model-callable local operation;
2. the operation exposes the remote name, description, and argument schema;
3. model-proposed arguments are forwarded to the matching remote tool;
4. a successful remote response becomes inspectable operation evidence; and
5. a remote error stops the turn without fabricating a successful observation.

Atomic feature: `T07` MCP client tool consumption.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented mechanism | Result or continuation artifact | Important boundary |
| --- | --- | --- | --- |
| Mastra | The official `@mastra/mcp` package provides `MCPClient`; `getTools()` obtains MCP tools for use by an agent. | Agent tool results returned through the normal Mastra tool path. | This is an official integration package. MCP server exposure is a separate concern. |
| LangChain | The official `langchain-mcp-adapters` package uses `MultiServerMCPClient.get_tools()` to convert MCP server tools into LangChain tools. | LangChain tool messages; structured MCP content can be retained in a `ToolMessage` artifact. | The client is stateless by default and creates a fresh MCP session per tool call unless the application explicitly manages a persistent session. |
| Pydantic AI | `MCPToolset` wraps the client integration and makes stdio, Streamable HTTP, or SSE MCP tools available to an agent. | Validated agent messages and tool-return data. | Toolset lifecycle can be automatic or explicit. Per-user authorization generally requires a separately configured client/toolset identity. |
| OpenAI Agents SDK | `HostedMCPTool` runs MCP access in OpenAI's Responses infrastructure; SDK-side MCP server clients support Streamable HTTP, stdio, and SSE. | Hosted Responses tool results or SDK-side MCP tool results, depending on the selected locus. | Hosted and SDK-side execution have different trust and deployment boundaries and must not be treated as the same client path. |
| Google ADK | `McpToolset` connects to an MCP server and adapts discovered tools into ADK tools. | ADK tool results in the agent session/event flow. | Client consumption and serving ADK tools through MCP are separate documented directions. |
| LlamaIndex / LlamaAgents | The official MCP integration makes tools from an existing MCP server available to LlamaIndex agents and workflows. | Agent/workflow tool-call results. | Transport lifecycle and durability depend on the integration and application configuration; the reviewed overview does not establish them as workflow-core guarantees. |
| AutoGen | The official `autogen-ext[mcp]` extension provides `McpWorkbench` for MCP tools, resources, and prompts. | Workbench tool results consumed by AutoGen agents. | MCP support is an official extension rather than an AgentChat-core transport, and the documented integration does not support every MCP capability. |
| Jidoka | `Jidoka.Operation.Source.MCP` opt-in discovery compiles each remote tool into an ordinary operation. The operation capability maps its prefixed local name back to the remote name, calls the configured client, normalizes the reply, and crosses the standard effect shell. | Public operation metadata, operation intent/result journal entries, `Effect.OperationResult`, model tool messages, and streamed failure events. | This proof uses a deterministic fake client. The exposed remote schema is prompt metadata; Jidoka does not currently enforce that MCP argument schema at runtime. |

## Executable Jidoka proof

Parity tests are opt-in and must be run from the repository root.

Run only this comparison:

```bash
mix test --only parity:mcp_client_tool_consumption test/parity --trace
```

Run every parity comparison:

```bash
mix test --only parity test/parity --trace
```

The normal suite excludes parity comparisons:

```bash
mix test
```

For the targeted command, ExUnit should report one selected test and a final
`Result: 1 passed`. The `--only parity:mcp_client_tool_consumption` filter
overrides the normal parity exclusion and selects the value assigned by
`use Jidoka.ParityCase, parity: :mcp_client_tool_consumption`.

The tagged integration test uses the public `Jidoka.Operation.Source.MCP`
compiler and the public turn facade. Its fake MCP client provides deterministic
discovery, success, and failure responses, so the proof requires no credentials,
network transport, or external server.

The test fails if any assertion is false. A passing run proves:

- opt-in discovery compiles exactly one prefixed MCP operation;
- operation metadata retains the MCP source, endpoint, remote tool name, prefix,
  and remote argument schema;
- the first model prompt exposes that same local operation and argument schema;
- the model-selected local name maps to the expected remote tool name and the
  exact model-proposed arguments reach the fake client;
- the successful MCP response is normalized into one operation result, one
  matching journaled operation intent/result, and one model tool observation;
- a fake remote error returns a typed `ExecutionError` and streams exactly one
  `:capability_call_failed`, `:effect_failed`, and `:turn_failed` event;
- the failed operation emits no `:operation_observed` event; and
- the model is not called a second time after the remote failure.

## What this does not claim

- The exposed MCP argument schema is model-facing metadata. This proof does not
  claim runtime validation or enforcement of model-proposed arguments against
  that schema.
- The fake client does not prove MCP transport interoperability, connection or
  session lifecycle, authentication, authorization, credential handling, or
  compatibility with a live external MCP server.
- The comparison proves MCP client tool consumption only. It does not prove MCP
  server hosting or publication of Jidoka operations as MCP tools.
- Remote MCP metadata and results remain untrusted input. A scripted model and
  fake result do not prove prompt-injection resistance, content sanitization,
  or safe execution of instructions embedded in remote content.

## Official sources

- [Mastra: MCP overview](https://mastra.ai/docs/mcp/overview.md)
- [LangChain: Model Context Protocol (MCP)](https://docs.langchain.com/oss/python/langchain/mcp)
- [Pydantic AI: MCP client](https://pydantic.dev/docs/ai/mcp/client/)
- [OpenAI Agents SDK: Model context protocol (MCP)](https://openai.github.io/openai-agents-python/mcp/)
- [Google ADK: MCP tools](https://adk.dev/tools-custom/mcp-tools/)
- [LlamaIndex: Model Context Protocol (MCP)](https://developers.llamaindex.ai/python/framework/module_guides/mcp/)
- [AutoGen: Workbench and MCP](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/components/workbench.html)
- `Jidoka.Operation.Source.MCP`
- `Jidoka.Operation.Source`
- `Jidoka.Runtime.EffectInterpreter`
