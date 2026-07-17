# Use Case 09: Resumable State, Durable Execution, and Replay

**Roadmap status:** Docs ready; Jidoka crash-safe durability is partial.

## Comparison contract

A long-running agent can pause, persist state, survive process failure, resume
without repeating completed unsafe effects, and reconstruct or fork prior state
with explicit replay semantics.

Atomic features: `E06` serializable continuation, `E07` crash-safe durable
execution, `E08` replay/time travel, and `S02` checkpoint state.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Serializable/resumable state | Durable/replay boundary |
| --- | --- | --- |
| Mastra | Workflow snapshots preserve step state, outputs, paths, suspended steps, and retry counts; runs support resume and time travel. | Durable agents and external runners add restartable/background execution, but a LangGraph-style deterministic task replay and pending-write contract was not established. |
| LangGraph | Checkpointers save every graph superstep in threads; interrupts, pending writes, retries, failures, replay, and fork are explicit. | The Functional API requires side effects/nondeterminism in checkpointed tasks and still requires idempotent operations. |
| Pydantic AI | Durable integrations cover Temporal, DBOS, Prefect, and Restate; Harness step persistence records append-only events, continuation snapshots, tool effects, and run lineage. | Harness step persistence explicitly is not full graph-state checkpointing; durable vendor semantics belong to official integrations. |
| OpenAI Agents SDK | Serializable `RunState` resumes HITL; official Dapr, Temporal, Restate, and DBOS integrations provide restart/long-wait durability. | The SDK has no native graph time-travel engine, and persistence/effect semantics depend on the integration. |
| Google ADK | Opt-in resumable apps checkpoint dynamic workflow nodes and resume by invocation ID. | Core resume is at-least-once. DBOS, Dapr, Restate, and Temporal are separate stronger integrations. |
| LlamaIndex / LlamaAgents | `Context.to_dict/from_dict` supports snapshot/restore; applications may skip completed steps; DBOS adds automatic durable execution. | Core checkpoint storage is app-managed and in-flight work may replay; exact side effects require idempotency. |
| AutoGen | Agents and teams expose `save_state/load_state` for application persistence. | State serialization is not a transactional durable workflow engine, automatic checkpointer, or exactly-once executor. |
| Jidoka | Versioned signed snapshots, sessions, journals, cursors, claims, and data-only replay expose continuation evidence. | Partial: production persistence/claims and crash recovery are store/application responsibilities; replay reconstructs evidence and does not re-execute capabilities. |

## Jidoka proof target

Prove snapshot round-trip, session persistence, pending-effect recovery, data-only
replay without capability calls, and stale/claimed resume rejection. A separate
product design must define process crash, store transaction, claim expiry,
completed-effect, and retry semantics before claiming durable execution.

## Official sources

- [Mastra snapshots](https://mastra.ai/docs/workflows/snapshots), [time travel](https://mastra.ai/docs/workflows/time-travel), [durable agents](https://mastra.ai/docs/long-running-agents/durable-agents)
- [LangGraph persistence](https://docs.langchain.com/oss/python/langgraph/persistence), [Functional API](https://docs.langchain.com/oss/python/langgraph/functional-api), [time travel](https://docs.langchain.com/oss/python/langgraph/use-time-travel)
- [Pydantic durable execution](https://pydantic.dev/docs/ai/integrations/durable_execution/overview/), [step persistence](https://pydantic.dev/docs/ai/harness/step-persistence/)
- [OpenAI durable integrations](https://openai.github.io/openai-agents-python/running_agents/#durable-execution-integrations-and-human-in-the-loop)
- [Google ADK resume](https://adk.dev/runtime/resume/)
- [LlamaAgents durable workflows](https://developers.llamaindex.ai/python/llamaagents/workflows/durable_workflows/), [DBOS](https://developers.llamaindex.ai/python/llamaagents/workflows/dbos/)
- [AutoGen state](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/state.html)
- [Jidoka snapshots](../../guides/snapshots-and-resume.md), [sessions](../../guides/sessions-and-stores.md)
