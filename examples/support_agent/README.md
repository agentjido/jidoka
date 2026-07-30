# Support Agent

This example shows a small order-support agent with one action and one
operation control.

The deterministic path is:

1. The Mock LLM requests `lookup_order`.
2. The operation control checks whether order access needs human review.
3. Jidoka runs the action when access is allowed.
4. Jidoka puts the action result in the next model prompt.
5. The Mock LLM uses the order result in its final answer.

When the request context contains a credential reference, the control pauses
the turn before the action runs. The ExUnit test also proves that this snapshot
can resume after approval.

Run the example:

```bash
mix jidoka.example support_agent
```

Run its test:

```bash
mix test examples/support_agent/support_agent_test.exs
```

Open `examples/support_agent/support_agent.livemd` for the executable
walkthrough.
