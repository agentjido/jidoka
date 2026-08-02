# Support Agent

The Support Agent is a complete deterministic Jidoka example. Its one scenario,
`controlled_tool_call`, follows this path:

```text
request
  -> scripted model tool request
  -> operation control
  -> action or interrupt
  -> operation result
  -> next scripted model observation
  -> final result
```

The runtime invariant tests have three deterministic cases:

- `allowed_round_trip` verifies tool calling, operation control, and tool
  observation.
- `interrupted_and_approved` verifies operation control, human review,
  snapshot serialization, and exact resume.
- `not_found_result` verifies that a sparse action result reaches the next
  model input without malformed answer text.

The agent and action are components that these cases use. The cases do not
claim to prove their complete public contracts.

## Read It In This Order

1. `lib/agent.ex` - the agent instructions, context, tool, and control.
2. `lib/actions/lookup_order.ex` - the application operation.
3. `lib/controls/require_order_approval.ex` - the allow-or-review policy.
4. `lib/scenario.ex` - deterministic demo wiring.
5. `test/controlled_tool_call_test.exs` - application behavior and runtime
   guarantees.
6. `support_agent.livemd` - the complete interactive walkthrough.

The agent, action, and control are application patterns that you can copy.
`ScriptedLLM`, `scenario.ex`, `example.exs`, the manifest, and the tests are
demo and verification code. In production, configure a real model on the agent
instead of passing the scripted `:llm` capability.

## Run It

Run the command demonstration:

```bash
mix run examples/support_agent/example.exs
```

Run the example tests with normal ExUnit output:

```bash
mix test examples/support_agent/test/controlled_tool_call_test.exs --trace
```

Run the scenario through its native ExUnit tag:

```bash
mix test --only example:support_agent
mix test --only tool_calling
mix test --only serializable_pause_resume
```

Open `support_agent.livemd` for the executable walkthrough. Start the Phoenix
application in `showcase/` and open `/agents/support` for the curated UI.

No path uses a real LLM, provider key, network request, or recorded fixture.
The local scripted model is in `lib/scripted_llm.ex`.

The command runner and Livebook set a predictable local snapshot signing
secret so the serialization step runs without application setup. Production
applications must set their own private `:snapshot_signing_secret` value or
`JIDOKA_SNAPSHOT_SIGNING_SECRET` environment variable.
