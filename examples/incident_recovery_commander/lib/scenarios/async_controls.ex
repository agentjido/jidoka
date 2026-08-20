defmodule JidokaExamples.IncidentRecoveryCommander.Scenarios.AsyncControls do
  @moduledoc false

  alias Jidoka.{Cancellation, Stream}
  alias Jidoka.Memory.Store.InMemory, as: MemoryStore
  alias JidokaExamples.IncidentRecoveryCommander.{Agent, ScriptedLLM}

  @incident_id "IR-2026-0042"

  def stream(opts \\ []) do
    incident_id = Keyword.get(opts, :incident_id, @incident_id)
    request_id = Keyword.get(opts, :stream_request_id, "incident-commander-stream")
    observer = Keyword.get(opts, :observer, self())

    with {:ok, memory_pid} <- MemoryStore.start_link() do
      memory_store = {MemoryStore, pid: memory_pid}

      try do
        with {:ok, request} <-
               Jidoka.chat_async(Agent, "Stream the final incident brief.",
                 context: incident_context(incident_id),
                 llm: ScriptedLLM.streaming_brief(request_id, observer, incident_id),
                 memory_store: memory_store,
                 request_id: request_id,
                 session_id: "incident-stream-session",
                 stream: true
               ),
             stream = Jidoka.stream(request, stream_event_timeout_ms: 100),
             {:ok, answer} <- Jidoka.await(request, timeout: 1_000) do
          events = Enum.to_list(stream)

          {:ok,
           %{
             answer: answer,
             events: events,
             terminal_event_count: Enum.count(events, &Stream.terminal?/1),
             text: events |> Enum.map(&Stream.text_delta/1) |> Enum.reject(&is_nil/1) |> Enum.join(),
             thinking:
               events
               |> Enum.map(&Stream.thinking_delta/1)
               |> Enum.reject(&is_nil/1)
               |> Enum.join()
           }}
        end
      after
        stop_process(memory_pid)
      end
    end
  end

  def cancel(opts \\ []) do
    incident_id = Keyword.get(opts, :incident_id, @incident_id)
    request_id = Keyword.get(opts, :cancel_request_id, "incident-commander-cancel")
    observer = Keyword.get(opts, :observer, self())

    with {:ok, memory_pid} <- MemoryStore.start_link() do
      memory_store = {MemoryStore, pid: memory_pid}

      try do
        with {:ok, request} <-
               Jidoka.chat_async(Agent, "Start a cancellable incident drill.",
                 context: incident_context(incident_id),
                 llm: ScriptedLLM.cancellable(observer),
                 memory_store: memory_store,
                 request_id: request_id,
                 session_id: "incident-cancel-session",
                 stream: true
               ),
             {:ok, capability_pid} <- await_cancellable_model(request_id),
             {:ok, %Cancellation{} = cancellation} <- Jidoka.cancel(request, grace_ms: 500),
             {:cancelled, ^cancellation} <- Jidoka.await(request, timeout: 100) do
          events = request |> Jidoka.stream(stream_event_timeout_ms: 100) |> Enum.to_list()

          {:ok,
           %{
             cancellation: cancellation,
             capability_alive?: Process.alive?(capability_pid),
             terminal_event_count: Enum.count(events, &Stream.terminal?/1)
           }}
        end
      after
        stop_process(memory_pid)
      end
    end
  end

  defp incident_context(incident_id) do
    %{
      incident_id: incident_id,
      pause_recovery: false,
      region: "us-central",
      severity: :sev1,
      tenant_id: "northwind"
    }
  end

  defp await_cancellable_model(request_id) do
    receive do
      {:incident_cancellable_model_started, pid} -> {:ok, pid}
    after
      1_000 -> {:error, {:incident_cancellable_model_not_started, request_id}}
    end
  end

  defp stop_process(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  end
end
