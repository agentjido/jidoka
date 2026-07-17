# Use Case 05: Session History vs. Scoped Memory Continuity

## Comparison contract

An application runs multiple requests under a stable session identity. The
comparison keeps three different forms of continuity separate:

1. a session records requests and the latest run result;
2. prior conversation state is made available to a later model call; and
3. facts stored outside the transcript are recalled only inside their declared
   scope.

These properties are often grouped under “memory,” but they are not
interchangeable. This comparison is a **partial characterization** for Jidoka:
session records and exact session-scoped memory work, and callers can carry
prior assistant/tool-observation state explicitly. The session facade does not
automatically inject that state into the next request, and `agent_state` does
not reconstruct prior user messages.

Atomic features: `S01` session history, `S03` working memory, `S04` scoped
long-term memory, and `S06` memory isolation.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented conversation continuity | Documented longer-lived memory | Important boundary |
| --- | --- | --- | --- |
| Mastra | Threads group message history under resource/thread identities and can be cloned or shared across attributed users. | Working memory, observational memory, and semantic recall provide distinct longer-lived state/retrieval modes backed by configured storage. | Durability and vector behavior depend on the selected provider; observational compression is not the same contract as raw history. |
| LangGraph / LangChain | Short-term memory is thread-scoped graph state persisted by a checkpointer. | Long-term memories live separately in stores under application-defined namespaces. | Checkpoint state and long-term store namespaces are separate contracts. |
| Pydantic AI | Core callers pass serializable `message_history`; processors can trim or summarize it. | Harness adds a bounded namespaced searchable notebook with optimistic concurrency and pluggable stores. | Core history persistence is application-owned; Harness memory is an official package and is not a full graph-state checkpoint. |
| OpenAI Agents SDK | Sessions automatically maintain history across runs through pluggable implementations and can compact Responses context. | Beta sandbox memory stores distilled lessons/preferences as workspace files, separate from conversation history. | SQLite, Redis, SQLAlchemy, Dapr, MongoDB, OpenAI Conversations, encrypted, and advanced SQLite implementations have different persistence loci. |
| Google ADK | `Session` contains chronological events and state through a `SessionService`. | `MemoryService` provides cross-session retrieval through in-memory, Vertex AI Memory Bank, or Vertex AI RAG implementations. | Persistence and retrieval behavior depend on the selected service. |
| LlamaIndex / LlamaAgents | `Memory` includes short-term FIFO chat history and may be keyed by `session_id`. | Optional long-term extraction blocks and configured chat stores extend retention. | A session identifier alone does not make memory durable. |
| AutoGen | Agents retain chat context in stateful model context; teams expose save/load state for application persistence. | A separate Memory protocol provides `add`, `query`, and `update_context`, with persistent implementations in official extensions. | Saving team state and choosing/persisting memory implementations are explicit application responsibilities. |
| Jidoka | `Jidoka.Session` persists request records and the latest result. A later `Turn.Request` can explicitly carry a prior public `agent_state`. | `Jidoka.Memory` recalls entries under the agent/session policy before prompt assembly. | Partial: ordinary `Session.run/3` does not auto-inject the prior result state, and carried state contains assistant/tool observations rather than a full user/assistant transcript. In-memory stores are test/process stores, not production durability. |

## Executable Jidoka partial characterization

Parity tests are opt-in and must be run from the repository root. A passing
test validates the status declared by this comparison; it does not turn this
partial characterization into a full parity claim.

Run only this comparison:

```bash
mix test --only parity:session_history_vs_scoped_memory_continuity test/parity --trace
```

Run every parity comparison:

```bash
mix test --only parity test/parity --trace
```

The normal suite excludes parity comparisons:

```bash
mix test
```

The tagged test uses the public session facade, two isolated in-memory session
records, a session-scoped memory store, real prompt assembly, and real turn
execution. The first turn executes one public operation through an injected
local operation capability. Both the model responses and operation result are
deterministic injected test capabilities. A passing run proves:

- session A persists each submitted `Turn.Request` in order;
- each returned session and the reloaded session-A record retain the latest
  completed `Turn.Result`;
- memory written through `Session.write_memory/3` is recalled for session A
  before its model calls;
- A1 executes one deterministic operation before its final response, with the
  tool observation and `Effect.OperationResult` exposed in public result state;
- an ordinary second session-A request receives neither the first assistant
  response nor its tool observation and operation result automatically;
- a request that explicitly carries the first public `agent_state` executes a
  real session turn whose model prompt contains the prior assistant response
  and tool observation;
- the explicitly continued result retains the prior operation result, tool
  observation, and both prior and current assistant messages;
- the first user request is absent from carried `agent_state`, so the test does
  not mistake assistant-state carry for full transcript reconstruction; and
- session B sees neither session A's scoped memory, assistant state, tool
  observation, nor operation result.

## What this does not claim

- Jidoka does not currently provide automatic transcript continuation through
  repeated ordinary `Session.run/3` calls.
- Carrying `Turn.Result.agent_state` does not reconstruct prior user requests;
  an application that needs a complete transcript must build it from its
  session request records and chosen conversation policy.
- The in-memory stores used by the proof do not establish production database
  durability, distributed coordination, backups, or multi-process consistency.
- Exact scoped recall is not semantic/vector retrieval, ranking, summarization,
  or automatic memory extraction.
- A passing parity tag validates this documented partial status; aggregate pass
  counts must not be presented as full session-history parity.

## Official sources

- [Mastra memory overview](https://mastra.ai/docs/memory/overview)
- [Mastra memory storage](https://mastra.ai/docs/memory/storage)
- [LangGraph memory](https://docs.langchain.com/oss/python/langgraph/add-memory)
- [LangChain memory overview](https://docs.langchain.com/oss/python/concepts/memory)
- [Pydantic AI message history](https://pydantic.dev/docs/ai/core-concepts/message-history/)
- [Pydantic AI Harness memory](https://pydantic.dev/docs/ai/harness/memory/)
- [OpenAI Agents SDK sessions](https://openai.github.io/openai-agents-python/sessions/)
- [OpenAI Agents SDK sandbox agent memory](https://openai.github.io/openai-agents-python/sandbox/memory/)
- [Google ADK sessions](https://adk.dev/sessions/session/)
- [Google ADK memory](https://adk.dev/sessions/memory/)
- [LlamaIndex memory](https://developers.llamaindex.ai/python/framework/module_guides/deploying/agents/memory/)
- [AutoGen memory and RAG](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/memory.html)
- [AutoGen agents and state](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/agents.html)
