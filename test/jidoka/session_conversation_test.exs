defmodule Jidoka.SessionConversationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Session.Conversation
  alias Jidoka.Session.Data
  alias Jidoka.Turn

  test "completed turns advance canonical conversation state" do
    request =
      Turn.Request.new!(
        input: "Hello",
        request_id: "turn_1",
        context: %{
          "workspace" => "alpha",
          "worker" => self(),
          "api_key" => "runtime-only"
        }
      )

    agent_state =
      Agent.State.new!(
        messages: [
          Agent.Message.user("Hello", id: "msg_user", request_id: "turn_1"),
          Agent.Message.assistant("Hi", id: "msg_assistant", request_id: "turn_1")
        ]
      )

    result = result(agent_state, "turn_1")

    assert {:ok,
            %Conversation{
              agent_state: ^agent_state,
              continuation_revision: 1,
              turn_count: 1,
              context_state: %{"workspace" => "alpha"},
              last_completed_request_id: "turn_1"
            }} = Conversation.complete(Conversation.new!(), request, result)
  end

  test "conversation state rejects process handles and credential fields" do
    unsafe_state = Agent.State.new!(metadata: %{worker: self()})

    assert {:error, {:unsafe_conversation_state, reason}} =
             Conversation.new(agent_state: unsafe_state)

    assert reason =~ "pid"

    assert {:error, _reason} =
             Conversation.new(context_state: %{"api_key" => "must-not-persist"})

    credential_state = Agent.State.new!(metadata: %{"auth_token" => "must-not-persist"})

    assert {:error, {:credential_in_conversation, _path}} =
             Conversation.new(agent_state: credential_state)
  end

  test "version 1 and 2 sessions load into canonical conversation state" do
    spec = spec()
    request = Turn.Request.new!(input: "Hello", request_id: "legacy_turn", context: %{tenant: "t1"})
    agent_state = Agent.State.new!(messages: [Agent.Message.assistant("done")])
    result = result(agent_state, "legacy_turn")

    for version <- [1, 2] do
      assert {:ok,
              %Data{
                schema_version: ^version,
                conversation: %Conversation{
                  agent_state: ^agent_state,
                  continuation_revision: 1,
                  turn_count: 1,
                  context_state: %{tenant: "t1"},
                  last_completed_request_id: "legacy_turn"
                }
              }} =
               Data.new(%{
                 schema_version: version,
                 session_id: "legacy_#{version}",
                 agent_id: spec.id,
                 spec: spec,
                 status: :finished,
                 requests: [request],
                 result: result
               })
    end
  end

  test "version 3 sessions round-trip and promote a result" do
    assert {:ok, %Data{schema_version: 3} = session} =
             Data.start(spec(), session_id: "session_v3")

    assert {:ok, ^session} = session |> Map.from_struct() |> Data.from_input()

    request = Turn.Request.new!(input: "Hello", request_id: "turn_v3")
    result = result(Agent.State.new!(messages: [Agent.Message.assistant("done")]), "turn_v3")

    completed = session |> Data.put_request(request) |> Data.put_result(result)

    assert completed.conversation.continuation_revision == 1
    assert completed.conversation.turn_count == 1
    assert completed.conversation.last_completed_request_id == "turn_v3"
    assert completed.conversation.agent_state == result.agent_state
  end

  test "conversation constructors reject inconsistent completion identity" do
    assert {:ok, %Conversation{}} = Conversation.new()
    assert {:ok, %Conversation{} = conversation} = Conversation.from_input(%{})
    assert {:ok, ^conversation} = Conversation.from_input(conversation)

    assert {:error, {:invalid_conversation_completion_identity, 1, nil}} =
             Conversation.new(turn_count: 1)

    assert {:error, {:invalid_conversation_completion_identity, 0, "request-1"}} =
             Conversation.new(last_completed_request_id: "request-1")

    assert_raise ArgumentError, ~r/invalid session conversation/, fn ->
      Conversation.new!(turn_count: 1)
    end
  end

  test "completed conversation raises when the promoted state is unsafe" do
    request = Turn.Request.new!(input: "Hello", request_id: "unsafe-result")
    unsafe_state = Agent.State.new!(metadata: %{worker: self()})
    unsafe_result = result(unsafe_state, "unsafe-result")

    assert_raise ArgumentError, ~r/invalid completed conversation/, fn ->
      Conversation.complete!(Conversation.new!(), request, unsafe_result)
    end
  end

  test "request revision helpers support nil and fresh request boundaries" do
    conversation = Conversation.new!(continuation_revision: 3, turn_count: 3, last_completed_request_id: "r3")
    fresh = Turn.Request.new!(input: "Fresh", metadata: %{"jidoka_fresh_conversation" => true})
    continued = Turn.Request.new!(input: "Continue")

    assert Conversation.base_for_request(conversation, nil) == conversation
    assert Conversation.base_for_request(conversation, continued) == conversation
    assert Conversation.base_for_request(conversation, fresh) == Conversation.new!()
    assert Conversation.next_revision(conversation, nil) == 3
    assert Conversation.next_revision(conversation, continued) == 4
    assert Conversation.next_revision(conversation, fresh) == 1
  end

  test "durable context filtering removes live values and credentials from nested data" do
    context = %{
      123 => "numeric key",
      keep: 1,
      list: [1, self(), 2],
      tuple: {1, self(), 2},
      date: ~D[2026-08-20],
      nested: %{password: "secret", keep: true}
    }

    assert %{
             123 => "numeric key",
             keep: 1,
             list: [1, 2],
             tuple: [1, 2],
             date: %{calendar: Calendar.ISO, day: 20, month: 8, year: 2026},
             nested: %{keep: true}
           } = Conversation.durable_context_state(context)
  end

  test "legacy conversation normalization accepts loose result and request data" do
    state = Agent.State.new!(messages: [Agent.Message.assistant("done")])
    context = Jidoka.Context.from_data!(%{tenant: "one"})

    requests = [
      %{request_id: "r1", context: %{data: %{tenant: "one"}}},
      %{request_id: "r2", context: context},
      :invalid
    ]

    assert {:ok,
            %Conversation{
              agent_state: ^state,
              continuation_revision: 2,
              turn_count: 2,
              context_state: %{tenant: "one"},
              last_completed_request_id: "r2"
            }} =
             Conversation.from_legacy(%{agent_state: state, metadata: %{debug: %{request_id: "r2"}}}, requests)

    assert {:ok, %Conversation{turn_count: 1, last_completed_request_id: "missing"}} =
             Conversation.from_legacy(%{metadata: %{debug: %{request_id: "missing"}}}, requests)

    assert {:ok, %Conversation{turn_count: 0, last_completed_request_id: nil}} =
             Conversation.from_legacy(nil, requests)

    assert {:ok, %Conversation{last_completed_request_id: nil}} =
             Conversation.from_legacy(:invalid, [:invalid])
  end

  defp result(agent_state, request_id) do
    Turn.Result.new!(
      content: "done",
      agent_state: agent_state,
      journal: Effect.Journal.new!(),
      metadata: %{debug: %{request_id: request_id}}
    )
  end

  defp spec do
    Agent.Spec.new!(
      id: "conversation_agent",
      instructions: "Reply.",
      model: %{provider: :test, id: "model"}
    )
  end
end
