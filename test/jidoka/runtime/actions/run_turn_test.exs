defmodule Jidoka.Runtime.Actions.RunTurnTest.Support.CompleteAgent do
  alias Jidoka.Effect
  alias Jidoka.Turn

  def run_turn(%Turn.Request{} = request, opts) do
    if pid = opts[:operation_context][:test_pid] do
      send(pid, {:run_turn_opts, opts})
    end

    {:ok,
     Turn.Result.new!(
       content: "done",
       agent_state: request.agent_state,
       journal: Effect.Journal.new!()
     )}
  end
end

defmodule Jidoka.Runtime.Actions.RunTurnTest.Support.HibernateAgent do
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

  def run_turn(%Turn.Request{} = request, _opts) do
    spec =
      Jidoka.agent!(
        id: "hibernate_action_agent",
        instructions: "Hibernate from action.",
        model: %{provider: :test, id: "model"}
      )

    plan = Jidoka.plan!(spec)

    state =
      Turn.State.new!(spec: spec, plan: plan, request: request, agent_state: request.agent_state)

    {:hibernate, AgentSnapshot.from_turn_state!(state, Turn.Cursor.after_prompt())}
  end
end

defmodule Jidoka.Runtime.Actions.RunTurnTest.Support.RaisingAgent do
  def run_turn(_request, _opts), do: raise("boom")
end

defmodule Jidoka.Runtime.Actions.RunTurnTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Runtime.AgentServerState
  alias Jidoka.Runtime.Actions.RunTurn

  test "writes completed turn results into Jido agent state" do
    agent_state = Agent.State.new!(metadata: %{existing: true})

    context = %{
      agent: %{agent_module: Jidoka.Runtime.Actions.RunTurnTest.Support.CompleteAgent},
      state: %{jidoka: AgentServerState.new!(agent_state: agent_state)},
      agent_server_pid: self()
    }

    params = %{
      input: "hello",
      request_id: "request-1",
      context: %{
        domain: Jidoka.Runtime.Actions.RunTurnTest,
        session_id: "session-1",
        user_id: "user-1"
      },
      runtime_opts: [operation_context: [test_pid: self()]]
    }

    assert {:ok, state} = RunTurn.run(params, context)
    assert state.status == :completed
    assert state.last_answer == "done"
    assert state.last_request_id == "request-1"
    assert state.jidoka.status == :completed
    assert state.jidoka.agent_state.metadata == %{existing: true}

    assert_receive {:run_turn_opts, opts}
    assert opts[:operation_context].jido_agent == context.agent
    assert opts[:operation_context].jido_agent_server_pid == self()
    assert opts[:operation_context].test_pid == self()
    assert opts[:session_id] == "session-1"
    refute Map.has_key?(opts[:operation_context], :domain)
    refute Map.has_key?(opts[:operation_context], :user_id)
  end

  test "writes hibernation snapshots into Jido agent state" do
    context = %{
      agent: %{agent_module: Jidoka.Runtime.Actions.RunTurnTest.Support.HibernateAgent},
      state: %{}
    }

    assert {:ok, state} = RunTurn.run(%{input: "pause"}, context)
    assert state.status == :waiting
    assert state.jidoka.status == :hibernated
    assert state.jidoka.snapshot.agent_id == "hibernate_action_agent"
  end

  test "returns failed state for invalid input and agent exceptions" do
    assert {:ok, state} = RunTurn.run(%{}, %{})
    assert state.status == :failed
    assert state.jidoka.status == :failed
    assert %Jidoka.Error.ValidationError{field: :input} = state.jidoka.error

    context = %{agent: %{agent_module: Jidoka.Runtime.Actions.RunTurnTest.Support.RaisingAgent}}

    assert {:ok, state} = RunTurn.run(%{input: "explode"}, context)
    assert state.status == :failed
    assert state.jidoka.status == :failed
    assert %Jidoka.Error.ExecutionError{details: %{cause: %RuntimeError{}}} = state.jidoka.error
  end
end
