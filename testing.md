# Testing Jidoka Agents

Jidoka tests should start provider-free. Most agent behavior is ordinary Elixir:
schemas, actions, controls, workflows, schedules, traces, and request metadata
can be tested without asking a model to be deterministic.

Use live provider tests only for the final integration check.

## Testing Order

1. Contract tests: the agent compiles with the expected public contract.
2. Context tests: runtime context is shaped and merged correctly.
3. Action tests: deterministic operations work without an LLM.
4. Control tests: input, operation, and result policy returns the expected
   `:ok`, interrupt, or error shape.
5. Result tests: typed result contracts parse and validate raw output.
6. Workflow tests: deterministic multi-step processes run without the model.
7. Trace tests: request, tool, workflow, control, memory, compaction, and result
   events are visible.
8. Schedule tests: schedules validate and can be run manually without waiting
   for cron.
9. Live-provider tests: one or two end-to-end checks prove the configured model
   can run the agent.

## Contract Tests

Contract tests prove the module exposes the intended runtime surface.

```elixir
test "support agent contract is stable" do
  assert MyApp.SupportAgent.id() == "support_agent"
  assert function_exported?(MyApp.SupportAgent, :runtime_module, 0)
  assert MyApp.SupportAgent.tool_names() == ["load_ticket"]

  assert {:ok, definition} = Jidoka.inspect_agent(MyApp.SupportAgent)
  assert definition.context_schema
  assert definition.result
end
```

## Context Tests

Context is caller-provided runtime data. Test the merge at the session boundary
before testing a full turn.

```elixir
test "session context merges per turn context" do
  session =
    Jidoka.session(MyApp.SupportAgent, "ticket-123",
      context: %{account_id: "acct_123", actor_id: "user_1"}
    )

  opts = Jidoka.Session.chat_opts(session, context: %{actor_id: "user_2"})

  assert opts[:conversation] == "ticket-123"
  assert opts[:context].account_id == "acct_123"
  assert opts[:context].actor_id == "user_2"
end
```

## Action Tests

Actions are deterministic. Test them directly with plain Elixir data and a
small context map.

```elixir
test "load ticket action returns application data" do
  assert {:ok, %{id: "ticket-123", status: :open}} =
           MyApp.Actions.LoadTicket.run(%{id: "ticket-123"}, %{actor_id: "user_1"})
end
```

## Control Tests

Controls are policy. Test the return shape directly and keep the examples small.

```elixir
test "dangerous operation requires approval" do
  input = %Jidoka.Guardrails.Tool{
    agent: %{id: "support_agent"},
    server: self(),
    request_id: "req-test",
    operation_kind: :action,
    tool_name: "refund_customer",
    tool_call_id: "tool-call-test",
    arguments: %{amount: 5000},
    context: %{actor_id: "user_1"},
    metadata: %{},
    request_opts: %{}
  }

  assert {:interrupt, %Jidoka.Interrupt{kind: :approval}} =
           MyApp.Controls.RequireApproval.call(input)
end
```

## Result Tests

Typed results are final app-facing values. Test the contract with raw JSON and
maps before testing a live model response.

```elixir
test "ticket classification result parses" do
  result = MyApp.TicketClassifier.result()

  assert {:ok, %{category: :billing, confidence: 0.94}} =
           Jidoka.Output.parse(result, ~s({"category":"billing","confidence":0.94}))
end
```

## Workflow Tests

Workflows are deterministic orchestration. Test them by calling `run/2`.

```elixir
test "triage workflow runs in order" do
  assert {:ok, %{priority: :high, routed_to: :billing}} =
           MyApp.Workflows.Triage.run(%{ticket_id: "ticket-123"},
             context: %{account_id: "acct_123"}
           )
end
```

## Trace Tests

Trace tests should assert structure, not log text.

```elixir
test "trace records the scheduled workflow turn" do
  session = Jidoka.session(MyApp.SupportAgent, "trace-ticket-123")

  assert {:ok, _reply} = Jidoka.chat(session, "Summarize the ticket.")
  assert {:ok, trace} = Jidoka.inspect_trace(session)

  assert Enum.any?(trace.events, &(&1.category == :request))
end
```

## Schedule Tests

Do not wait for cron in unit tests. Build or register the schedule, then run it
manually through the manager/executor surface.

```elixir
test "scheduled support digest is runnable" do
  session = Jidoka.session(MyApp.SupportAgent, "daily-digest")

  assert {:ok, schedule} =
           Jidoka.schedule(session,
             id: :daily_digest,
             prompt: "Prepare the support digest.",
             cron: "0 9 * * *"
           )

  assert {:ok, run} = Jidoka.run_schedule(schedule.id)
  assert run.status in [:completed, :interrupted, :failed]
end
```

## Test Doubles

Prefer ordinary Elixir doubles at the Jidoka boundary. A test double should be
small, deterministic, and shaped like the production collaborator it replaces.

- For tools, define a tiny `use Jidoka.Action` module in `test/support`.
- For subagents, define a module with `runtime_module/0`, `start_link/1`, and
  `chat/3` that returns fixed data.
- For provider turns, use an input control that interrupts before the provider
  call when the test is about sessions, traces, schedules, or UI projection.
- For repair/summarization paths, inject the function or app config override the
  runtime already exposes instead of relying on a live model.

```elixir
stop_before_provider = fn input ->
  Jidoka.Approval.request("Stop before provider execution.",
    data: %{request_id: input.request_id}
  )
end

assert {:interrupt, %Jidoka.Interrupt{kind: :approval}} =
         Jidoka.chat(session, "test turn", controls: [input: stop_before_provider])
```

## Deterministic Actions

Actions should be testable without the agent loop. Put network, database, or
third-party boundaries behind your application modules, then pass fixture data
or a fake adapter through context.

```elixir
test "action uses the injected ticket repo" do
  repo = %{load_ticket: fn "ticket-123" -> %{id: "ticket-123", status: :open} end}

  assert {:ok, %{status: :open}} =
           MyApp.Actions.LoadTicket.run(%{id: "ticket-123"}, %{ticket_repo: repo})
end
```

This keeps action failures clear: schema validation belongs to the action
contract, business behavior belongs to the action test, and model behavior
belongs to a small number of live smoke tests.

## Trace Assertions

Trace tests should assert categories, events, IDs, and sanitized metadata. Avoid
asserting exact log lines, event order unrelated to the behavior under test, or
raw provider output.

```elixir
assert {:ok, trace} = Jidoka.inspect_trace(session)

assert Enum.any?(trace.events, fn event ->
         event.category == :guardrail and
           event.event in [:interrupt, :block, :allow] and
           event.request_id == request.request_id
       end)

refute inspect(trace.events) =~ "sk-ant-"
```

## Live-Provider Tests

Keep live tests few, tagged, explicitly gated, and shape-oriented. Do not assert
exact prose.

```elixir
@tag :llm_eval
test "support agent completes one live turn" do
  unless System.get_env("RUN_JIDOKA_LIVE_TESTS") == "1" &&
           System.get_env("ANTHROPIC_API_KEY") do
    flunk("Set RUN_JIDOKA_LIVE_TESTS=1 and ANTHROPIC_API_KEY for live tests")
  end

  session = Jidoka.session(MyApp.SupportAgent, "live-ticket-123")

  assert {:ok, result} =
           Jidoka.chat(session, "Classify this ticket: I need help with my invoice.")

  assert is_map(result) or is_binary(result)
end
```

By default, keep live tests excluded and run them deliberately:

```bash
mix test
RUN_JIDOKA_LIVE_TESTS=1 mix test --include llm_eval
```
