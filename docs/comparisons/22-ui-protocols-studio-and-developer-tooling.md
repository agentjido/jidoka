# Use Case 22: UI Protocols, Studio, and Developer Tooling

**Roadmap status:** Docs ready; Jidoka has projections/Kino but no Studio or standard UI protocol.

## Comparison contract

Developers can inspect and visualize an agent locally, run it interactively,
render streaming/tool/review state through stable UI data, and understand which
parts are a local devtool, a wire protocol, or a hosted production platform.

Atomic features: `R04` Studio/playground, `R05` UI projection/protocol, and
`O02` local inspection/preflight.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented developer/UI surface | Important boundary |
| --- | --- | --- |
| Mastra | Local/deployed Studio tests agents/workflows/tools, visualizes graphs/traces, and manages datasets/experiments; Agent Builder, MCP Apps, channels, and AI SDK streams cover UI/product paths. | Local Studio, deployed Studio, Agent Builder, and Platform are different loci/access tiers. |
| LangChain / LangGraph | Graph/debug streams and local Agent Server combine with LangSmith Studio, generative UI, traces, threads, assistants, prompts, experiments, memory, and time travel. | Studio and production management are LangSmith platform surfaces. |
| Pydantic AI | AG-UI and Vercel AI event adapters, local `Agent.to_web()`, CLI, graph visualization, and Logfire inspection. | Local web chat is explicitly a dev/debug tool; Logfire is hosted. |
| OpenAI Agents SDK | Semantic stream events support product UIs; REPL and Graphviz visualize local execution; hosted trace dashboards inspect runs. | The SDK does not define a general AG-UI/A2UI-style frontend protocol or local Studio. |
| Google ADK | CLI/local web UI inspects events/state/tools/model traces; A2UI and streaming protocols support UIs; Agent Runtime adds managed surfaces. | Language/runtime coverage and hosted deployment must remain qualified. |
| LlamaIndex / LlamaAgents | Official workflow server/debugger UI shows graphs, schemas, logs, concurrent runs, and HITL event entry; hosted Agent Builder adds natural-language/visual construction. | Debugger/server packages and hosted Cloud Builder are separate from workflow core. |
| AutoGen | Studio offers drag/drop team building, JSON components, playground sessions, streaming, pause/stop, graph views, galleries, and export. | Official docs call Studio a research prototype without production security guarantees. |
| Jidoka | `inspect`, `preflight`, `project`, request debug summaries, `AgentView`, streaming events, Kino/Livebook renderers, and Phoenix-friendly projections are stable local/data surfaces. | No visual builder, standard frontend wire protocol, hosted trace UI, production auth/multi-user Studio, or deployment control plane. |

## Jidoka proof target

Prove that the same deterministic turn drives `AgentView`, Kino/debug output,
and stable projections through public events without exposing private runtime
state. A future protocol should serialize these stable semantics rather than
making a UI depend directly on internal structs.

## Official sources

- [Mastra Studio](https://mastra.ai/docs/studio/overview), [MCP Apps](https://mastra.ai/docs/mcp/mcp-apps)
- [LangSmith Studio](https://docs.langchain.com/langsmith/studio), [generative UI](https://docs.langchain.com/langsmith/generative-ui-react)
- [Pydantic AI UI streams](https://pydantic.dev/docs/ai/integrations/ui/overview/), [web chat](https://pydantic.dev/docs/ai/guides/web/)
- [OpenAI Agents SDK visualization](https://openai.github.io/openai-agents-python/visualization/), [REPL](https://openai.github.io/openai-agents-python/repl/)
- [Google ADK A2UI](https://adk.dev/integrations/a2ui/)
- [LlamaAgents workflow deployment](https://developers.llamaindex.ai/python/llamaagents/workflows/deployment/), [Agent Builder](https://developers.llamaindex.ai/python/llamaagents/cloud/builder/)
- [AutoGen Studio](https://microsoft.github.io/autogen/stable/user-guide/autogenstudio-user-guide/index.html)
- [Jidoka AgentView](../../guides/agent-view.md), [Kino notebooks](../../guides/kino-notebooks.md), [inspection](../../guides/inspection-and-preflight.md)
