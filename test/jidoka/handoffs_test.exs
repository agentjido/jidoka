defmodule JidokaTest.HandoffsTest do
  use JidokaTest.Support.Case, async: false

  alias JidokaTest.{
    BillingHandoffSpecialist,
    ContextPeerHandoffAgent,
    HandoffForwardExceptAgent,
    HandoffForwardNoneAgent,
    HandoffForwardOnlyAgent,
    HandoffRouterAgent,
    MissingPeerHandoffAgent,
    PeerHandoffAgent,
    ReviewHandoffSpecialist,
    SessionBillingHandoffAgent,
    SessionHandoffRouterAgent,
    StartFailureHandoffAgent,
    WrongPeerHandoffAgent
  }

  test "compiled agents expose handoff definitions and generated tools" do
    assert HandoffRouterAgent.handoff_names() == ["billing_specialist"]

    assert [
             %Jidoka.Handoff.Capability{
               name: "billing_specialist",
               agent: BillingHandoffSpecialist,
               target: :auto
             }
           ] = HandoffRouterAgent.handoffs()

    assert "billing_specialist" in HandoffRouterAgent.tool_names()
    assert handoff_tool(HandoffRouterAgent, "billing_specialist").schema() == Jidoka.Handoff.Capability.input_schema()
  end

  test "auto handoff returns a first-class outcome and stores the conversation owner" do
    conversation_id = unique_id("support-handoff")
    tool = handoff_tool(HandoffRouterAgent, "billing_specialist")

    try do
      assert {:error, {:handoff, %Jidoka.Handoff{} = handoff}} =
               tool.run(
                 %{
                   message: "Please continue with billing.",
                   summary: "Customer asked about invoice.",
                   reason: "billing"
                 },
                 handoff_context(conversation_id, tenant: "acme", secret: "drop")
               )

      assert handoff.conversation_id == conversation_id
      assert handoff.from_agent == "handoff_router_agent"
      assert handoff.to_agent == BillingHandoffSpecialist
      assert handoff.to_agent_id =~ "jidoka_handoff_support_handoff"
      assert handoff.name == "billing_specialist"
      assert handoff.message == "Please continue with billing."
      assert handoff.summary == "Customer asked about invoice."
      assert handoff.reason == "billing"
      assert handoff.context[:tenant] == "acme"
      refute Map.has_key?(handoff.context, Jidoka.Handoff.context_key())

      assert %{agent: BillingHandoffSpecialist, agent_id: agent_id, handoff: ^handoff} =
               Jidoka.handoff_owner(conversation_id)

      assert agent_id == handoff.to_agent_id
      assert Process.alive?(Jidoka.whereis(agent_id))
    after
      cleanup_conversation(conversation_id)
    end
  end

  test "auto handoff requires a conversation id" do
    tool = handoff_tool(HandoffRouterAgent, "billing_specialist")

    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             tool.run(%{message: "Transfer billing."}, %{})

    assert error.message == "Handoff target :auto requires a conversation."
    assert error.details.reason == :missing_conversation
  end

  test "handoff forward_context can drop, include, or exclude public context" do
    none_conversation = unique_id("handoff-none")
    only_conversation = unique_id("handoff-only")
    except_conversation = unique_id("handoff-except")

    try do
      assert {:error, {:handoff, %Jidoka.Handoff{context: %{}}}} =
               HandoffForwardNoneAgent
               |> handoff_tool("billing_specialist")
               |> run_transfer(none_conversation, %{tenant: "acme", account_id: "acct_123"})

      assert {:error, {:handoff, %Jidoka.Handoff{context: only_context}}} =
               HandoffForwardOnlyAgent
               |> handoff_tool("billing_specialist")
               |> run_transfer(only_conversation, %{tenant: "acme", account_id: "acct_123", secret: "drop"})

      assert only_context == %{tenant: "acme", account_id: "acct_123"}

      assert {:error, {:handoff, %Jidoka.Handoff{context: except_context}}} =
               HandoffForwardExceptAgent
               |> handoff_tool("billing_specialist")
               |> run_transfer(except_conversation, %{tenant: "acme", account_id: "acct_123", secret: "drop"})

      assert except_context[:tenant] == "acme"
      assert except_context[:account_id] == "acct_123"
      refute Map.has_key?(except_context, :secret)
    after
      cleanup_conversation(none_conversation)
      cleanup_conversation(only_conversation)
      cleanup_conversation(except_conversation)
    end
  end

  test "peer handoffs require an existing target with the expected runtime" do
    conversation_id = unique_id("handoff-peer")
    reset_agent("billing-peer-handoff-test")
    assert {:ok, pid} = BillingHandoffSpecialist.start_link(id: "billing-peer-handoff-test")

    try do
      assert {:error, {:handoff, %Jidoka.Handoff{} = handoff}} =
               PeerHandoffAgent
               |> handoff_tool("billing_specialist")
               |> run_transfer(conversation_id, %{tenant: "peer"})

      assert handoff.to_agent_id == "billing-peer-handoff-test"
      assert Jidoka.whereis("billing-peer-handoff-test") == pid
      assert Jidoka.handoff_owner(conversation_id).agent_id == "billing-peer-handoff-test"
    after
      cleanup_conversation(conversation_id)
      reset_agent("billing-peer-handoff-test")
    end
  end

  test "context-derived peer handoffs resolve the target before applying context forwarding" do
    conversation_id = unique_id("handoff-peer-context")
    reset_agent("billing-peer-context-handoff-test")
    assert {:ok, pid} = BillingHandoffSpecialist.start_link(id: "billing-peer-context-handoff-test")

    try do
      assert {:error, {:handoff, %Jidoka.Handoff{} = handoff}} =
               ContextPeerHandoffAgent
               |> handoff_tool("billing_specialist")
               |> run_transfer(conversation_id, %{billing_peer_id: "billing-peer-context-handoff-test"})

      assert handoff.to_agent_id == "billing-peer-context-handoff-test"
      assert Jidoka.whereis("billing-peer-context-handoff-test") == pid
    after
      cleanup_conversation(conversation_id)
      reset_agent("billing-peer-context-handoff-test")
    end
  end

  test "missing and mismatched peer handoffs return Jidoka execution errors" do
    missing_tool = handoff_tool(MissingPeerHandoffAgent, "billing_specialist")

    assert {:error, %Jidoka.Error.ExecutionError{} = missing_error} =
             run_transfer(missing_tool, unique_id("missing-peer"), %{})

    assert missing_error.message == "Handoff target agent could not be found."
    assert missing_error.details.reason == :peer_not_found
    assert missing_error.details.cause == {:peer_not_found, "missing-billing-peer-handoff-test"}

    reset_agent("wrong-billing-peer-handoff-test")
    assert {:ok, pid} = ReviewHandoffSpecialist.start_link(id: "wrong-billing-peer-handoff-test")

    try do
      wrong_tool = handoff_tool(WrongPeerHandoffAgent, "billing_specialist")

      assert {:error, %Jidoka.Error.ExecutionError{} = wrong_error} =
               run_transfer(wrong_tool, unique_id("wrong-peer"), %{})

      assert wrong_error.message == "Handoff target runtime did not match the configured agent."
      assert wrong_error.details.reason == :peer_mismatch

      assert wrong_error.details.cause ==
               {:peer_mismatch, JidokaTest.BillingHandoffSpecialist.Runtime, JidokaTest.ReviewHandoffSpecialist.Runtime}
    after
      assert Jidoka.whereis("wrong-billing-peer-handoff-test") == pid
      reset_agent("wrong-billing-peer-handoff-test")
    end
  end

  test "invalid payloads and failed auto-target starts return normalized handoff errors" do
    tool = handoff_tool(HandoffRouterAgent, "billing_specialist")

    assert {:error, %Jidoka.Error.ValidationError{} = invalid_error} =
             tool.run(%{message: " "}, handoff_context(unique_id("invalid-payload")))

    assert invalid_error.message == "Handoff message must be a non-empty string."
    assert invalid_error.details.reason == :invalid_payload

    conversation_id = unique_id("handoff-start-failure")
    start_failure_tool = handoff_tool(StartFailureHandoffAgent, "start_failure_specialist")

    try do
      assert {:error, %Jidoka.Error.ExecutionError{} = start_error} =
               run_transfer(start_failure_tool, conversation_id, %{})

      assert start_error.message == "Handoff target agent could not be started."
      assert start_error.details.reason == :start_failed
      assert start_error.details.cause == {:start_failed, :boom}
      assert is_nil(Jidoka.handoff_owner(conversation_id))
    after
      cleanup_conversation(conversation_id)
    end
  end

  test "handoff metadata is available before request state is persisted" do
    conversation_id = unique_id("handoff-meta")
    request_id = unique_id("req-handoff")
    tool = handoff_tool(HandoffRouterAgent, "billing_specialist")

    try do
      assert {:error, {:handoff, %Jidoka.Handoff{} = handoff}} =
               tool.run(%{message: "Transfer billing."}, handoff_context(conversation_id, request_id: request_id))

      assert [
               %{
                 name: "billing_specialist",
                 outcome: :handoff,
                 handoff: ^handoff,
                 to_agent_id: to_agent_id
               }
             ] = Jidoka.Handoff.Capability.request_calls(self(), request_id)

      assert to_agent_id == handoff.to_agent_id
    after
      cleanup_conversation(conversation_id)
    end
  end

  test "public owner helpers clear ownership" do
    conversation_id = unique_id("handoff-reset")
    tool = handoff_tool(HandoffRouterAgent, "billing_specialist")

    try do
      assert {:error, {:handoff, %Jidoka.Handoff{}}} =
               tool.run(%{message: "Transfer billing."}, handoff_context(conversation_id))

      assert %{agent: BillingHandoffSpecialist, handoff: %Jidoka.Handoff{name: "billing_specialist"}} =
               Jidoka.handoff_owner(conversation_id)

      assert :ok = Jidoka.reset_handoff(conversation_id)
      assert is_nil(Jidoka.handoff_owner(conversation_id))
    after
      cleanup_conversation(conversation_id)
    end
  end

  test "session future turns route to the handoff owner until reset" do
    session =
      Jidoka.Session.new!(
        agent: SessionHandoffRouterAgent,
        id: unique_id("handoff-session"),
        context: %{tenant: "acme"}
      )

    tool = handoff_tool(SessionHandoffRouterAgent, "session_billing_specialist")
    handoff_agent_id = "jidoka_handoff_#{session.conversation_id}_session_billing_specialist"
    test_pid = self()

    route_interrupt = fn input ->
      send(test_pid, {
        :routed_turn,
        input.message,
        input.agent.id,
        input.server,
        Jidoka.Context.strip_internal(input.context)
      })

      {:interrupt, %{kind: :approval, message: "Stopped #{input.message}", data: %{}}}
    end

    try do
      assert {:error, {:handoff, %Jidoka.Handoff{} = handoff}} =
               tool.run(
                 %{
                   message: "Please continue with billing.",
                   summary: "Customer is asking about an invoice.",
                   reason: "billing"
                 },
                 handoff_context(
                   session.conversation_id,
                   %{
                     :tenant => "acme",
                     Jidoka.Handoff.from_agent_key() => SessionHandoffRouterAgent.id(),
                     Jidoka.Trace.agent_id_key() => session.agent_id
                   }
                 )
               )

      assert handoff.to_agent == SessionBillingHandoffAgent
      assert handoff.to_agent_id == handoff_agent_id
      assert %{agent: SessionBillingHandoffAgent, agent_id: ^handoff_agent_id} = Jidoka.handoff_owner(session)

      assert {:interrupt, %Jidoka.Interrupt{message: "Stopped future turn"}} =
               Jidoka.chat(session, "future turn", controls: [input: route_interrupt])

      handoff_pid = Jidoka.whereis(handoff_agent_id)
      assert_receive {:routed_turn, "future turn", ^handoff_agent_id, ^handoff_pid, future_context}
      assert future_context == %{session: session.id, tenant: "acme"}

      assert :ok = Jidoka.reset_handoff(session)
      assert is_nil(Jidoka.handoff_owner(session))

      assert {:interrupt, %Jidoka.Interrupt{message: "Stopped back to parent"}} =
               Jidoka.chat(session, "back to parent", controls: [input: route_interrupt])

      parent_pid = Jidoka.Session.whereis(session)
      assert_receive {:routed_turn, "back to parent", agent_id, ^parent_pid, parent_context}
      assert agent_id == session.agent_id
      assert parent_context == %{session: session.id, tenant: "acme"}
    after
      reset_agent(session.agent_id)
      reset_agent(handoff_agent_id)
      Jidoka.reset_handoff(session)
    end
  end

  test "handoff declarations validate names, targets, agents, and conflicts" do
    assert {:error, reason} = Jidoka.Handoff.Capability.new(JidokaTest.AddNumbers)
    assert reason =~ "valid Jidoka subagent"

    assert {:error, reason} =
             Jidoka.Handoff.Capability.new(BillingHandoffSpecialist, as: "Billing-Specialist")

    assert reason =~ "handoff names must start with a lowercase letter"

    assert {:error, reason} =
             Jidoka.Handoff.Capability.new(BillingHandoffSpecialist, target: :ephemeral)

    assert reason =~ "handoff target must be :auto"

    assert_raise Spark.Error.DslError, ~r/duplicate operation names.*add_numbers/s, fn ->
      Code.compile_string("""
      defmodule JidokaTest.DuplicateHandoffToolAgent do
        use Jidoka.Agent

        agent :duplicate_handoff_tool_agent do
          instructions "This should fail."
        end

        tools do
          action JidokaTest.AddNumbers
        end

        capabilities do
          handoff JidokaTest.BillingHandoffSpecialist, as: :add_numbers
        end
      end
      """)
    end
  end

  defp run_transfer(tool, conversation_id, context) do
    tool.run(%{message: "Please take over."}, handoff_context(conversation_id, context))
  end

  defp handoff_context(conversation_id, extra \\ []) do
    extra_map = Map.new(extra)
    request_id = Map.get(extra_map, :request_id, unique_id("req"))
    extra_map = Map.delete(extra_map, :request_id)

    Map.merge(
      %{
        Jidoka.Handoff.context_key() => conversation_id,
        Jidoka.Handoff.server_key() => self(),
        Jidoka.Handoff.request_id_key() => request_id,
        Jidoka.Handoff.from_agent_key() => HandoffRouterAgent.id()
      },
      extra_map
    )
  end

  defp handoff_tool(agent_module, name), do: find_tool(agent_module, name)

  defp cleanup_conversation(conversation_id) do
    case Jidoka.handoff_owner(conversation_id) do
      %{agent_id: agent_id} -> reset_agent(agent_id)
      _ -> :ok
    end

    Jidoka.reset_handoff(conversation_id)
  end

  defp reset_agent(agent_id) do
    case Jidoka.whereis(agent_id) do
      nil -> :ok
      pid -> Jidoka.stop_agent(pid)
    end
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
