# Agent Orchestration

Use this guide when more than one agent is involved in a user flow.

Jidoka has two orchestration primitives that look similar in the DSL but mean
different things:

- **Subagent**: run another agent for one bounded task inside the current turn.
  The parent keeps ownership and receives the child result.
- **Handoff**: record that another agent owns future turns for the
  conversation. The current turn completes, and your application routes the
  next user message to the recorded owner.

Both are authored in `tools do ... end`, both compile to operations, and both
can forward context. They differ in lifetime, ownership, and return shape.

## When To Use This

- Use **subagent** when a parent agent needs a specialist answer before it can
  finish its own response.
- Use **handoff** when the specialist should become the agent for the next user
  message.
- Use **workflow** instead when the steps are deterministic application logic
  and do not need another model persona.
- Use **Jido process hosting** separately when you need agents supervised in a
  process tree. Orchestration is about who does the work, not how processes are
  hosted.

## Quick Decision Table

| Question | Use |
| --- | --- |
| "Can another agent answer this side question for the parent?" | `subagent` |
| "Should a different persona own the next message?" | `handoff` |
| "Should the parent synthesize the child answer now?" | `subagent` |
| "Should the app route future turns elsewhere until reset?" | `handoff` |
| "Do I need an operation result in this turn?" | `subagent` |
| "Do I need durable routing state?" | `handoff` |

## Mental Model

```text
Subagent
user -> parent agent -> child agent turn -> child result -> parent final answer

Handoff
user -> current agent -> handoff record -> current final answer
next user message -> app dispatcher -> recorded owner agent
```

A subagent is a nested call. A handoff is routing state.

## Subagent Flow

Define a child agent with its own instructions, model, controls, and tools.

```elixir
defmodule MyApp.EvidenceAgent do
  use Jidoka.Agent

  agent :evidence_agent do
    model "openai:gpt-4o-mini"
    instructions "Answer one evidence question. Be concise."
  end
end
```

Register it in the parent agent.

```elixir
defmodule MyApp.SupportAgent do
  use Jidoka.Agent

  agent :support_agent do
    model "openai:gpt-4o-mini"
    instructions "Use evidence_specialist before answering disputed claims."
  end

  tools do
    subagent MyApp.EvidenceAgent,
      as: :evidence_specialist,
      description: "Checks one bounded evidence question.",
      timeout: 30_000,
      forward_context: {:only, [:tenant, :case_id]},
      result: :structured
  end
end
```

When the parent model calls `evidence_specialist`, Jidoka runs one child turn.
The child receives:

- `task` from the operation arguments as its input;
- forwarded context controlled by `forward_context:`;
- optional task-local `context` from the operation arguments;
- its own agent spec, controls, tools, model settings, and loop budget.

The parent receives an operation result like:

```elixir
%{
  subagent: "evidence_specialist",
  agent: "MyApp.EvidenceAgent",
  content: "The account was upgraded on May 12.",
  value: %{status: "confirmed"},
  operation_results: []
}
```

The parent then continues the same turn and produces the final answer.
Conversation ownership never changes.

## Handoff Flow

Define the target agent that should own future turns.

```elixir
defmodule MyApp.BillingAgent do
  use Jidoka.Agent

  agent :billing_agent do
    model "openai:gpt-4o-mini"
    instructions "Own billing follow-up."
  end
end
```

Register a handoff operation in the current agent.

```elixir
defmodule MyApp.SupportRouter do
  use Jidoka.Agent

  agent :support_router do
    model "openai:gpt-4o-mini"
    instructions "Hand off billing issues to billing_specialist."
  end

  tools do
    handoff MyApp.BillingAgent,
      as: :billing_specialist,
      description: "Transfers future billing follow-up to billing.",
      forward_context: {:only, [:tenant, :case_id, :session_id]}
  end
end
```

When the model calls `billing_specialist`, Jidoka records a
`Jidoka.Handoff` in the owner store. The handoff contains:

- `conversation_id`;
- source and target agent information;
- target `agent_id`;
- handoff `message`;
- optional `summary` and `reason`;
- forwarded context.

The current agent still receives an operation result and finishes its response.
Jidoka does not automatically route the next user message. Your app dispatcher
does that:

