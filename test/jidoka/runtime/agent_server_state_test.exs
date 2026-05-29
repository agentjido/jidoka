defmodule Jidoka.Runtime.AgentServerStateTest do
  use ExUnit.Case, async: true

  alias Jidoka.Effect
  alias Jidoka.Runtime.AgentServerState
  alias Jidoka.Turn

  test "completed states preserve Jido conventions and typed Jidoka state" do
    request = Turn.Request.new!(input: "hello", request_id: "request-1")

    result =
      Turn.Result.new!(
        content: "done",
        agent_state: request.agent_state,
        journal: Effect.Journal.new!()
      )

    state = AgentServerState.completed(result, request)
    jido_state = AgentServerState.to_jido_state(state)

    assert jido_state.status == :completed
    assert jido_state.last_answer == "done"
    assert jido_state.last_request_id == "request-1"
    assert jido_state.error == nil
    assert jido_state.jidoka.status == :completed
    assert AgentServerState.from_jido_state(jido_state) == {:ok, state}
    assert AgentServerState.to_run_result(state) == {:ok, result}
  end

  test "hibernated and failed states map to Jido await-compatible statuses" do
    request = Turn.Request.new!(input: "pause", request_id: "request-2")

    spec =
      Jidoka.agent!(
        id: "agent_server_state_agent",
        instructions: "State contract.",
        model: %{provider: :test, id: "model"}
      )

    turn_state =
      Turn.State.new!(
        spec: spec,
        plan: Jidoka.plan!(spec),
        request: request,
        agent_state: request.agent_state
      )

    snapshot =
      Jidoka.Runtime.AgentSnapshot.from_turn_state!(turn_state, Turn.Cursor.after_prompt())

    hibernated = AgentServerState.hibernated(snapshot, request)
    failed = AgentServerState.failed(:boom, request.agent_state)

    assert AgentServerState.to_jido_state(hibernated).status == :waiting
    assert AgentServerState.to_run_result(hibernated) == {:hibernate, snapshot}

    assert AgentServerState.to_jido_state(failed).status == :failed

    assert %Jidoka.Error.ExecutionError{details: %{cause: :boom}} =
             AgentServerState.to_jido_state(failed).error

    assert {:error, %Jidoka.Error.ExecutionError{details: %{cause: :boom}}} =
             AgentServerState.to_run_result(failed)
  end
end
