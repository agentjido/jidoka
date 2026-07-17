# Use Case 19: Teams, Group Chat, and Agent Graphs

**Roadmap status:** Docs ready; Jidoka has agent workflow steps but no general team runtime.

## Comparison contract

Multiple agents collaborate through deterministic graphs or dynamic speaker
selection, with explicit termination, context visibility, state ownership, and
the ability to distinguish a team conversation from one manager calling tools.

Atomic features: `M03` teams/group chat, `M04` deterministic agent graphs,
`M06` remote/distributed runtime, and `W04` cycles/dynamic work.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented multi-agent surface | Important boundary |
| --- | --- | --- |
| Mastra | Supervisors, background subagents, AgentController modes/forks, workflows containing agents, multi-user threads, A2A, and SDK-backed agents. | Supervisor synthesis is not group-chat speaker selection, and no durable ownership-handoff primitive was established. |
| LangChain / LangGraph | Subagent, handoff, router, and skills patterns compose on StateGraph; Deep Agents adds dynamic/background subagents; Agent Server hosts graphs. | Many multi-agent patterns are application graph design rather than one generic team object. |
| Pydantic AI | Delegation, programmatic handoff, Pydantic Graph, Harness subagents, and sandboxed dynamic workflow composition. | No general shared-transcript group-chat runtime was established. |
| OpenAI Agents SDK | Manager agents-as-tools, handoffs, Python orchestration, and experimental hosted multi-agent execution. | The SDK intentionally uses Python rather than a declarative graph/team runtime. |
| Google ADK | Hierarchical agents, transfer, agent tools, sequential/parallel/loop agents, graph routes, dynamic workflows, and A2A. | Collaboration semantics vary by mode and SDK language. |
| LlamaIndex | Linear AgentWorkflow swarm/handoffs, orchestrator-as-tool, custom planners, and event-driven workflows. | Active agent state lives in workflow context; durable cross-request storage is separate. |
| AutoGen | RoundRobinGroupChat, SelectorGroupChat, Swarm, Magentic-One, TeamTool, and experimental GraphFlow with branches, parallelism, joins, loops, and message filters. | GraphFlow is experimental; team snapshots are not durable workflow checkpoints. |
| Jidoka | Workflows can invoke agent steps, subagents return bounded results, and handoffs record future-turn owner data. | No general team/shared-transcript/speaker-selection/termination runtime, dynamic agent graph, remote runtime, or distributed team state. |

## Roadmap decision

First prove the existing workflow-agent-step boundary. Add a general team model
only for a use case that cannot be expressed clearly with workflows, bounded
delegation, and ownership handoff. Any design must define transcript ownership,
speaker selection, termination, context filters, tool concurrency, persistence,
and recovery.

## Official sources

- [Mastra supervisor agents](https://mastra.ai/docs/agents/supervisor-agents), [AgentController subagents](https://mastra.ai/docs/agent-controller/subagents)
- [LangChain multi-agent overview](https://docs.langchain.com/oss/python/langchain/multi-agent), [LangGraph workflows](https://docs.langchain.com/oss/python/langgraph/workflows-agents)
- [Pydantic AI multi-agent patterns](https://pydantic.dev/docs/ai/guides/multi-agent-applications/), [dynamic workflow](https://pydantic.dev/docs/ai/harness/dynamic-workflow/)
- [OpenAI agent orchestration](https://openai.github.io/openai-agents-python/multi_agent/)
- [Google ADK workflows](https://adk.dev/workflows/)
- [LlamaIndex multi-agent patterns](https://developers.llamaindex.ai/python/framework/understanding/agent/multi_agent/)
- [AutoGen teams](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/teams.html), [GraphFlow](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/graph-flow.html)
- [Jidoka orchestration](../../guides/agent-orchestration.md), [workflows](../../guides/workflows.md)
