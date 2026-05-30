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

  test "agent messages are typed durable chat data" do
    assert {:ok, %Agent.Message{role: :user, content: "hello"}} =
             Agent.Message.from_input(%{"role" => "user", "content" => "hello"})

    assert {:ok, %Agent.State{messages: [%Agent.Message{role: :assistant}]}} =
             Agent.State.from_input(%{
               "messages" => [%{"role" => "assistant", "content" => "stored"}]
             })

    assert Agent.Message.to_map(Agent.Message.tool("lookup", %{"id" => "A-1"})) == %{
             role: :tool,
             content: "%{\"id\" => \"A-1\"}",
             operation: "lookup",
             output: %{"id" => "A-1"}
           }

    assert {:error, {:missing_message_content, :assistant}} =
             Agent.Message.from_input(%{"role" => "assistant"})

    assert {:error, :missing_tool_message_operation} =
             Agent.Message.from_input(%{"role" => "tool", "content" => "missing operation"})
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

    assert {:ok, %Operation{name: "lookup", idempotency: :pure}} =
             Operation.from_input(%{"name" => "lookup", "idempotency" => "pure"})

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

  test "effect contracts accept decoded string enums without creating atoms" do
    assert {:ok, %Effect.Intent{kind: :operation, idempotency: :dedupe}} =
             Effect.Intent.new(%{
               "id" => "operation:1",
               "kind" => "operation",
               "payload" => %{"name" => "lookup"},
               "idempotency_key" => "key-1",
               "idempotency" => "dedupe"
             })

    assert {:error, _reason} =
             Effect.Intent.new(%{
               id: "operation:bad",
               kind: :operation,
               payload: %{},
               idempotency_key: "bad"
             })

    assert {:ok, %Effect.Result{kind: :operation, status: :ok}} =
             Effect.Result.new(%{
               "intent_id" => "operation:1",
               "kind" => "operation",
               "status" => "ok",
               "output" => %{"value" => 1}
             })

    assert {:ok, %Turn.Cursor{phase: :before_effect}} =
             Turn.Cursor.new(%{"phase" => "before_effect"})
  end

  test "LLM decisions and operation observations are typed effect payloads" do
    assert {:ok, %Effect.LLMDecision{type: :operation, name: "lookup"}} =
             Effect.LLMDecision.from_input(%{
               "type" => "operation",
               "name" => "lookup",
               "arguments" => %{"id" => "A-1"}
             })

    intent =
      Effect.Intent.new(:operation, %{
        name: "lookup",
        arguments: %{"id" => "A-1"},
        request_id: "turn_1",
        loop_index: 0
      })

    assert {:ok,
            %Effect.OperationResult{
              operation: "lookup",
              arguments: %{"id" => "A-1"},
              output: %{"name" => "Ada"},
              effect_id: effect_id
            }} = Effect.OperationResult.from_effect(intent, %{"name" => "Ada"})

    assert effect_id == intent.id
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

  test "turn request id generation can be injected" do
    generator = fn "turn" -> "turn_test_1" end

    assert {:ok, %Turn.Request{request_id: "turn_test_1"}} =
             Turn.Request.from_input("Hello", id_generator: generator)

    assert {:error, {:invalid_generated_id, "turn", nil}} =
             Turn.Request.from_input("Hello", id_generator: fn "turn" -> nil end)

    assert {:error, {:id_generator_failed, "turn", {:exception, %RuntimeError{}}}} =
             Turn.Request.from_input("Hello", id_generator: fn "turn" -> raise "boom" end)
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

  test "agent snapshot id generation can be explicit or injected" do
    state = base_state()

    assert {:ok, %AgentSnapshot{snapshot_id: "snap_explicit"}} =
             AgentSnapshot.from_turn_state(state, Turn.Cursor.after_prompt(),
               snapshot_id: "snap_explicit"
             )

    assert {:ok, %AgentSnapshot{snapshot_id: "snap_injected"}} =
             AgentSnapshot.from_turn_state(state, Turn.Cursor.after_prompt(),
               id_generator: fn "snap" -> "snap_injected" end
             )
  end

  test "agent snapshots serialize and deserialize through the hibernate contract" do
    state = base_state()
    snapshot = AgentSnapshot.from_turn_state!(state, Turn.Cursor.after_prompt())

    assert {:ok, serialized} = AgentSnapshot.serialize(snapshot)
    assert serialized =~ "jidoka:snapshot:v1:"

    assert {:ok, %AgentSnapshot{} = restored} = AgentSnapshot.deserialize(serialized)
    assert restored.snapshot_id == snapshot.snapshot_id
    assert restored.cursor.phase == :after_prompt
    assert restored.turn_state.spec.id == "snapshot_agent"
  end

  test "snapshot serialization rejects non-portable runtime values" do
    state = base_state()
    snapshot = AgentSnapshot.from_turn_state!(state, Turn.Cursor.after_prompt())
    snapshot = %{snapshot | metadata: %{callback: fn -> :ok end}}

    assert {:error, {:non_serializable_snapshot_value, [:metadata, :callback], :function}} =
             AgentSnapshot.serialize(snapshot)

    snapshot = AgentSnapshot.from_turn_state!(state, Turn.Cursor.after_prompt())
    snapshot = %{snapshot | metadata: %{wrapped: {:ok, fn -> :ok end}}}

    assert {:error, {:non_serializable_snapshot_value, [:metadata, :wrapped, 1], :function}} =
             AgentSnapshot.serialize(snapshot)
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
