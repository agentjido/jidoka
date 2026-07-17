# Use Case 01: Resumable Tool Approval

## Comparison contract

A model proposes a financial side effect. The runtime must stop before calling
the tool, expose the pending call for human review, preserve enough state to
cross a request or process boundary, and continue only after a targeted approval
or denial.

This comparison treats five properties as distinct:

1. the side effect is not executed before review;
2. the caller receives a structured pending request;
3. continuation state can leave the active run and later be restored;
4. an approval or denial targets the pending call; and
5. the resumed run produces inspectable evidence of what executed.

Atomic features: `T05` pre-execution approval, `G04` human review and targeted
resume, and `E06` serializable pause/resume state.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented mechanism | Continuation artifact | Important boundary |
| --- | --- | --- | --- |
| Mastra | Agent tools support request-wide, per-tool, or conditional approval; callers explicitly approve or decline and resume, and a tool can also suspend after execution begins to request input. | Suspended tool/run state backed by configured storage; memory can automatically resume a suspended tool from a later conversational response. | Restart-safe resume depends on storage. The reviewed docs do not establish an authenticated operation snapshot or effect journal equivalent to Jidoka's. |
| LangGraph | `interrupt()` pauses a graph; a checkpointer saves graph state and `Command(resume=...)` continues it under the same thread ID. | Checkpoint plus `thread_id`. | The interrupted node restarts from its beginning, so code before the interrupt must be safe to repeat. Production persistence requires a durable checkpointer. |
| Pydantic AI | A tool marked `requires_approval` yields `DeferredToolRequests`; the caller returns approvals or denials by tool-call ID in a later run. | Original message history plus `DeferredToolResults`. | Approval is explicitly not an authorization boundary; the application must authenticate the caller and authorize sensitive work. |
| OpenAI Agents SDK | Tools marked `needs_approval` produce interruptions; callers convert the result to `RunState`, approve or reject call IDs, and resume the top-level agent. | Serializable `RunState`. | Approval decisions are scoped to call IDs. Durable storage and the surrounding authorization boundary belong to the application. |
| Google ADK | Experimental tool confirmation supports boolean or structured confirmation, conditional predicates, and resume through the Runner or REST; graph `RequestInput` remains the general human-input node. | Invocation/session state plus confirmation response. | Core resume is at-least-once, feature support is language/version gated, and confirmation is not exactly-once effect execution. |
| LlamaIndex Workflows | `InputRequiredEvent` and `HumanResponseEvent` pause and continue a workflow; web applications can snapshot and restore workflow context across requests. | Stored workflow-context snapshot. | Code before `wait_for_event()` is replayed. The event-pair pattern is recommended when repeat safety matters. |
| AutoGen AgentChat | `UserProxyAgent` can block for immediate feedback; asynchronous feedback is modeled by terminating a run, saving team state, and starting the next run with feedback. | Application-persisted team state between runs. | The blocking `UserProxyAgent` path is explicitly not save/resume safe. Resumable approval is therefore application-managed rather than one portable pending-tool primitive. |
| Jidoka | An operation approval policy creates a `Review.Request` and hibernates at a `:review` cursor before effect interpretation. `Jidoka.approve/3` or `deny/3` targets the interrupt and resumes the pending intent. | Versioned, HMAC-authenticated `AgentSnapshot` containing turn state, cursor, interrupt, and journal. | Snapshot storage and approver authentication/authorization remain application responsibilities. A review snapshot must be consumed once and its successful result persisted; this example does not claim exactly-once execution from repeatedly resuming the original pre-result snapshot. |

## Executable Jidoka proof

Parity tests are opt-in and must be run from the repository root.

Run only this comparison:

```bash
mix test --only parity:resumable_tool_approval test/parity --trace
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
`Result: 1 passed`. The `--only parity:resumable_tool_approval` filter overrides
the normal parity exclusion and selects the value assigned by
`use Jidoka.ParityCase, parity: :resumable_tool_approval`.

The tagged integration test uses a real `Jidoka.Agent` definition and the public
runtime facade. It injects deterministic model and operation capabilities so it
needs no API key and proves behavior rather than model prose. Parity tests are
excluded from normal `mix test` runs.

The test fails if any assertion is false. A passing run proves:

- `issue_refund` is declared `:unsafe_once` with an approval policy;
- the turn hibernates at `:review` before the refund capability runs;
- `Jidoka.pending_reviews/1` exposes the operation, complete validated arguments,
  policy reason, expiry, message, and risk metadata;
- the snapshot round-trips through Jidoka's signed opaque serialization;
- a payload mutation that preserves the original signature is rejected through
  both snapshot deserialization and the public approval facade;
- an approval aimed at the wrong interrupt is rejected before the refund runs;
- approving the serialized snapshot passes the reviewed arguments to the real
  action exactly once and journals the matching operation intent and result;
- the model receives the successful operation as a prompt tool observation;
- the event stream orders approval before the single capability lifecycle; and
- denying a fresh request executes no additional refund.

## What this does not claim

- The test does not provide a production database, queue, or operator UI.
- Jidoka correlates the response to the pending interrupt, but the application
  must authenticate the reviewer and authorize that principal for the refund.
- Logical review IDs and signed snapshots do not replace tenant isolation,
  secret management, or an application transaction around result persistence.
- The exactly-once proof is scoped to one approved resume. Applications must
  consume each pre-result snapshot once and persist the resulting journal or
  `Turn.Result` before acknowledging completion.

## Official sources

- [Mastra agent approval](https://mastra.ai/docs/agents/agent-approval)
- [LangGraph interrupts](https://docs.langchain.com/oss/python/langgraph/interrupts)
- [Pydantic AI deferred tools](https://pydantic.dev/docs/ai/tools-toolsets/deferred-tools/)
- [OpenAI Agents SDK human-in-the-loop](https://openai.github.io/openai-agents-python/human_in_the_loop/)
- [Google ADK tool confirmation](https://adk.dev/tools/confirmation/)
- [LlamaIndex Workflows human-in-the-loop](https://developers.llamaindex.ai/python/llamaagents/workflows/human_in_the_loop/)
- [AutoGen human-in-the-loop](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/human-in-the-loop.html)
