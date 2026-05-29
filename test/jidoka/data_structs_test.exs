defmodule Jidoka.DataStructsTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

  test "agent state accepts nil, maps, and structs as input" do
    assert {:ok, %Agent.State{messages: [], operation_results: [], metadata: %{}}} =
             Agent.State.from_input(nil)

    assert {:ok, %Agent.State{metadata: %{"owner" => "unit"}} = state} =
             Agent.State.from_input(%{"metadata" => %{"owner" => "unit"}})

    assert {:ok, ^state} = Agent.State.from_input(state)
  end

  test "operation specs validate idempotency and normalize fields" do
    assert Operation.valid_idempotencies() == [
             :pure,
             :idempotent,
             :dedupe,
             :reconcile,
             :unsafe_once
           ]

    assert {:ok, %Operation{name: "lookup", idempotency: :pure}} =
             Operation.from_input(%{"name" => :lookup, "idempotency" => :pure})

    assert {:error, [%Zoi.Error{path: [:idempotency]}]} =
             Operation.new(name: "lookup", idempotency: :not_valid)
  end

  test "effect intents derive stable ids and results preserve status" do
    first = Effect.Intent.new(:llm, %{request_id: "turn_1", loop_index: 0})
    second = Effect.Intent.new(:llm, %{request_id: "turn_1", loop_index: 0})
    custom = Effect.Intent.new(:operation, %{name: "lookup"}, id: "custom", idempotency_key: "k")

    assert first.id == second.id
    assert first.idempotency_key == second.idempotency_key
    assert custom.id == "custom"

    assert %Effect.Result{kind: :llm, status: :ok, output: %{ok: true}} =
             Effect.Result.ok(first, %{ok: true})

    assert %Effect.Result{kind: :operation, status: :error, output: :failed} =
             Effect.Result.error(custom, :failed)
  end

  test "effect journals keep intents and replace results by intent id" do
    intent = Effect.Intent.new(:llm, %{request_id: "turn_1"})
    first = Effect.Result.ok(intent, %{type: :final, content: "first"})
    second = Effect.Result.ok(intent, %{type: :final, content: "second"})

    journal =
      Effect.Journal.new!()
      |> Effect.Journal.put_intent(intent)
      |> Effect.Journal.put_result(first)
      |> Effect.Journal.put_result(second)

    assert journal.intents[intent.id] == intent
    assert Effect.Journal.result_for(journal, intent) == second
  end

  test "turn requests normalize string input and preserve supplied state" do
    assert {:ok, %Turn.Request{} = request} = Turn.Request.from_input("Hello")
    assert request.input == "Hello"
    assert request.request_id =~ "turn_"
    assert %Agent.State{} = request.agent_state

    agent_state = Agent.State.new!(messages: [%{role: :user, content: "prior"}])

    assert {:ok, %Turn.Request{agent_state: ^agent_state, context: %{tenant: "t1"}}} =
             Turn.Request.from_input(
               input: "Hello",
               agent_state: agent_state,
               context: %{tenant: "t1"}
             )
  end

  test "turn cursors describe checkpoint positions" do
    intent = Effect.Intent.new(:operation, %{name: "lookup"})

    assert %Turn.Cursor{phase: :after_prompt, loop_index: 0} = Turn.Cursor.after_prompt()

    assert %Turn.Cursor{phase: :before_effect, metadata: metadata} =
             Turn.Cursor.before_effect(intent)

    assert metadata["effect_id"] == intent.id
    assert metadata["effect_kind"] == :operation
  end

  test "agent snapshots round-trip from serializable maps" do
    state = base_state()
    snapshot = AgentSnapshot.from_turn_state!(state, Turn.Cursor.after_prompt())

    assert snapshot.schema_version == AgentSnapshot.schema_version()

    assert {:ok, %AgentSnapshot{} = restored} =
             snapshot
             |> portable_map()
             |> AgentSnapshot.from_input()

    assert restored.schema_version == AgentSnapshot.schema_version()
    assert restored.agent_id == "snapshot_agent"
    assert restored.cursor.phase == :after_prompt
    assert restored.turn_state.spec.id == "snapshot_agent"
  end

  test "turn results require a finished state" do
    %Turn.State{} = state = base_state()
    finished = %{state | status: :finished, result: "done"}

    assert %Turn.Result{content: "done"} = Turn.Result.from_turn_state!(finished)

    assert_raise FunctionClauseError, fn ->
      Turn.Result.from_turn_state!(state)
    end
  end

  defp base_state do
    spec =
      Agent.Spec.new!(
        id: "snapshot_agent",
        instructions: "Snapshot test.",
        model: %{provider: :test, id: "model"}
      )

    plan = Turn.Plan.new!(spec)
    request = Turn.Request.new!(input: "Hello")

    Turn.State.new!(
      spec: spec,
      plan: plan,
      request: request,
      agent_state: request.agent_state
    )
  end

  defp portable_map(%_{} = value), do: value |> Map.from_struct() |> portable_map()

  defp portable_map(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), portable_map(nested)} end)
  end

  defp portable_map(value) when is_list(value), do: Enum.map(value, &portable_map/1)
  defp portable_map(value), do: value
end
