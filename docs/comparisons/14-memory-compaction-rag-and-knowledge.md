# Use Case 14: Memory, Compaction, RAG, and Knowledge

**Roadmap status:** Docs ready; Jidoka compaction and RAG are product gaps.

## Comparison contract

An agent keeps current conversation history, stores scoped facts across
sessions, compacts long context without confusing summary with memory, ingests
knowledge into searchable indexes, and retrieves bounded evidence with a clear
persistence and tenancy boundary.

Atomic features: `S03` long-term memory, `S04` scope, `S05` compaction, `S06`
stores, `S07` ingestion/indexing, and `T13` RAG/retrieval.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented surface | Important boundary |
| --- | --- | --- |
| Mastra | Thread/resource history, working memory, observational memory, semantic recall, multi-user threads, chunking/embedding, vector integrations, reranking, and GraphRAG. | Storage/provider choice determines durability; observational memory is distinct from raw transcript compaction. |
| LangChain / LangGraph | Checkpointed short-term state, namespaced long-term stores, trim/delete/summarize middleware, semantic search, loaders, embeddings, vector stores, and 2-step/agentic/hybrid RAG. | LangGraph state, long-term Store, and external retrieval indexes are separate persistence contracts. |
| Pydantic AI | Core message-history processors, Harness namespaced searchable memory/compaction, embeddings, application vector stores, and provider-native file search. | Harness memory is an official package; generic RAG storage/ingestion remains application/provider selected. |
| OpenAI Agents SDK | Pluggable conversation sessions, response compaction, beta sandbox file memory, and hosted vector-store file search. | Conversation state, sandbox memory, and hosted RAG are three different loci. |
| Google ADK | Session state, cross-session MemoryService, model summarization compaction, database/Vertex services, artifacts, and grounding/knowledge integrations. | Managed RAG/memory behavior is hosted and language/runtime dependent. |
| LlamaIndex | Token-limited memory, static/fact/vector memory blocks, persistent stores, readers/parsers/ingestion/indexes/retrievers/routers/query engines. | This is a core differentiator; workflow context serialization is still separate from memory/index durability. |
| AutoGen | Context-window strategies, Memory protocol, list memory, Chroma/Redis vector integrations, and app-managed ingestion. | Snapshotting an agent/team is not the same as long-term semantic memory. |
| Jidoka | Memory policies recall/write through pluggable store behaviors with explicit scope; sessions store request records/latest results. | Partial: no transcript compaction, built-in ingestion/index/vector/RAG layer, or production store implementation; ordinary sessions do not auto-carry a full transcript. |

## Jidoka proof and product split

First prove memory recall/capture, namespace isolation, capture-failure evidence,
and custom-store behavior. Then design compaction as a transcript-window feature
and RAG as an external knowledge boundary; neither should be emulated by calling
the existing memory API a vector database.

## Official sources

- [Mastra memory](https://mastra.ai/docs/memory/overview), [RAG](https://mastra.ai/docs/rag/retrieval)
- [LangChain memory](https://docs.langchain.com/oss/python/langchain/short-term-memory), [retrieval](https://docs.langchain.com/oss/python/langchain/retrieval)
- [Pydantic Harness memory](https://pydantic.dev/docs/ai/harness/memory/), [compaction](https://pydantic.dev/docs/ai/harness/compaction/), [embeddings](https://pydantic.dev/docs/ai/guides/embeddings/)
- [OpenAI sessions](https://openai.github.io/openai-agents-python/sessions/), [sandbox memory](https://openai.github.io/openai-agents-python/sandbox/memory/)
- [Google ADK memory](https://adk.dev/sessions/memory/), [compaction](https://adk.dev/context/compaction/)
- [LlamaIndex memory](https://developers.llamaindex.ai/python/framework/module_guides/deploying/agents/memory/), [framework](https://developers.llamaindex.ai/python/framework/)
- [AutoGen memory and RAG](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/memory.html)
- [Jidoka memory](../../guides/memory.md), [memory contracts](../../guides/memory-contracts.md)
