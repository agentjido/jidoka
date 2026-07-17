# Use Case 08: Controls, Guardrails, and Operation Safety

**Roadmap status:** Docs ready.

## Comparison contract

An application validates input before the model, validates the final result
before the caller, applies policy around every operation, requires review when
needed, and makes retry/deduplication behavior explicit for side effects.

Atomic features: `G01` input controls, `G02` output controls, `G03` operation
policy, `G04` human review, and `T06` idempotency/effect semantics.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented surface | Important boundary |
| --- | --- | --- |
| Mastra | Input/output/hybrid processors, built-in guardrails, bounded processor retry/tripwires, tool approval, and runtime tool suspension. | Persistent effect idempotency is still an application/tool concern unless the selected durable runtime supplies a stronger contract. |
| LangChain / LangGraph | Middleware provides PII handling, custom guardrails, call limits, fallback/retry, and tool HITL decisions (`approve`, `edit`, `reject`, `respond`). | LangGraph explicitly requires idempotent side effects for replay; that discipline is not automatic exactly-once execution. |
| Pydantic AI | Harness guardrails support allow/block/replace/retry; core tools validate arguments and support retry feedback, deferred approval, and sequential barriers. | Guardrails, output validation, and durable-integration retry budgets are distinct mechanisms. |
| OpenAI Agents SDK | Input, output, and per-tool guardrails wrap the runner; approvals span tools, nested agents, handoffs, shell, patch, and MCP. | Approval is not authorization, and durable side-effect reconciliation depends on the selected integration/application. |
| Google ADK | Callbacks and global plugins can inspect, modify, or bypass agent/model/tool stages; tool confirmation is experimental and ATR Guardrail is an integration. | Core resume is at-least-once and documents idempotent tools as an application obligation. |
| LlamaIndex / LlamaAgents | Validation, callbacks, workflow steps/events, and HITL events can compose policy. | No unified first-class guardrail/policy API or automatic exactly-once effect layer was established. |
| AutoGen | Core intervention handlers inspect, replace, or drop runtime messages, including tool requests; AgentChat includes human feedback and termination patterns. | Message interception and team pause are not a persisted, authenticated review artifact or durable deduplication ledger. |
| Jidoka | Input, output, and operation controls cross stable runtime phases; operation specs declare idempotency and `:unsafe_once`; review hibernates before interpretation and the effect journal records intent/result. | Applications still own reviewer authorization, result persistence, external idempotency keys, and reconciliation. |

## Jidoka proof target

Use one agent with all three control phases. Assert rejected input makes no model
call, rejected output never reaches the caller, an operation policy can allow,
block, or interrupt, and duplicate/replayed intents follow each declared
idempotency policy without relying on model prose.

## Official sources

- [Mastra guardrails](https://mastra.ai/docs/agents/guardrails), [agent approval](https://mastra.ai/docs/agents/agent-approval)
- [LangChain guardrails](https://docs.langchain.com/oss/python/langchain/guardrails), [human in the loop](https://docs.langchain.com/oss/python/langchain/human-in-the-loop)
- [Pydantic AI Harness guardrails](https://pydantic.dev/docs/ai/harness/guardrails/), [deferred tools](https://pydantic.dev/docs/ai/tools-toolsets/deferred-tools/)
- [OpenAI Agents SDK guardrails](https://openai.github.io/openai-agents-python/guardrails/), [human in the loop](https://openai.github.io/openai-agents-python/human_in_the_loop/)
- [Google ADK callbacks](https://adk.dev/callbacks/), [tool confirmation](https://adk.dev/tools/confirmation/)
- [LlamaAgents human in the loop](https://developers.llamaindex.ai/python/llamaagents/workflows/human_in_the_loop/)
- [AutoGen intervention approval](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/cookbook/tool-use-with-intervention.html)
- [Jidoka controls](../../guides/controls.md), [idempotency and safety](../../guides/idempotency-and-safety.md)