```elixir
def dispatch(conversation_id, input, opts \\ []) do
  case Jidoka.handoff(conversation_id) do
    %{agent: owner_agent, handoff: handoff} ->
      owner_agent.chat(input,
        context: Map.merge(handoff.context, %{handoff_summary: handoff.summary})
      )

    nil ->
      MyApp.SupportRouter.chat(input, opts)
  end
end
```

Reset ownership when the specialist is done:

```elixir
:ok = Jidoka.reset_handoff("case-123")
```

## Context Rules

Subagents and handoffs both accept `forward_context:`.

| Policy | Behavior |
| --- | --- |
| `:public` | Forward the public parent context. |
| `:none` | Forward nothing. |
| `{:only, keys}` | Forward only listed keys. |
| `{:except, keys}` | Forward everything except listed keys. |

Prefer `{:only, keys}` for orchestration. It makes the boundary explicit and
keeps secrets out of child prompts and handoff records.

Operation arguments can also include a task-local `context` map. Jidoka merges
that with the forwarded context for the target.

When testing a DSL agent directly and you want operation sources to see the
same context as the turn request, put the data on the request `context:`:

```elixir
request =
  Jidoka.Turn.Request.new!(
    input: "Route this billing issue.",
    context: %{session_id: "case-123", tenant: "acme"}
  )

MyApp.SupportRouter.run_turn(request,
  llm: fake_llm
)
```

That is the context source used by `forward_context:`. Provider credentials,
runtime handles, and other private values belong in `operation_context:` and
are available through `Jidoka.Context.get_runtime/3`.

## Result And Ownership Rules

| Concern | Subagent | Handoff |
| --- | --- | --- |
| Current turn | Parent waits for child result. | Current agent records transfer and finishes. |
| Future turns | Parent still owns them. | Target agent owns them until reset. |
| Return shape | Child content, value, and child operation results. | Handoff payload plus owner projection. |
| Safety | `:idempotent` by default. | `:unsafe_once`; gate with approval or a control when needed. |
| Storage | No routing state is written. | Owner store records the target. |

## Testing Pattern

Test subagents by asserting the child agent actually received the bounded task
and that the parent saw the child result.

```elixir
assert {:ok, result} =
         MyApp.SupportAgent.run_turn(
           Jidoka.Turn.Request.new!(
             input: "Check the evidence.",
             context: %{tenant: "acme", secret: "do-not-forward"}
           ),
           llm: fake_llm,
           operation_context: %{subagent_llm: fake_llm}
         )

assert [%{operation: "evidence_specialist", output: output}] =
         Enum.map(result.agent_state.operation_results, &Jidoka.project/1)

assert output.content =~ "confirmed"
```

Test handoffs by asserting ownership was recorded, then call your dispatcher
with the next user message.

```elixir
request =
  Jidoka.Turn.Request.new!(
    input: "This is a billing issue.",
    context: %{session_id: "case-123", tenant: "acme"}
  )

assert {:ok, _result} =
         MyApp.SupportRouter.run_turn(request,
           llm: fake_llm
         )

assert %{agent: MyApp.BillingAgent, handoff: handoff} =
         Jidoka.handoff("case-123")

assert handoff.context == %{tenant: "acme", session_id: "case-123"}

assert {:ok, _reply} = dispatch("case-123", "What happens next?")
```

Reset handoff state in `setup` or `on_exit` when tests use the default
in-memory owner store.

## Common Frictions

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| Child agent sees too much context | `forward_context: :public` was too broad. | Use `{:only, [...]}`. |
| Parent expects future routing after subagent | Wrong primitive. | Use `handoff`. |
| Handoff records owner but next message still hits router | App dispatcher does not read `Jidoka.handoff/1`. | Add routing before default agent selection. |
| Handoff result lacks conversation id | No `conversation_id`, `conversation`, or `session_id` was present. | Pass one in arguments or context. |
| Child hibernates during subagent call | Subagent hit HITL or checkpoint behavior. | Keep subagents bounded, or handle `{:subagent_hibernated, ...}` as an operation error. |

## Related Guides

- [Agent DSL](agent-dsl.md) - how `subagent` and `handoff` are authored.
- [Skill, Workflow, And Subagent Tools](skill-workflow-subagent-tools.md) -
  detailed subagent source behavior with skills and workflows.
- [Handoffs](handoffs.md) - storage, routing, controls, and reset behavior.
- [Tools And Operations](tools-and-operations.md) - shared operation contract.
- [Controls](controls.md) - operation controls for handoff approval.
