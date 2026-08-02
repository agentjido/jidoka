defmodule JidokaExamples.DurableRefund.Scenario do
  @moduledoc false

  alias Jidoka.Agent.Spec
  alias Jidoka.Agent.Spec.Controls
  alias Jidoka.Cancellation
  alias Jidoka.Harness.Session
  alias Jidoka.Harness.Store.InMemory
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.JidoActions
  alias Jidoka.Schema
  alias Jidoka.Stream
  alias Jidoka.Turn
  alias JidokaExamples.DurableRefund.Actions.IssueRefund
  alias JidokaExamples.DurableRefund.Agent
  alias JidokaExamples.DurableRefund.ScriptedLLM

  def run(opts) do
    opts = Keyword.drop(opts, [:credential_ref])

    with {:ok, recovery} <- durable_recovery(opts),
         {:ok, fork} <- safe_fork(opts) do
      {:ok,
       %{
         durable_recovery: %{
           answer: recovery.answer,
           operation_calls: recovery.operation_calls,
           session_revision: recovery.session.revision,
           status: recovery.session.status
         },
         safe_fork: %{
           branch_answer: fork.branch_answer,
           branch_id: fork.branch.session_id,
           lineage: Jidoka.project(fork.branch.lineage),
           source_answer: fork.source_answer,
           source_id: fork.source.session_id
         }
       }}
    end
  end

  def async_streaming(opts \\ []) do
    request_id = Keyword.get(opts, :request_id, "durable-refund-stream")
    observer = Keyword.get(opts, :observer, self())

    with {:ok, request} <-
           Jidoka.chat_async(Agent, "Stream refund guidance",
             request_id: request_id,
             stream: true,
             llm: ScriptedLLM.streaming(request_id, observer)
           ),
         stream = Jidoka.stream(request, stream_event_timeout_ms: 100),
         {:ok, "Refund guidance is ready." = answer} <- Jidoka.await(request, timeout: 1_000) do
      events = Enum.to_list(stream)

      {:ok,
       %{
         answer: answer,
         events: events,
         request_id: request_id,
         terminal_events: Enum.filter(events, &Stream.terminal?/1),
         text: events |> Enum.map(&Stream.text_delta/1) |> Enum.reject(&is_nil/1) |> Enum.join(),
         thinking: events |> Enum.map(&Stream.thinking_delta/1) |> Enum.reject(&is_nil/1) |> Enum.join()
       }}
    end
  end

  def typed_cancellation(opts \\ []) do
    observer = Keyword.get(opts, :observer, self())
    request_id = Keyword.get(opts, :request_id, "durable-refund-cancel")

    with {:ok, request} <-
           Jidoka.chat_async(Agent, "Cancel this refund check",
             request_id: request_id,
             stream: true,
             llm: ScriptedLLM.cancellable(observer)
           ),
         {:ok, capability_pid} <- await_capability_start(request_id),
         {:ok, %Cancellation{} = cancellation} <- Jidoka.cancel(request, grace_ms: 500),
         {:cancelled, ^cancellation} <- Jidoka.await(request, timeout: 100) do
      events =
        request
        |> Jidoka.stream(stream_event_timeout_ms: 100)
        |> Enum.to_list()

      {:ok,
       %{
         cancellation: cancellation,
         capability_alive?: Process.alive?(capability_pid),
         terminal_events: Enum.filter(events, &Stream.terminal?/1)
       }}
    end
  end

  def bounded_execution(opts \\ []) do
    observer = Keyword.get(opts, :observer, self())
    {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)
    spec = max_one_turn_spec()

    operation_llm = fn intent, _journal, _context ->
      max_tokens = Schema.get_key(intent.payload.generation.params, :max_tokens)
      send(observer, {:budget_max_tokens, max_tokens})

      {:ok,
       %{
         type: :operation,
         name: "issue_refund",
         arguments: %{"amount" => 42.0, "order_id" => "A1001"}
       }}
    end

    turn_result =
      Jidoka.turn(spec, "Issue the refund",
        llm: operation_llm,
        operations: JidoActions.operations([IssueRefund]),
        operation_context: %{refund_counter: counter}
      )

    slow_llm = fn _intent, _journal, _context ->
      Process.sleep(5_000)
      {:ok, %{type: :final, content: "too late"}}
    end

    timeout_result =
      Jidoka.turn(Agent, "Time out this model",
        llm: slow_llm,
        capability_timeout_ms: 5
      )

    receive do
      {:budget_max_tokens, max_tokens} ->
        {:ok,
         %{
           max_tokens: max_tokens,
           operation_calls: Elixir.Agent.get(counter, & &1),
           timeout_result: timeout_result,
           turn_result: turn_result
         }}
    after
      100 -> {:error, :missing_budget_observation}
    end
  end

  def durable_recovery(opts \\ []) do
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
           {:ok, [%Session{}]} <-
             Jidoka.Session.recoverable(store, clock: current_clock(clock)),
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

  def safe_fork(opts \\ []) do
    store = Keyword.get_lazy(opts, :fork_store, &in_memory_store/0)
    source_id = Keyword.get(opts, :source_session_id, "durable-refund-source")
    branch_id = Keyword.get(opts, :branch_session_id, "durable-refund-branch")

    with {:ok, %Session{}} <- Jidoka.Session.start(Agent, source_id, store: store),
         {:hibernate, %Session{} = source, %AgentSnapshot{} = snapshot} <-
           Jidoka.Session.run(source_id, "Choose a refund path",
             store: store,
             llm: ScriptedLLM.final("unused"),
             checkpoint: :after_prompt
           ),
         {:ok, %Session{} = branch} <-
           Jidoka.Session.fork(source_id,
             store: store,
             session_id: branch_id,
             snapshot: snapshot
           ),
         {:ok, %Session{} = finished_source, %Turn.Result{} = source_result} <-
           Jidoka.Session.resume(source_id,
             store: store,
             llm: ScriptedLLM.final("manual review path")
           ),
         {:ok, %Session{} = finished_branch, %Turn.Result{} = branch_result} <-
           Jidoka.Session.resume(branch_id,
             store: store,
             llm: ScriptedLLM.final("automatic refund path")
           ) do
      {:ok,
       %{
         branch: finished_branch,
         branch_answer: branch_result.content,
         branch_before_resume: branch,
         source: finished_source,
         source_answer: source_result.content,
         source_before_fork: source
       }}
    end
  end

  defp max_one_turn_spec do
    %Spec{controls: %Controls{} = current_controls} = spec = Agent.spec()
    controls = %Controls{current_controls | max_turns: 1}
    Spec.new!(%Spec{spec | controls: controls})
  end

  defp in_memory_store do
    {:ok, pid} = InMemory.start_link()
    {InMemory, pid: pid}
  end

  defp await_capability_start(request_id) do
    receive do
      {:cancellable_model_started, pid} -> {:ok, pid}
    after
      1_000 -> {:error, {:cancellable_model_not_started, request_id}}
    end
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
