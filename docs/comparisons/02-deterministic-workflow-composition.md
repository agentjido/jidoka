# Use Case 02: Deterministic Workflow Composition

## Comparison contract

An application needs deterministic control flow around agent capabilities. The
runtime must choose one branch, fan work out concurrently without changing
input order at the reduction boundary, reduce an empty input, retry failed work
only to an exact bound, and expose the same workflow to an agent as one
operation.

This comparison treats six properties as distinct:

1. a gate executes only the selected branch;
2. concurrent item completion does not determine reduction order;
3. an empty fanout still reaches the reducer with an empty list;
4. retry success and exhaustion honor their configured attempt bounds;
5. direct and agent-mediated execution return the same workflow output; and
6. the agent path exposes one inspectable workflow intent and result.

Atomic features: `E03` ordered parallel tool execution, `W01` sequential typed
steps, `W02` conditional routing, `W03` fan-out/fan-in, `W05` bounded retry, and
`W06` workflow-as-tool composition.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented mechanism | Composition surface | Important boundary |
| --- | --- | --- | --- |
| Mastra | `createWorkflow()` composes typed steps with `.then()`, `.parallel()`, `.branch()`, and concurrent `.foreach()`; `foreach` output order follows input order. | Workflow steps can call agents and tools or compose them directly as steps. | The reviewed pages establish agent/tool use inside a workflow, not this proof's same-workflow-as-one-agent-operation boundary. Mastra also documents a broader workflow lifecycle than this bounded contract. |
| LangGraph | `StateGraph` and the Functional API express routing, parallelization, and shared-state aggregation with reducers. | Applications can invoke graphs directly and wrap agents or tools as nodes. | LangGraph's state-channel and checkpoint semantics differ from Jidoka's step-value DSL. This proof does not compare persistence or replay. |
| Pydantic AI | The graph builder provides decisions, broadcasts/maps, joins, and reducers for typed graph construction. | `GraphBuilder` compiles the application graph for execution. | The reviewed graph-builder pages establish generic graph composition, not this exact agent-tool exposure or stable list-order contract. |
| OpenAI Agents SDK | Deterministic orchestration is ordinary Python: chain agent runs, branch or loop in code, and use `asyncio.gather` for parallel work; agents can also be exposed as tools. | Application code owns the orchestration loop and calls `Runner`. | The SDK does not present the same dedicated workflow DSL in the reviewed guide. Retry and aggregation semantics therefore belong to application code for this contract. |
| Google ADK | `GraphBuilder` defines nodes, directed edges, conditional routing, and fan-out/fan-in graph workflows. | Agent, tool, and function nodes participate in one graph. | The graph documentation establishes topology and routing, but this comparison does not claim identical ordered fan-in or retry semantics. |
| LlamaIndex Workflows | Event-driven steps branch by returning different events, loop by emitting earlier events, and launch concurrent work by returning lists of events before a collecting step accepts the list. | A workflow coordinates ordinary functions, agents, and services through events. | Event collection is a different abstraction. The reviewed overview does not establish this comparison's exact stable ordering and bounded-retry contract. |
| AutoGen AgentChat | Experimental `GraphFlow` defines directed agent graphs with sequential, parallel, conditional, and looping execution. | A graph-directed team coordinates agent nodes and activation conditions. | `GraphFlow` is explicitly experimental and agent-team oriented. This proof does not claim parity with group-chat behavior or a general retry DSL. |
| Jidoka | The public `Jidoka.Workflow` DSL composes `gate`, concurrent `map`, `reduce`, and per-step bounded `retry` declarations. | The same workflow module runs through `Jidoka.Workflow.run/3` or is declared once in an agent `tools` block as a workflow operation. | The executable proof is in-process and bounded. It does not establish durable execution, scheduling, dynamic graph mutation, or unbounded loops. |

## Executable Jidoka proof

Parity tests are opt-in and must be run from the repository root.

Run only this comparison:

```bash
mix test --only parity:deterministic_workflow_composition test/parity --trace
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
`Result: 1 passed`. The `--only parity:deterministic_workflow_composition`
filter overrides the normal parity exclusion and selects the value assigned by
`use Jidoka.ParityCase, parity: :deterministic_workflow_composition`.

The tagged integration test builds workflows with the public DSL and calls the
public workflow and agent APIs. A scripted model capability makes one workflow
operation request and then returns a final response, so the proof needs no API
key and does not rely on model prose.

The test fails if any assertion is false. A passing run proves:

- the eligible and ineligible inputs execute only their corresponding branch;
- three map workers start together and process barriers release them in the
  deliberate completion order `2, 1, 0`, without sleeps;
- the reducer nevertheless receives values in input order `3, 1, 2`;
- an empty input invokes the reducer once with `[]` and returns a zero total;
- a transient failure succeeds on exactly attempt three;
- a permanent failure returns `{:retry_exhausted, 2, :still_failing}` after
  exactly two calls;
- direct execution and the structured workflow operation return the same
  workflow output;
- the agent spec publicly identifies the operation as `:workflow`; and
- the turn contains exactly one workflow operation intent, one operation
  result, and a journal result whose ID and output match that operation.

## What this does not claim

- The proof does not provide a durable workflow store, scheduler, distributed
  queue, or crash recovery.
- Process barriers establish completion order, not throughput or a performance
  advantage.
- The retry targets are deterministic and side-effect free. Retrying external
  side effects still requires appropriate idempotency and reconciliation.
- The scenario covers one bounded branch/map/reduce graph, not dynamic graph
  mutation, cancellation, backpressure, or arbitrary looping.
- One scripted operation decision proves the agent integration boundary; it
  does not claim that a probabilistic model will always choose the workflow.
- Competitor rows summarize documented mechanisms, not full behavioral
  equivalence across every framework feature.

## Official sources

- [Mastra workflow control flow](https://mastra.ai/docs/workflows/control-flow)
- [Mastra workflows with agents and tools](https://mastra.ai/docs/workflows/agents-and-tools)
- [LangGraph workflows and agents](https://docs.langchain.com/oss/python/langgraph/workflows-agents)
- [Pydantic AI graph-builder decisions](https://pydantic.dev/docs/ai/graph/builder/decisions)
- [Pydantic AI graph-builder joins and reducers](https://pydantic.dev/docs/ai/graph/builder/joins)
- [OpenAI Agents SDK orchestration](https://openai.github.io/openai-agents-python/multi_agent/)
- [Google ADK graph workflows](https://adk.dev/graphs/)
- [LlamaIndex Workflows introduction](https://developers.llamaindex.ai/python/llamaagents/workflows/)
- [AutoGen GraphFlow](https://microsoft.github.io/autogen/dev/user-guide/agentchat-user-guide/graph-flow.html)
