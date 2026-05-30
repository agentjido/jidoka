defmodule Jidoka.HarnessSessionIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Controls
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Harness
  alias Jidoka.Harness.Session
  alias Jidoka.Harness.Store.InMemory
  alias Jidoka.Review
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Turn

  defmodule RequireReviewControl do
    @moduledoc false

    use Jidoka.Control, name: "require_review"

    @impl true
    def call(_operation), do: {:interrupt, :approval_required}
  end

  test "sessions persist hibernate and resume to completion through a store" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}
    spec = chat_spec()

    assert {:ok, %Session{session_id: "sess_chat"}} =
             Harness.start_session(spec, session_id: "sess_chat", store: store)

    llm = fn _intent, _journal -> {:ok, %{type: :final, content: "stored hello"}} end

    assert {:hibernate, %Session{status: :hibernated} = hibernated, %AgentSnapshot{} = snapshot} =
             Harness.run_session("sess_chat", "Say hello",
               store: store,
               llm: llm,
               checkpoint: :after_prompt
             )

    assert snapshot.cursor.phase == :after_prompt
    assert [%AgentSnapshot{}] = hibernated.snapshots

    assert {:ok, %Session{status: :finished} = finished, %Turn.Result{content: "stored hello"}} =
             Harness.resume_session("sess_chat", store: store, llm: llm)

    assert finished.session_id == "sess_chat"

    assert {:ok, %Session{status: :finished, result: %Turn.Result{content: "stored hello"}}} =
             Harness.store_get_session(store, "sess_chat")
  end

  test "sessions list pending approvals and resume approved operation reviews" do
    test_pid = self()
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}
    spec = review_spec()

    assert {:ok, %Session{session_id: "sess_review"}} =
             Harness.start_session(spec, session_id: "sess_review", store: store)

    llm = fn _intent, %Effect.Journal{} = journal ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "refund_order",
             arguments: %{"order_id" => "order_123"}
           }}

        1 ->
          {:ok, %{type: :final, content: "Refund refund_123 is queued."}}
      end
    end

    operations =
      LocalOperations.operations(%{
        refund_order: fn intent, _journal ->
          arguments = Jidoka.Schema.get_key(intent.payload, :arguments)
          send(test_pid, {:refund_called, arguments})
          {:ok, %{"refund_id" => "refund_123", "order_id" => arguments["order_id"]}}
        end
      })

    assert {:hibernate, %Session{status: :waiting} = waiting, %AgentSnapshot{} = snapshot} =
             Harness.run_session("sess_review", "Refund order_123",
               store: store,
               llm: llm,
               operations: operations
             )

    assert snapshot.cursor.phase == :review

    assert {:ok, [%Review.Request{interrupt_id: interrupt_id, operation: "refund_order"}]} =
             Harness.pending_reviews(store)

    assert waiting.pending_reviews |> hd() |> Map.get(:interrupt_id) == interrupt_id

    approval = Review.Response.approve(interrupt_id)

    assert {:ok, %Session{status: :finished, pending_reviews: []} = finished,
            %Turn.Result{content: "Refund refund_123 is queued."}} =
             Harness.resume_session("sess_review",
               store: store,
               approval: approval,
               llm: llm,
               operations: operations
             )

    assert_receive {:refund_called, %{"order_id" => "order_123"}}

    assert {:ok,
            %Harness.Replay{
              session_id: "sess_review",
              status: :finished,
              pending_reviews: [],
              timeline: timeline
            }} = Harness.replay(finished)

    assert Enum.any?(timeline, &(&1.event == :approval_requested))
    assert Enum.any?(timeline, &(&1.event == :approval_responded))
    assert Enum.any?(timeline, &(&1.event == :turn_finished))
  end

  defp chat_spec do
    Agent.Spec.new!(
      id: "session_chat_agent",
      instructions: "Answer tersely.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp review_spec do
    Agent.Spec.new!(
      id: "session_review_agent",
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
            %{control: RequireReviewControl, match: %{name: "refund_order"}}
          ]
        ),
      runtime_defaults: %{max_model_turns: 4}
    )
  end

  defp count_results(%Effect.Journal{results: results}, kind) do
    results
    |> Map.values()
    |> Enum.count(&(&1.kind == kind))
  end
end
