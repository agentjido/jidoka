# Use Case 17: Background Work, Schedules, Servers, and Deployment

**Roadmap status:** Product gap beyond Jidoka process hosting.

## Comparison contract

An application can launch long-running/background work, reconnect to status and
events, schedule recurring runs, expose agents over a supported API server, and
deploy the runtime with clearly labeled local, self-hosted, and managed loci.

Atomic features: `W07` background work, `W08` schedules, `R01` long-lived
runtime, `R02` HTTP server, and `R03` managed deployment.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented runtime/deployment surface | Important boundary |
| --- | --- | --- |
| Mastra | Durable agents, background tasks, goals, signals, scheduled workflows, standalone Server, adapters/middleware/auth/PubSub, multi-runtime deployment, external workflow runners, and Platform. | Core Server, official integrations, and managed Platform must remain separately labeled. |
| LangChain / LangGraph | LangSmith Agent Server provides assistants, threads, background runs, task queue, cron, MCP/A2A, scaling, CLI/local server, cloud/self-host deployment. | These are LangSmith runtime/platform capabilities, not LangGraph OSS core. |
| Pydantic AI | Apps serve agents themselves; durable integrations support long waits/restarts and some serverless runtimes. | No package-owned general agent server/deployment control plane was established. |
| OpenAI Agents SDK | Applications host the runner; durable Dapr/Temporal/Restate/DBOS integrations and hosted sandbox/provider tools cover specific execution loci. | No general SDK application server, scheduler, or deployer was established. |
| Google ADK | Core API server/runtime, long-running tools, cancellation/resume, container deployment, Cloud Run/GKE paths, and hosted Agent Runtime. | Managed Agent Runtime and Google infrastructure are Hosted, not local core. |
| LlamaIndex / LlamaAgents | Official workflow server/CLI supports sync/async runs, status, cancellation, event streaming, HITL submission, SQLite persistence, debugger UI; Cloud adds build/deploy/rollback. | Core workflow execution, official server package, and hosted Cloud are distinct. |
| AutoGen | Core single-process and experimental distributed gRPC runtimes host agents; applications compose APIs/UI. | No production agent-server/deployment product or scheduler was established; Studio is a research/dev tool. |
| Jidoka | DSL agents can run directly or under a supervised Jido `AgentServer` process with lookup, await, and stop helpers. | No background-run directory, reconnectable run stream, scheduler, HTTP server, deployment adapter, autoscaling/runtime control plane, or managed service. |

## Roadmap questions

This work likely crosses the Jidoka/Jido boundary. Decide which package owns run
identity, claims, queueing, schedules, storage, APIs, auth, scaling, and
deployment before building examples. Process hosting alone must not be marketed
as durable background execution.

## Official sources

- [Mastra durable agents](https://mastra.ai/docs/long-running-agents/durable-agents), [scheduled workflows](https://mastra.ai/docs/workflows/scheduled-workflows), [Server](https://mastra.ai/docs/server/mastra-server)
- [LangSmith Agent Server](https://docs.langchain.com/langsmith/agent-server), [cron jobs](https://docs.langchain.com/langsmith/cron-jobs)
- [Pydantic durable execution](https://pydantic.dev/docs/ai/integrations/durable_execution/overview/)
- [OpenAI durable integrations](https://openai.github.io/openai-agents-python/running_agents/#durable-execution-integrations-and-human-in-the-loop)
- [Google ADK API server](https://adk.dev/runtime/api-server/), [deployment](https://adk.dev/deploy/)
- [LlamaAgents workflow deployment](https://developers.llamaindex.ai/python/llamaagents/workflows/deployment/), [click-to-deploy](https://developers.llamaindex.ai/python/llamaagents/cloud/click-to-deploy/)
- [AutoGen Core](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/index.html)
- [Jidoka Jido process integration](../../guides/jido-process-integration.md)
