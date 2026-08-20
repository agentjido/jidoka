defmodule JidokaExamples.IncidentRecoveryCommander.Scenarios.Command do
  @moduledoc false

  alias Jidoka.{Effect, Event, Operation, Session, Snapshot, Trace}
  alias Jidoka.Memory.Store.InMemory, as: MemoryStore
  alias Jidoka.Session.Store.Dets
  alias Jidoka.Trace.Policy
  alias Jidoka.Trace.Sink.InMemory, as: TraceSink

  alias JidokaExamples.IncidentRecoveryCommander.{
    Agent,
    IncidentState,
    ScriptedLLM
  }

  @incident_id "IR-2026-0042"
  @session_table __MODULE__

  def run(opts \\ []) do
    with_snapshot_signing_secret(fn -> run_command(opts) end)
  end

  defp run_command(opts) do
    incident_id = Keyword.get(opts, :incident_id, @incident_id)
    session_id = Keyword.get(opts, :session_id, "incident-commander-session")
    path = dets_path()

    with {:ok, incident_state} <- IncidentState.start_link(),
         {:ok, memory_pid} <- MemoryStore.start_link(),
         {:ok, first_store_pid} <- start_session_store(path) do
      memory_store = {MemoryStore, pid: memory_pid}
      first_store = {Dets, pid: first_store_pid}
      llm = ScriptedLLM.capability(incident_id, incident_state)

      try do
        with {:ok, initial} <-
               initial_command(
                 first_store,
                 memory_store,
                 incident_state,
                 llm,
                 incident_id,
                 session_id
               ),
             :ok <- GenServer.stop(first_store_pid),
             {:ok, second_store_pid} <- start_session_store(path) do
          second_store = {Dets, pid: second_store_pid}

          try do
            resume_command(
              initial,
              second_store,
              memory_store,
              incident_state,
              llm,
              session_id
            )
          after
            stop_process(second_store_pid)
          end
        end
      after
        stop_process(first_store_pid)
        stop_process(memory_pid)
        stop_process(incident_state)
        File.rm(path)
      end
    end
  end

  defp initial_command(store, memory_store, incident_state, llm, incident_id, session_id) do
    opts = runtime_opts(store, memory_store, incident_state, llm)

    with {:ok, session} <- Session.start(Agent, session_id, store: store),
         {:ok, _write} <-
           Session.write_memory(
             session,
             "Runbook: isolate writes, preserve evidence, restore dependencies first, and publish only reviewed text.",
             memory_store: memory_store
           ),
         {:hibernate, waiting_session, %Snapshot{} = snapshot} <-
           Session.run(
             session_id,
             "Recover incident #{incident_id} and preserve a complete audit trail.",
             opts ++
               [
                 context: incident_context(incident_id, true),
                 request_id: "#{session_id}-command"
               ]
           ),
         {:ok, restored_snapshot} <- snapshot |> Snapshot.serialize!() |> Snapshot.deserialize(),
         {:ok, reviews} <- Jidoka.pending_reviews(waiting_session) do
      continuations = snapshot.metadata["operation_continuations"]

      {:ok,
       %{
         completed_operation_count: operation_result_count(snapshot.turn_state.journal),
         continuation_descriptors: Enum.map(continuations, &Operation.Continuation.descriptor/1),
         restored_snapshot: restored_snapshot,
         review_operations: Enum.map(reviews, & &1.operation),
         serialized_snapshot_bytes: byte_size(Snapshot.serialize!(snapshot)),
         snapshot: snapshot,
         waiting_revision: waiting_session.revision
       }}
    end
  end

  defp resume_command(initial, store, memory_store, incident_state, llm, session_id) do
    opts =
      store
      |> runtime_opts(memory_store, incident_state, llm)
      |> Keyword.put(:nested_resume_opts, context: %{pause_recovery: false})

    with {:ok, reloaded} <- Session.get(store, session_id),
         {:ok, reviews} <- Jidoka.pending_reviews(reloaded),
         {:ok, containment_review} <- find_review(reviews, "isolate_service"),
         {:hibernate, after_containment, after_containment_snapshot} <-
           Jidoka.approve(reloaded, containment_review, opts),
         {:ok, [communications_review]} <- Jidoka.pending_reviews(after_containment),
         true <- communications_review.operation == "publish_status_update",
         {:ok, completed_session, result} <-
           Jidoka.approve(after_containment, communications_review, opts),
         {:ok, replay} <- Session.replay(completed_session),
         {:ok, trace} <- trace_evidence(result) do
      state = IncidentState.snapshot(incident_state)

      {:ok,
       %{
         answer: result.content,
         approval_order: [containment_review.operation, communications_review.operation],
         completed_session: completed_session,
         counts: state.counts,
         initial: initial,
         intermediate_continuation_count: length(after_containment_snapshot.metadata["operation_continuations"]),
         memory_recalled?: Enum.any?(result.events, &(&1.event == :memory_recalled)),
         model_attempts: model_attempts(result),
         operation_names: Enum.map(result.agent_state.operation_results, & &1.operation),
         replay: replay,
         result: result,
         store_restart_revision: reloaded.revision,
         trace: trace,
         value: result.value
       }}
    else
      false -> {:error, :unexpected_remaining_review}
      {:error, _reason} = error -> error
      other -> {:error, {:incident_command_resume_failed, other}}
    end
  end

  defp runtime_opts(store, memory_store, incident_state, llm) do
    [
      store: store,
      llm: llm,
      memory_store: memory_store,
      model_policy: [
        models: [
          %{provider: :openai, id: "incident-commander-primary"},
          %{provider: :anthropic, id: "incident-commander-fallback"}
        ],
        retry: [max_attempts: 1],
        sleep: fn _delay -> :ok end
      ],
      operation_context: %{
        incident_state: incident_state,
        subagent_llm: llm,
        subagent_operation_context: %{incident_state: incident_state}
      },
      max_parallel_operations: 5
    ]
  end

  defp incident_context(incident_id, pause_recovery) do
    %{
      incident_id: incident_id,
      pause_recovery: pause_recovery,
      region: "us-central",
      severity: :sev1,
      tenant_id: "northwind"
    }
  end

  defp find_review(reviews, operation) do
    case Enum.find(reviews, &(&1.operation == operation)) do
      nil -> {:error, {:missing_incident_review, operation}}
      review -> {:ok, review}
    end
  end

  defp operation_result_count(%Effect.Journal{} = journal) do
    Enum.count(journal.results, fn {_id, result} -> result.kind == :operation end)
  end

  defp model_attempts(result) do
    result.events
    |> Enum.filter(&(&1.event == :capability_call_completed and &1.effect_kind == :llm))
    |> Enum.map(& &1.data.model_attempts)
  end

  defp trace_evidence(result) do
    with {:ok, sink} <- TraceSink.start_link() do
      sensitive_event =
        Event.build(:prompt_assembled, [],
          request_id: result.metadata.debug.request_id,
          data: %{
            api_key: "incident-example-secret",
            prompt: "raw incident prompt",
            visible: %{incident_id: result.value.incident_id, token: "incident-token"}
          }
        )

      try do
        with :ok <-
               Trace.record(result.events ++ [sensitive_event], {TraceSink, pid: sink}, policy: Policy.new!()) do
          entries = TraceSink.list(sink)

          {:ok,
           %{
             entries: entries,
             entry_count: length(entries),
             leaks_secret?: String.contains?(inspect(entries), "incident-example-secret")
           }}
        end
      after
        stop_process(sink)
      end
    end
  end

  defp start_session_store(path) do
    Dets.start_link(path: path, table: @session_table, auto_save: :infinity)
  end

  defp dets_path do
    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(System.tmp_dir!(), "jidoka-incident-commander-#{suffix}.dets")
  end

  defp stop_process(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  end

  defp with_snapshot_signing_secret(fun) do
    case Application.fetch_env(:jidoka, :snapshot_signing_secret) do
      {:ok, _secret} ->
        fun.()

      :error ->
        Application.put_env(
          :jidoka,
          :snapshot_signing_secret,
          "incident-recovery-commander-example-signing-secret"
        )

        try do
          fun.()
        after
          Application.delete_env(:jidoka, :snapshot_signing_secret)
        end
    end
  end
end
