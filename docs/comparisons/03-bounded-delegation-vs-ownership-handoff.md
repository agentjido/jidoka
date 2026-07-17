# Use Case 03: Bounded Delegation Versus Ownership Handoff

## Comparison contract

A router asks a specialist to complete one bounded task, receives the result,
and remains responsible for the current conversation. In a separate path, the
router explicitly hands the conversation to that specialist and records enough
public routing data for the application to send later turns to the new owner.

This comparison treats seven properties as distinct:

1. bounded delegation returns a child result to the parent;
2. inherited child context is allowlisted and excludes a parent secret;
3. bounded delegation does not change conversation ownership;
4. a handoff is an explicitly allowed operation that records target ownership;
5. handoff context is a public, inspectable projection rather than hidden runtime state;
6. direct invocation of the router still invokes the router; and
7. application dispatch through the recorded owner reaches the specialist until reset.

Atomic features: `M01` manager-owned delegation, `M02` future-turn ownership
handoff, and `M05` context and memory isolation.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Manager-owned delegation | Handoff or active-agent mechanism | Important boundary |
| --- | --- | --- | --- |
| Mastra | A supervisor registers subagents on `agents`; delegated calls return results for supervisor synthesis. Delegation hooks and `messageFilter` control the call boundary. | Mastra documents handoff as an ownership-moving pattern implemented with agents, workflows, and memory, while a supervisor remains in charge for the full task. | The supervisor API is a concrete manager loop. The reviewed handoff material is an application composition pattern, not a per-conversation owner lookup/reset contract. |
| LangGraph | The subagents pattern wraps specialists as tools; the main agent controls routing, memory, and synthesis, and subagents return to it. | Handoff tools return `Command` updates such as `active_agent` or `current_step`; a graph routes to the selected agent and a checkpointer can preserve that state across turns. | The graph schema, context projection, and production checkpointer are application choices. A state variable is not by itself an authorization boundary. |
| Pydantic AI | Agent delegation calls a delegate from a parent tool and returns the delegate output to the controlling agent. | Programmatic hand-off means application code or a human decides which agent to run next and explicitly passes any message history. | Agents are stateless; the documented hand-off does not install a framework-owned conversation owner. The application owns continuation and persistence. |
| OpenAI Agents SDK | `Agent.as_tool()` lets a manager call a specialist and then continue the original agent conversation. | A handoff tool transfers the active run to another agent. `RunResult.last_agent` identifies the agent that should usually start the next user turn. | The runner follows handoffs within a run; the application still decides how to persist the result and which `last_agent` to supply on a later request. |
| Google ADK | In task and single-turn collaboration modes, a coordinator delegates to a subagent and control automatically returns with the result. | Chat-mode subagents retain control until a manual transfer; ADK session services preserve conversation history and state used by subsequent runs. | Mode changes control semantics. The documented in-memory session service is non-persistent, and production routing depends on the selected runner/session implementation. |
| LlamaIndex | The orchestrator pattern exposes specialist `run` methods as tools, and every tool returns to the orchestrator. | `AgentWorkflow` manages a linear swarm in which the active agent can hand control to another agent until one returns a final answer. | `AgentWorkflow` owns active control inside its workflow context. Cross-request durability depends on retaining or persisting the workflow context; it is not a separate owner-directory API. |
| AutoGen | `AgentTool` wraps a stateful agent as a tool and returns its `TaskResult` to the calling agent; parallel tool calls must be disabled for this path. | `Swarm` selects the next speaker from the latest `HandoffMessage`; its saved manager state includes the current speaker and message thread. | `save_state()` returns serializable state, but the application must store and reload it. A handoff message changes team routing, not an external durable owner record. |
| Jidoka | A `subagent` DSL entry compiles to an idempotent operation, runs one child turn, returns a structured result to the parent, and can forward only selected public context. | A `handoff` DSL entry compiles to an `:unsafe_once` operation. After an explicit control allows it, the operation returns public handoff/owner data and records the owner for future app dispatch. | Jidoka does not automatically reroute a direct agent call. The application reads `Jidoka.handoff/1` and invokes its `agent`; `reset_handoff/1` restores default routing. The default owner store is supervised node-local in-memory ETS, so it survives the request process that records a handoff. Clustered or durable routing requires a configured store. |

