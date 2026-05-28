defmodule JidokaTest.AgentViewContractTest do
  use JidokaTest.Support.Case, async: false

  alias Jidoka.Session
  alias JidokaTest.ChatAgent
  alias Jido.Thread.Agent, as: ThreadAgent

  defmodule ContractAgent do
    def id, do: "contract_agent"
  end

  defmodule AnonymousAgent do
  end

  defmodule StartableAgent do
    def id, do: "startable_agent"
    def start_link(_opts), do: {:ok, self()}
  end

  defmodule DefaultView do
    use Jidoka.AgentView, agent: ContractAgent
  end

  defmodule SessionView do
    use Jidoka.AgentView
  end

  defmodule RuntimeView do
    use Jidoka.AgentView, agent: ChatAgent
  end

  defmodule StartableView do
    use Jidoka.AgentView, agent: StartableAgent
  end

  defmodule InvalidPrepareView do
    use Jidoka.AgentView, agent: ContractAgent

    @impl Jidoka.AgentView
    def prepare(_input), do: :unexpected
  end

  defmodule ErrorPrepareView do
    use Jidoka.AgentView, agent: ContractAgent

    @impl Jidoka.AgentView
    def prepare(_input), do: {:error, :not_ready}
  end

  defmodule CustomView do
    use Jidoka.AgentView

    @impl Jidoka.AgentView
    def agent_module(_input), do: ContractAgent

    @impl Jidoka.AgentView
    def conversation_id(input), do: Jidoka.AgentView.normalize_id(input[:conversation], "demo")

    @impl Jidoka.AgentView
    def agent_id(input), do: "custom-agent-#{conversation_id(input)}"

    @impl Jidoka.AgentView
    def runtime_context(input) do
      %{
        channel: "test",
        session: conversation_id(input),
        account_id: input[:account_id]
      }
    end
  end

  test "default AgentView callbacks derive conversation, agent id, and runtime context" do
    input = %{"conversation_id" => "Case 123!"}

    assert DefaultView.conversation_id(input) == "case_123"
    assert DefaultView.agent_id(input) == "contract_agent-case_123"
    assert DefaultView.runtime_context(input) == %{session: "case_123"}
  end

  test "default AgentView callbacks derive from a Jidoka session" do
    session =
      Jidoka.Session.new!(
        agent: ContractAgent,
        id: "Case 123!",
        context: %{tenant: "acme"}
      )

    assert SessionView.agent_module(session) == ContractAgent
    assert SessionView.conversation_id(session) == "case_123"
    assert SessionView.agent_id(session) == "contract_agent-case_123"
    assert SessionView.runtime_context(session) == %{session: "case_123", tenant: "acme"}
  end

  test "AgentView default helpers normalize ids and arbitrary inputs" do
    assert Jidoka.AgentView.new(status: :running).status == :running
    assert Jidoka.AgentView.default_conversation_id(conversation_id: "VIP Case!") == "vip_case"
    assert Jidoka.AgentView.default_conversation_id(%{conversation_id: "Map Case"}) == "map_case"
    assert Jidoka.AgentView.default_conversation_id(%{"conversation_id" => "String Map"}) == "string_map"
    assert Jidoka.AgentView.default_conversation_id(%{conversation_id: "!!!"}) == "default"

    assert Jidoka.AgentView.default_agent_id(ContractAgent, "case_1") == "contract_agent-case_1"
    assert Jidoka.AgentView.default_agent_id(AnonymousAgent, "case_1") == "anonymous_agent-case_1"
    assert Jidoka.AgentView.default_runtime_context(:ignored, "case_1") == %{session: "case_1"}
    assert Jidoka.AgentView.normalize_id(" Billing / VIP ", "fallback") == "billing_vip"
    assert Jidoka.AgentView.normalize_id(nil, "fallback") == "fallback"

    request_id = Jidoka.AgentView.request_id()
    assert request_id =~ "agent-view-"
    assert Jidoka.AgentView.lifecycle_hooks() == [:before_turn, :after_turn, :snapshot]
    assert Jidoka.AgentView.ui_hooks() == [:before_turn, :after_turn, :snapshot]
  end

  test "AgentView state is projection-only, not persistence" do
    view =
      Jidoka.AgentView.new(
        agent_id: "contract-agent",
        conversation_id: "case_123",
        visible_messages: [%{role: :assistant, content: "Projected"}],
        metadata: %{projection: %{thread_id: "thread-123"}}
      )

    attrs = Map.from_struct(view)

    refute Map.has_key?(attrs, :pid)
    refute Map.has_key?(attrs, :thread)
    refute Map.has_key?(attrs, :transcript)
    refute Map.has_key?(attrs, :requests)
    refute Map.has_key?(attrs, :storage)
    refute Map.has_key?(attrs, :repo)

    updated = DefaultView.before_turn(view, "Need help")

    assert view.visible_messages == [%{role: :assistant, content: "Projected"}]
    assert [%{role: :assistant}, %{role: :user, pending?: true}] = updated.visible_messages
    refute Map.has_key?(Map.from_struct(updated), :transcript)
  end

  test "custom AgentView callbacks define the application surface" do
    input = %{conversation: "VIP Refund", account_id: "acct_123"}

    assert CustomView.agent_module(input) == ContractAgent
    assert CustomView.conversation_id(input) == "vip_refund"
    assert CustomView.agent_id(input) == "custom-agent-vip_refund"

    assert CustomView.runtime_context(input) == %{
             channel: "test",
             session: "vip_refund",
             account_id: "acct_123"
           }
  end

  test "AgentView starts and snapshots a session-owned runtime pid" do
    session =
      Session.new!(
        agent: ChatAgent,
        id: unique_id("agent-view-session"),
        context_ref: "support",
        context: %{tenant: "acme"}
      )

    try do
      assert {:ok, pid} = SessionView.start_agent(session)
      assert pid == Session.whereis(session)

      assert {:ok, view} = SessionView.snapshot(pid, session)

      assert view.agent_id == session.agent_id
      assert view.conversation_id == session.conversation_id
      assert view.runtime_context == %{session: session.id, tenant: "acme"}
      assert view.metadata.projection.context_ref == "support"
    after
      stop_session_agent(session)
    end
  end

  test "AgentView snapshots raw agents without requiring a running server" do
    agent = new_runtime_agent(ChatAgent.runtime_module())

    assert {:ok, view} = RuntimeView.snapshot(agent, %{conversation_id: "Raw Case!"})

    assert view.agent_id == agent.id
    assert view.conversation_id == "raw_case"
    assert view.runtime_context == %{session: "raw_case"}
    assert view.metadata.projection.entry_count == 0
  end

  test "custom AgentView snapshots keep custom identity and context projections" do
    agent = new_runtime_agent(ChatAgent.runtime_module())
    input = %{conversation: "VIP Refund", account_id: "acct_123"}

    assert {:ok, view} = CustomView.snapshot(agent, input)

    assert view.agent_id == agent.id
    assert view.conversation_id == "vip_refund"

    assert view.runtime_context == %{
             channel: "test",
             session: "vip_refund",
             account_id: "acct_123"
           }
  end

  test "AgentView snapshot stays consistent with the low-level thread projection" do
    agent =
      ChatAgent.runtime_module()
      |> new_runtime_agent()
      |> ThreadAgent.append([
        ai_message(:user, "I need refund help.", request_id: "req-projection"),
        ai_message(:assistant, "I can help with that.", request_id: "req-projection")
      ])

    assert {:ok, projection} = Jidoka.Agent.View.snapshot(agent)
    assert {:ok, view} = RuntimeView.snapshot(agent, %{conversation_id: "Projection Case"})

    assert view.visible_messages == projection.visible_messages
    assert view.llm_context == projection.llm_context
    assert view.streaming_message == projection.streaming_message
    assert view.events == projection.events

    assert view.metadata.projection == %{
             context_ref: projection.context_ref,
             thread_id: projection.thread_id,
             thread_rev: projection.thread_rev,
             entry_count: projection.entry_count
           }
  end

  test "before_turn adds optimistic user state without mutating rendered output concerns" do
    view = Jidoka.AgentView.new(agent_id: "contract-agent", conversation_id: "case_123")

    assert %{status: :idle, visible_messages: []} = DefaultView.before_turn(view, " ")

    running = DefaultView.before_turn(view, "  Need refund help  ")

    assert running.status == :running
    assert running.error == nil
    assert running.error_text == nil
    assert running.streaming_message == nil
    assert [%{role: :user, content: "Need refund help", pending?: true}] = running.visible_messages
  end

  test "compatibility submit alias delegates to before_turn" do
    view = Jidoka.AgentView.new(agent_id: "contract-agent", conversation_id: "case_123")

    submit = DefaultView.before_submit(view, "hello")
    turn = DefaultView.before_turn(view, "hello")

    assert submit.status == turn.status
    assert submit.error == turn.error
    assert submit.error_text == turn.error_text

    assert Enum.map(submit.visible_messages, &Map.drop(&1, [:id])) ==
             Enum.map(turn.visible_messages, &Map.drop(&1, [:id]))
  end

  test "after_turn preserves structured errors and provides formatted text" do
    reason = Jidoka.Error.validation_error("Bad input.", field: :message)
    agent = %Jido.Agent{id: "contract_agent", state: %{}}

    run = %Jidoka.AgentView.Run{
      request: Jido.AI.Request.Handle.new("req-test", self(), "hello"),
      agent_ref: agent,
      request_id: "req-test",
      conversation_id: "case_123",
      view_module: DefaultView,
      input: %{}
    }

    assert {:ok, updated} = DefaultView.after_turn(run, {:error, reason})

    assert updated.status == :error
    assert updated.error == reason
    assert updated.error_text == "Bad input."
    assert updated.outcome == {:error, reason}
  end

  test "visible_messages appends an in-flight streaming draft" do
    view =
      Jidoka.AgentView.new(
        visible_messages: [%{role: :user, content: "Hello"}],
        streaming_message: %{role: :assistant, content: "Working", streaming?: true}
      )

    assert [
             %{role: :user, content: "Hello"},
             %{role: :assistant, content: "Working", streaming?: true}
           ] = DefaultView.visible_messages(view)
  end

  test "start helper prepares and starts view-owned agents" do
    assert {:ok, pid} = StartableView.start_agent(%{conversation_id: "Start Me"})
    assert pid == self()
  end

  test "start helper normalizes invalid prepare callback returns" do
    assert {:error, %Jidoka.Error.ConfigError{} = error} =
             InvalidPrepareView.start_agent(%{})

    assert error.message =~ "AgentView prepare/1 must return"
    assert error.value == :unexpected

    assert ErrorPrepareView.start_agent(%{}) == {:error, :not_ready}
  end

  test "turn state helpers build runs and project interrupt and handoff outcomes" do
    request = Jido.AI.Request.Handle.new("req-agent-view-run", self(), "hello")

    run =
      Jidoka.AgentView.TurnState.build_run(
        DefaultView,
        request,
        %{conversation_id: "Case 42"},
        timeout: 123,
        conversation: "case_42"
      )

    assert run.request_id == "req-agent-view-run"
    assert run.conversation_id == "case_42"
    assert run.metadata == %{timeout: 123}

    view =
      Jidoka.AgentView.new(
        agent_id: "contract-agent",
        conversation_id: "case_42",
        streaming_message: %{role: :assistant, content: "Working"}
      )

    interrupt = Jidoka.Interrupt.new(id: "approval", message: "Approval needed", data: %{})
    interrupted = Jidoka.AgentView.TurnState.apply_result(view, {:interrupt, interrupt})

    assert interrupted.status == :interrupted
    assert interrupted.error_text == "Approval needed"
    assert interrupted.streaming_message == nil

    handoff =
      Jidoka.Handoff.new(
        conversation_id: "case_42",
        from_agent: "contract-agent",
        to_agent: ContractAgent,
        to_agent_id: "specialist",
        name: "specialist",
        message: "Escalating",
        context: %{}
      )

    handed_off = Jidoka.AgentView.TurnState.apply_result(view, {:handoff, handoff})

    assert handed_off.status == :handoff
    assert handed_off.error_text == "Conversation handed off to specialist."
    assert handed_off.outcome == {:handoff, handoff}
  end

  test "running visible messages preserves optimistic messages until refreshed state exists" do
    assert Jidoka.AgentView.TurnState.running_visible_messages([%{pending?: true}], []) == [%{pending?: true}]

    assert Jidoka.AgentView.TurnState.running_visible_messages([%{pending?: true}], [%{role: :assistant}]) == [
             %{role: :assistant}
           ]
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp ai_message(role, content, attrs) do
    payload =
      attrs
      |> Map.new()
      |> Map.merge(%{role: role, content: content, context_ref: Keyword.get(attrs, :context_ref, "default")})

    %{
      kind: :ai_message,
      payload: payload,
      refs: %{request_id: Map.get(payload, :request_id)}
    }
  end

  defp stop_session_agent(%Session{} = session) do
    case Session.whereis(session) do
      pid when is_pid(pid) -> Jidoka.stop_agent(pid)
      nil -> :ok
    end
  end
end
