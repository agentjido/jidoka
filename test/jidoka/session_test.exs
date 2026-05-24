defmodule JidokaTest.SessionTest do
  use JidokaTest.Support.Case, async: false

  alias Jidoka.Session
  alias JidokaTest.ChatAgent

  test "builds stable session identity and chat options" do
    assert {:ok, %Session{} = session} =
             Session.new(
               agent: ChatAgent,
               id: " Ticket 123! ",
               context: %{tenant: "acme"},
               metadata: [surface: :test]
             )

    assert session.id == "ticket_123"
    assert session.conversation_id == "ticket_123"
    assert session.agent_id == "chat_agent-ticket_123"
    assert session.context_ref == Session.default_context_ref()
    assert session.context == %{session: "ticket_123", tenant: "acme"}
    assert session.metadata == %{surface: :test}

    opts = Session.chat_opts(session, context: %{tenant: "override", actor: "user-1"})

    assert opts[:conversation] == "ticket_123"
    assert opts[:context] == %{session: "ticket_123", tenant: "override", actor: "user-1"}

    assert opts[:extra_refs] == %{
             session_id: "ticket_123",
             conversation_id: "ticket_123",
             agent_id: "chat_agent-ticket_123",
             context_ref: "default"
           }
  end

  test "validates required session options" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} = Session.new(agent: ChatAgent)
    assert error.field == :id

    assert {:error, %Jidoka.Error.ValidationError{} = error} = Session.new(id: "case")
    assert error.field == :agent

    assert {:error, %Jidoka.Error.ValidationError{} = error} = Session.new(agent: ChatAgent, id: "!!!")
    assert error.field == :id

    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Session.new(agent: ChatAgent, id: "case", context: [:not_a_pair])

    assert error.field == :context
  end

  test "session is a plain descriptor, not a process or transcript store" do
    session = session!("plain-descriptor", context: %{tenant: "acme"})

    refute is_pid(session)
    assert Session.whereis(session) == nil

    assert Map.take(Map.from_struct(session), [
             :id,
             :agent,
             :agent_id,
             :conversation_id,
             :context_ref,
             :context,
             :runtime,
             :start_opts,
             :metadata
           ]) == Map.from_struct(session)

    refute Map.has_key?(session, :pid)
    refute Map.has_key?(session, :messages)
    refute Map.has_key?(session, :thread)
    refute Map.has_key?(session, :transcript)

    assert {:error, %Jidoka.Error.ValidationError{} = error} = Session.snapshot(session)
    assert error.details.reason == :session_agent_not_running
    assert error.details.agent_id == session.agent_id
  end

  test "starts and reuses the session runtime agent" do
    session = session!("start-reuse")

    try do
      assert {:ok, pid} = Session.start_agent(session)
      assert Session.whereis(session) == pid
      assert {:ok, ^pid} = Session.start_agent(session)
    after
      stop_session_agent(session)
    end
  end

  test "passes non-default context_ref into fresh runtime state" do
    session = session!("context-ref", context_ref: "support-lane")

    try do
      assert {:ok, pid} = Session.start_agent(session)
      assert {:ok, %{agent: agent}} = Jido.AgentServer.state(pid)
      assert agent.state.active_context_ref == "support-lane"
    after
      stop_session_agent(session)
    end
  end

  test "Jidoka.chat accepts sessions and keeps the normal chat lifecycle" do
    session = session!("chat-path", context: %{tenant: "acme"})
    test_pid = self()

    guardrail = fn input ->
      send(test_pid, {:session_context, input.context})
      {:interrupt, %{kind: :approval, message: "Stop before provider", data: %{}}}
    end

    try do
      assert {:interrupt, %Jidoka.Interrupt{kind: :approval}} =
               Jidoka.chat(session, "hello", context: %{channel: "support"}, guardrails: [input: guardrail])

      assert_receive {:session_context, context}
      assert Jidoka.Context.strip_internal(context) == %{session: session.id, tenant: "acme", channel: "support"}
      assert {:ok, %{request_id: request_id}} = Jidoka.inspect_request(session)
      assert is_binary(request_id)
      assert {:ok, trace} = Jidoka.inspect_trace(session)
      assert trace.agent_id == session.agent_id

      assert {:ok, snapshot} = Session.snapshot(session)
      assert snapshot.kind == :agent_view
      assert snapshot.agent_id == session.agent_id
      assert snapshot.context_ref == session.context_ref

      assert {:ok, direct_trace} = Session.trace(session)
      assert direct_trace.agent_id == session.agent_id
    after
      stop_session_agent(session)
    end
  end

  test "start_chat_request accepts sessions for async turns" do
    session = session!("async-chat")

    guardrail = fn _input ->
      {:interrupt, %{kind: :approval, message: "Async stop", data: %{}}}
    end

    try do
      assert {:ok, request} = Jidoka.start_chat_request(session, "hello", guardrails: [input: guardrail])
      assert {:interrupt, %Jidoka.Interrupt{message: "Async stop"}} = Jidoka.await_chat_request(request)
    after
      stop_session_agent(session)
    end
  end

  test "handoff helpers accept sessions" do
    session = session!("handoff-helper")

    handoff =
      Jidoka.Handoff.new(
        conversation_id: session.conversation_id,
        from_agent: session.agent,
        to_agent: ChatAgent,
        to_agent_id: "specialist",
        name: "specialist",
        message: "Transfer",
        context: %{}
      )

    :ok = Jidoka.Handoff.Registry.put_owner(session.conversation_id, handoff)

    try do
      assert %{agent_id: "specialist"} = Session.handoff_owner(session)
      assert %{agent_id: "specialist"} = Jidoka.handoff_owner(session)
      assert :ok = Jidoka.reset_handoff(session)
      assert Jidoka.handoff_owner(session) == nil
    after
      Jidoka.reset_handoff(session.conversation_id)
    end
  end

  defp session!(id, opts \\ []) do
    suffix = System.unique_integer([:positive, :monotonic])

    opts
    |> Keyword.merge(agent: ChatAgent, id: "#{id}-#{suffix}")
    |> Session.new!()
  end

  defp stop_session_agent(%Session{} = session) do
    case Session.whereis(session) do
      pid when is_pid(pid) -> Jidoka.stop_agent(pid)
      nil -> :ok
    end
  end
end
