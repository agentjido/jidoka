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
