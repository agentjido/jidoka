defmodule JidokaExamples.DurableRefund.Scenarios.DurableRecovery do
  @moduledoc false

  alias Jidoka.Harness.Session
  alias Jidoka.Harness.Store.InMemory
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.JidoActions
  alias Jidoka.Turn
  alias JidokaExamples.DurableRefund.Actions.IssueRefund
  alias JidokaExamples.DurableRefund.Agent
  alias JidokaExamples.DurableRefund.ScriptedLLM

  def run(opts \\ []) do
    observer = Keyword.get(opts, :observer, self())
    session_id = Keyword.get(opts, :session_id, "durable-refund-recovery")
    store = Keyword.get_lazy(opts, :store, &in_memory_store/0)
    {:ok, clock} = Elixir.Agent.start_link(fn -> 100 end)
    {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)
    llm = ScriptedLLM.refund_round_trip()

    with {:ok, %Session{}} <- Jidoka.Session.start(Agent, session_id, store: store) do
      checkpoint_hook = fn stage, %AgentSnapshot{} = snapshot, _stored ->
        if stage == :result and snapshot.cursor.metadata["effect_kind"] == :operation do
          send(observer, {:durable_refund_result_saved, snapshot})

          receive do
            :acknowledge_durable_refund -> :ok
          end
        else
          :ok
        end
      end

      worker =
        Task.async(fn ->
          Jidoka.Session.run(session_id, "Refund order A1001",
            store: store,
            llm: llm,
            operation_context: %{example_observer: observer, refund_counter: counter},
            clock: current_clock(clock),
            lease_ttl_ms: 100,
            lease_heartbeat: false,
            owner_id: "refund-worker-1",
            on_durable_checkpoint: checkpoint_hook
          )
        end)

      with {:ok, durable_snapshot} <- await_durable_result(session_id),
           _shutdown <- Task.shutdown(worker, :brutal_kill),
           :ok <- Elixir.Agent.update(clock, fn _now -> 200 end),
           {:ok, [%Session{}]} <- Jidoka.Session.recoverable(store, clock: current_clock(clock)),
           {:ok, %Session{} = session, %Turn.Result{} = result} <-
             Jidoka.Session.recover(session_id,
               store: store,
               llm: llm,
               operations: JidoActions.operations([IssueRefund]),
               operation_context: %{example_observer: observer, refund_counter: counter},
               clock: current_clock(clock),
               lease_ttl_ms: 100,
               lease_heartbeat: false,
               owner_id: "refund-worker-2"
             ) do
        {:ok,
         %{
           answer: result.content,
           durable_snapshot: durable_snapshot,
           operation_calls: Elixir.Agent.get(counter, & &1),
           session: session
         }}
      end
    end
  end

  defp in_memory_store do
    {:ok, pid} = InMemory.start_link()
    {InMemory, pid: pid}
  end

  defp await_durable_result(session_id) do
    receive do
      {:durable_refund_result_saved, %AgentSnapshot{} = snapshot} -> {:ok, snapshot}
    after
      1_000 -> {:error, {:durable_refund_result_not_saved, session_id}}
    end
  end

  defp current_clock(clock), do: fn -> Elixir.Agent.get(clock, & &1) end
end
