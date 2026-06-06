defmodule Jidoka.DebugReplayIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.{Controls, Operation}
  alias Jidoka.Debug
  alias Jidoka.Debug.{ReplayDiagnostics, RequestSummary}
  alias Jidoka.Effect
  alias Jidoka.Harness
  alias Jidoka.Harness.Session
  alias Jidoka.Review
  alias Jidoka.Runtime.{AgentSnapshot, LocalOperations}
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  defmodule RequireRefundReviewControl do
    @moduledoc false

    use Jidoka.Control, name: "require_refund_review"

    @impl true
    def call(_operation), do: {:interrupt, :approval_required}
  end

  test "completed session debug summary includes prompt, operations, usage, and replay diagnostics" do
    assert {:ok, %Session{} = session} =
             Harness.start_session(Jidoka.IntegrationSupport.AccountAgent.spec(),
               session_id: "sess_debug_completed"
             )

    request =
      Turn.Request.new!(
        input: "Check account acct_100.",
        request_id: "turn_debug_completed",
        context: %{test_pid: self()}
      )

    assert {:ok, %Session{} = session, %Turn.Result{} = result} =
             Harness.run_session(session, request,
               llm: account_llm("acct_100"),
               operations: account_operations()
             )

    assert_receive {:account_lookup_called, "acct_100"}

    assert {:ok,
            %RequestSummary{
              request_id: "turn_debug_completed",
              session_id: "sess_debug_completed",
              agent_id: "multi_turn_account_agent",
              status: :finished,
              model: "test:model",
              input: "Check account acct_100.",
              content: "Account acct_100 is on the Pro plan.",
              context_keys: ["test_pid"],
              operation_names: ["account_lookup"],
              replay_diagnostics: %ReplayDiagnostics{status: :complete}
            } = summary} = Debug.latest(session)

    assert result.metadata.debug.request_id == summary.request_id
    assert Enum.map(summary.prompt.messages, & &1.role) == [:system, :user, :tool]
    assert [%{operation: "account_lookup", output: %{account_id: "acct_100"}}] = summary.operation_results
    assert summary.usage.llm_calls == 2
    assert summary.usage.total_tokens == 12

    assert %{kind: :request_debug, replay_diagnostics: %{status: :complete}} =
             Jidoka.inspect(summary)
  end

  test "missing session request ids fail instead of returning the latest request" do
    assert {:ok, %Session{} = session} =
             Harness.start_session(Jidoka.IntegrationSupport.AccountAgent.spec(),
               session_id: "sess_debug_missing_request"
             )

    assert {:ok, %Session{} = session, %Turn.Result{}} =
             Harness.run_session(
               session,
               Turn.Request.new!(input: "Check account acct_200.", request_id: "turn_present"),
               llm: account_llm("acct_200"),
               operations: account_operations()
             )

    assert {:ok, %RequestSummary{request_id: "turn_present"}} =
             Debug.request(session, request_id: "turn_present")

    assert {:error, {:request_debug_not_found, "sess_debug_missing_request", "turn_missing"}} =
             Debug.request(session, request_id: "turn_missing")
  end

  test "checkpointed session debug summary captures incomplete pending effects" do
    assert {:ok, %Session{} = session} =
             Harness.start_session(Jidoka.IntegrationSupport.AccountAgent.spec(),
               session_id: "sess_debug_checkpoint"
             )

    assert {:hibernate, %Session{} = session, %AgentSnapshot{} = snapshot} =
             Harness.run_session(session, "Check account acct_300.",
               llm: account_llm("acct_300"),
               operations: account_operations(),
               checkpoint: :after_prompt
             )

    assert snapshot.cursor.phase == :after_prompt

    assert {:ok,
            %RequestSummary{
              status: :running,
              replay_diagnostics: %ReplayDiagnostics{
                status: :incomplete,
                missing_effect_results: [_missing],
                warnings: warnings
              }
            }} = Debug.latest(session)

    assert "Some effect intents do not have recorded results." in warnings
  end

  test "pending human review debug summary is durable and marks replay waiting" do
    assert {:ok, %Session{} = session} =
             Harness.start_session(refund_spec(), session_id: "sess_debug_review")

    assert {:hibernate, %Session{status: :waiting} = session, %AgentSnapshot{} = snapshot} =
             Harness.run_session(session, "Refund order_123",
               llm: refund_llm("order_123"),
               operations: refund_operations(self())
             )

    refute_received {:refund_called, _arguments, _idempotency}

    assert {:ok,
            %RequestSummary{
              status: :waiting,
              pending_reviews: [%{operation: "refund_order", arguments: %{"order_id" => "order_123"}}],
              replay_diagnostics: %ReplayDiagnostics{
                status: :waiting,
                missing_effect_results: [_missing],
                pending_reviews: [%{operation: "refund_order"}],
                unsafe_effects: [_unsafe],
                warnings: warnings
              }
            }} = Debug.latest(session)

    assert "Human review is still pending." in warnings
    assert "Some unsafe_once effects are not replay-safe." in warnings

    assert {:ok, serialized} = AgentSnapshot.serialize(snapshot)
    assert {:ok, %AgentSnapshot{} = deserialized} = AgentSnapshot.deserialize(serialized)

    assert {:ok,
            %RequestSummary{
              session_id: "sess_debug_review",
              replay_diagnostics: %ReplayDiagnostics{status: :waiting}
            }} = Debug.request(deserialized, session: session)
  end

  test "approved unsafe operations finish but still surface replay safety warnings" do
    assert {:ok, %Session{} = session} =
             Harness.start_session(refund_spec(), session_id: "sess_debug_unsafe")

    assert {:hibernate, %Session{} = session, %AgentSnapshot{} = snapshot} =
             Harness.run_session(session, "Refund order_456",
               llm: refund_llm("order_456"),
               operations: refund_operations(self())
             )

    interrupt_id = snapshot.turn_state.pending_interrupt.id
    approval = Review.Response.approve(interrupt_id)

    assert {:ok, %Session{} = session, %Turn.Result{content: "Refund refund_456 is queued."}} =
             Harness.resume_session(session,
               approval: approval,
               llm: refund_llm("order_456"),
               operations: refund_operations(self())
             )

    assert_receive {:refund_called, %{"order_id" => "order_456"}, :unsafe_once}

    assert {:ok,
            %RequestSummary{
              status: :finished,
              operation_names: ["refund_order"],
              replay_diagnostics: %ReplayDiagnostics{
                status: :complete,
                unsafe_effects: [%{idempotency: :unsafe_once}],
                warnings: warnings
              }
            }} = Debug.latest(session)

    assert "Some unsafe_once effects are not replay-safe." in warnings

    assert {:ok, %ReplayDiagnostics{status: :complete, unsafe_effects: [_unsafe]}} =
             Harness.Replay.diagnose(session)
  end

  defp account_operations do
    test_pid = self()

    LocalOperations.operations(%{
      "account_lookup" => fn intent, _journal, _ctx ->
        arguments = Jidoka.Schema.get_key(intent.payload, :arguments)
        account_id = arguments["account_id"]
        send(test_pid, {:account_lookup_called, account_id})
        {:ok, %{account_id: account_id, plan: "Pro", seats: 8}}
      end
    })
  end

  defp account_llm(account_id) do
    fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "account_lookup",
             arguments: %{"account_id" => account_id},
             metadata: %{usage: %{input_tokens: 2, output_tokens: 1, total_tokens: 3}}
           }}

        _count ->
          {:ok,
           %{
             type: :final,
             content: "Account #{account_id} is on the Pro plan.",
             metadata: %{usage: %{input_tokens: 5, output_tokens: 4, total_tokens: 9}}
           }}
      end
    end
  end

  defp refund_spec do
    Agent.Spec.new!(
      id: "debug_refund_agent",
      instructions: "Use refund_order when refunds are requested.",
      model: %{provider: :test, id: "model"},
      operations: [
        Operation.new!(
          name: "refund_order",
          description: "Starts a refund.",
          idempotency: :unsafe_once
        )
      ],
      controls:
        Controls.new!(
          operations: [
            %{control: RequireRefundReviewControl, match: %{name: "refund_order"}}
          ]
        ),
      runtime_defaults: %{max_model_turns: 4}
    )
  end

  defp refund_llm(order_id) do
    fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "refund_order",
             arguments: %{"order_id" => order_id}
           }}

        _count ->
          {:ok, %{type: :final, content: "Refund refund_456 is queued."}}
      end
    end
  end

  defp refund_operations(test_pid) do
    LocalOperations.operations(%{
      "refund_order" => fn intent, _journal, _ctx ->
        arguments = Jidoka.Schema.get_key(intent.payload, :arguments)
        send(test_pid, {:refund_called, arguments, intent.idempotency})
        {:ok, %{"refund_id" => "refund_456", "order_id" => arguments["order_id"]}}
      end
    })
  end
end
