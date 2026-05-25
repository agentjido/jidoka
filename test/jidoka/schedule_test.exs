defmodule JidokaTest.ScheduleTest do
  use JidokaTest.Support.Case, async: false

  alias Jidoka.{Schedule, Session}
  alias JidokaTest.ChatAgent
  alias JidokaTest.Workflow.ToolOnlyWorkflow

  setup do
    manager = :"schedule_manager_#{System.unique_integer([:positive])}"

    start_supervised!({Jidoka.Schedule.Manager, name: manager, id: manager, schedules: [], history_limit: 5})

    %{manager: manager}
  end

  test "exports public schedule APIs" do
    assert function_exported?(Jidoka, :schedule, 2)
    assert function_exported?(Jidoka, :schedule_agent, 2)
    assert function_exported?(Jidoka, :schedule_workflow, 2)
    assert function_exported?(Jidoka, :list_schedules, 1)
    assert function_exported?(Jidoka, :cancel_schedule, 2)
    assert function_exported?(Jidoka, :run_schedule, 2)
  end

  test "validates schedule options" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Schedule.new(ToolOnlyWorkflow, kind: :workflow, id: "", cron: "* * * * *")

    assert error.field == :id

    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Schedule.new(ToolOnlyWorkflow, kind: :agent, id: "missing-prompt", cron: "* * * * *")

    assert error.field == :prompt
  end

  test "normalizes accepted schedule option shapes" do
    assert {:ok, %Schedule{} = schedule} =
             Schedule.new(ToolOnlyWorkflow,
               kind: :workflow,
               id: :daily_report,
               cron: " 0 9 * * * ",
               timezone: "",
               input: [value: 5],
               context: [tenant: "demo"],
               conversation: " support-digest ",
               opts: [trace?: true],
               start_opts: [name: :ignored_for_workflows],
               timeout: 1_000,
               overlap: :allow,
               enabled: false
             )

    assert schedule.id == "daily_report"
    assert schedule.cron == "0 9 * * *"
    assert schedule.timezone == Schedule.default_timezone()
    assert schedule.input == [value: 5]
    assert schedule.context == [tenant: "demo"]
    assert schedule.conversation == "support-digest"
    assert schedule.opts == [trace?: true]
    assert schedule.start_opts == [name: :ignored_for_workflows]
    assert schedule.timeout == 1_000
    assert schedule.overlap == :allow
    refute schedule.enabled?
  end

  test "returns validation errors for invalid schedule option shapes" do
    invalid_options = [
      {[kind: :other], :kind},
      {[timezone: 123], :timezone},
      {[overlap: :queue], :overlap},
      {[enabled?: :yes], :enabled?},
      {[timeout: 0], :timeout},
      {[context: [:not_a_pair]], :context},
      {[runtime: "runtime"], :runtime},
      {[opts: [:not_a_pair]], :opts},
      {[start_opts: [:not_a_pair]], :opts},
      {[conversation: :daily], :conversation}
    ]

    for {extra_opts, field} <- invalid_options do
      assert {:error, %Jidoka.Error.ValidationError{} = error} =
               Schedule.new(
                 ToolOnlyWorkflow,
                 Keyword.merge(
                   [kind: :workflow, id: "invalid-#{field}", cron: "0 9 * * *", input: %{value: 5}],
                   extra_opts
                 )
               )

      assert error.field == field
    end
  end

  test "registers, lists, and cancels disabled schedules", %{manager: manager} do
    assert {:ok, %Schedule{id: "disabled-digest", status: :disabled, scheduler_pid: nil}} =
             Jidoka.schedule_workflow(ToolOnlyWorkflow,
               id: "disabled-digest",
               cron: "0 9 * * *",
               input: %{value: 5},
               enabled?: false,
               manager: manager
             )

    assert {:ok, [%Schedule{id: "disabled-digest"}]} = Jidoka.list_schedules(manager: manager)
    assert :ok = Jidoka.cancel_schedule("disabled-digest", manager: manager)
    assert {:ok, []} = Jidoka.list_schedules(manager: manager)
  end

  test "rejects duplicate schedule ids unless replaced", %{manager: manager} do
    opts = [
      id: "duplicate",
      cron: "0 9 * * *",
      input: %{value: 5},
      enabled?: false,
      manager: manager
    ]

    assert {:ok, %Schedule{}} = Jidoka.schedule_workflow(ToolOnlyWorkflow, opts)
    assert {:error, %Jidoka.Error.ValidationError{} = error} = Jidoka.schedule_workflow(ToolOnlyWorkflow, opts)
    assert error.message =~ "already registered"

    assert {:ok, %Schedule{id: "duplicate"}} =
             Jidoka.schedule_workflow(ToolOnlyWorkflow, Keyword.put(opts, :replace, true))
  end

  test "validates enabled cron expressions at registration time", %{manager: manager} do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.schedule_workflow(ToolOnlyWorkflow,
               id: "bad-cron",
               cron: "not a cron",
               input: %{value: 5},
               manager: manager
             )

    assert error.field == :cron
  end

  test "starts a manager with initial schedules and supports list limits" do
    assert {:ok, schedule} =
             Schedule.new(ToolOnlyWorkflow,
               kind: :workflow,
               id: "initial",
               cron: "0 9 * * *",
               input: %{value: 5},
               enabled?: false
             )

    manager = :"initial_schedule_manager_#{System.unique_integer([:positive])}"
    start_supervised!({Jidoka.Schedule.Manager, name: manager, id: manager, schedules: [schedule]})

    assert {:ok, [%Schedule{id: "initial"}]} = Jidoka.list_schedules(manager: manager, limit: 1)
    assert {:ok, []} = Jidoka.list_schedules(manager: manager, limit: 0)
    assert {:error, :not_found} = Jidoka.cancel_schedule("missing", manager: manager)
  end

  test "runs a workflow schedule manually and records bounded history", %{manager: manager} do
    assert {:ok, %Schedule{id: "math-workflow"}} =
             Jidoka.schedule_workflow(ToolOnlyWorkflow,
               id: "math-workflow",
               cron: "0 9 * * *",
               input: %{value: 5},
               enabled?: false,
               manager: manager
             )

    assert {:ok, run} = Jidoka.run_schedule("math-workflow", manager: manager)
    assert run.status == :completed
    assert run.result == {:ok, %{value: 12}}
    assert is_binary(run.request_id)

    assert {:ok, [%Schedule{} = schedule]} = Jidoka.list_schedules(manager: manager)
    assert schedule.run_count == 1
    assert schedule.status == :disabled
    assert schedule.last_status == :completed
    assert hd(schedule.history).status == :completed
    refute Map.has_key?(hd(schedule.history), :result)

    assert {:ok, trace} = Jidoka.Trace.for_request(ToolOnlyWorkflow.id(), run.request_id)
    assert Enum.any?(trace.events, &(&1.category == :schedule and &1.event == :start))
    assert Enum.any?(trace.events, &(&1.category == :schedule and &1.event == :stop))
  end

  test "manual agent schedule failures are captured as failed runs", %{manager: manager} do
    assert {:ok, %Schedule{id: "missing-agent"}} =
             Jidoka.schedule_agent("missing-agent-id",
               id: "missing-agent",
               cron: "0 9 * * *",
               prompt: "Run a digest.",
               enabled?: false,
               manager: manager
             )

    assert {:ok, run} = Jidoka.run_schedule("missing-agent", manager: manager)
    assert run.status == :failed
    assert {:error, %Jidoka.Error.ValidationError{}} = run.result

    assert {:ok, [%Schedule{} = schedule]} = Jidoka.list_schedules(manager: manager)
    assert schedule.run_count == 1
    assert schedule.last_status == :failed
    assert schedule.last_error =~ "could not be found"
  end

  test "generated agents expose declared schedules" do
    assert [%Schedule{} = schedule] = JidokaTest.ScheduledAgent.schedules()
    assert [%Schedule{} = resolved] = Jidoka.Agent.Definition.ScheduleConfig.resolve!(JidokaTest.ScheduledAgent)

    assert schedule.id == "scheduled_agent:daily_digest"
    assert schedule.agent_id == "scheduled_agent:daily_digest"
    assert schedule.target == JidokaTest.ScheduledAgent
    assert schedule.cron == "0 9 * * *"
    assert schedule.timezone == "America/Chicago"
    assert schedule.conversation == "support-digest"
    assert schedule.overlap == :skip
    assert resolved == schedule
  end

  test "generated schedule metadata is available through public and runtime definitions" do
    assert [public_schedule] = JidokaTest.ScheduledAgent.schedules()
    assert JidokaTest.ScheduledAgent.__jidoka__().schedules == [public_schedule]
    assert JidokaTest.ScheduledAgent.runtime_module().__jidoka_definition__().schedules == [public_schedule]

    assert public_schedule.kind == :agent
    assert public_schedule.prompt == {JidokaTest.ScheduleCallbacks, :support_digest_prompt, []}
    assert public_schedule.context == {JidokaTest.ScheduleCallbacks, :support_digest_context, []}
    assert public_schedule.timeout == 30_000
    assert public_schedule.enabled?
    assert public_schedule.scheduler_pid == nil
    assert public_schedule.run_count == 0
    assert public_schedule.history == []
  end

  test "runs a session target schedule through Jidoka.chat", %{manager: manager} do
    session =
      Session.new!(
        agent: ChatAgent,
        id: "scheduled-session-#{System.unique_integer([:positive, :monotonic])}",
        context: %{tenant: "acme"}
      )

    test_pid = self()

    guardrail = fn input ->
      send(test_pid, {:scheduled_session_context, input.context})
      {:interrupt, %{kind: :approval, message: "Scheduled stop", data: %{}}}
    end

    assert {:ok, %Schedule{} = schedule} =
             Jidoka.schedule(session,
               id: "session-schedule",
               cron: "0 9 * * *",
               prompt: "Check in.",
               context: %{channel: "schedule"},
               opts: [guardrails: [input: guardrail]],
               enabled?: false,
               manager: manager
             )

    assert schedule.target == session
    assert schedule.agent_id == session.agent_id

    try do
      assert {:ok, run} = Jidoka.run_schedule("session-schedule", manager: manager)
      assert run.status == :interrupted
      assert {:interrupt, %Jidoka.Interrupt{message: "Scheduled stop"}} = run.result

      assert_receive {:scheduled_session_context, %{session: session_id, tenant: "acme", channel: "schedule"}}

      assert session_id == session.id

      assert {:ok, [%Schedule{} = updated]} = Jidoka.list_schedules(manager: manager)
      assert updated.last_status == :interrupted
      assert hd(updated.history).status == :interrupted
    after
      case Session.whereis(session) do
        pid when is_pid(pid) -> Jidoka.stop_agent(pid)
        nil -> :ok
      end
    end
  end

  test "rejects session schedules with mismatched explicit agent ids" do
    session = Session.new!(agent: ChatAgent, id: "scheduled-session-mismatch")

    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Schedule.new(session,
               kind: :agent,
               id: "bad-session-schedule",
               cron: "0 9 * * *",
               prompt: "Check in.",
               agent_id: "other-agent"
             )

    assert error.field == :agent_id
    assert error.details.reason == :session_agent_id_mismatch
  end
end