## Executable Jidoka proof

Parity tests are opt-in and must be run from the repository root.

Run only this comparison:

```bash
mix test --only parity:bounded_delegation_vs_ownership_handoff test/parity --trace
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
`Result: 1 passed`. The `--only` filter selects the value assigned by
`use Jidoka.ParityCase, parity: :bounded_delegation_vs_ownership_handoff`.

The tagged integration test defines real `subagent` and `handoff` DSL paths and
injects deterministic model capabilities, so it needs no API key. The test uses
a unique conversation ID, records the handoff from a monitored short-lived
process, waits for that process to exit, and registers an `on_exit` reset without
comparing generated IDs or timestamps.

The test fails if any assertion is false. A passing run proves:

- the bounded child result returns as an ordinary operation result and the parent finishes the turn;
- only the allowlisted `tenant` value reaches the child, while `secret` is absent;
- delegation leaves `Jidoka.handoff/1` empty;
- the handoff is an `:unsafe_once` operation admitted by an explicit matching control;
- its ordinary operation result exposes the target owner and allowlisted public context;
- after the handoff-producing process exits, the same owner projection remains available from `Jidoka.handoff/1` without asserting its timestamp;
- directly calling the router still executes the router even while an owner is recorded;
- an application-selected fresh request through `Jidoka.handoff(id).agent` reaches the specialist; and
- `Jidoka.reset_handoff/1` removes the owner.

## What this does not claim

- The default supervised ETS owner store survives request-process exit but not an owner-store, application, or node restart, and it is not a clustered routing database.
- Jidoka records routing data but deliberately does not intercept or rewrite direct module calls; the application dispatcher must consult it.
- The allowlist filters inherited public context. A caller that explicitly puts sensitive data into task-local operation arguments can still disclose it.
- The example control admits the handoff deterministically; a production application must authenticate the actor and apply its own authorization policy.
- A handoff result does not migrate sockets, queues, session history, or external side effects by itself.

## Official sources

- [Mastra supervisor agents](https://mastra.ai/docs/agents/supervisor-agents)
- [Mastra multi-agent systems](https://mastra.ai/guides/concepts/multi-agent-systems)
- [LangChain subagents](https://docs.langchain.com/oss/python/langchain/multi-agent/subagents)
- [LangChain handoffs with LangGraph state](https://docs.langchain.com/oss/python/langchain/multi-agent/handoffs)
- [Pydantic AI multi-agent patterns](https://pydantic.dev/docs/ai/guides/multi-agent-applications/)
- [OpenAI Agents SDK agent orchestration](https://openai.github.io/openai-agents-python/multi_agent/)
- [OpenAI Agents SDK tools](https://openai.github.io/openai-agents-python/tools/)
- [OpenAI Agents SDK handoffs](https://openai.github.io/openai-agents-python/handoffs/)
- [OpenAI Agents SDK results](https://openai.github.io/openai-agents-python/results/)
- [Google ADK collaborative workflows](https://adk.dev/workflows/collaboration/)
- [Google ADK agent team and session state](https://adk.dev/tutorials/agent-team/)
- [LlamaIndex multi-agent patterns](https://developers.llamaindex.ai/python/framework/understanding/agent/multi_agent/)
- [AutoGen agents and `AgentTool`](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/agents.html)
- [AutoGen teams](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/teams.html)
- [AutoGen Swarm](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/swarm.html)
- [AutoGen state management](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/state.html)
- [AutoGen AgentChat state reference](https://microsoft.github.io/autogen/stable/reference/python/autogen_agentchat.state.html)
