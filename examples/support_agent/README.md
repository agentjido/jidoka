# Support Agent

The Support Agent is the first complete Jidoka proof example. Its one scenario,
`controlled_tool_call`, follows this path:

```text
request
  -> Mock LLM tool request
  -> operation control
  -> action or interrupt
  -> operation result
  -> next Mock LLM observation
  -> final result
```

The scenario has three deterministic cases:

- `allowed_round_trip` verifies tool calling, operation control, and tool
  observation.
- `interrupted_and_approved` verifies operation control, human review, and
  snapshot resume.
- `not_found_result` verifies that a sparse action result reaches the next
  model input without malformed answer text.

The agent and action are components that these cases use. The cases do not
claim to prove their complete public contracts.

## Run It

Run the command demonstration:

```bash
mix jidoka.example support_agent
```

Run the three proof cases with normal ExUnit output:

```bash
mix test examples/support_agent/test/controlled_tool_call_test.exs --trace
```

Check every Support Agent surface:

```bash
mix jidoka.examples.check --example support_agent
mix jidoka.examples.check --example support_agent --verbose
```

Open `support_agent.livemd` for the executable walkthrough. Start the Phoenix
application in `showcase/` and open `/agents/support` for the curated UI.

No path uses a real LLM, provider key, network request, or recorded fixture.
