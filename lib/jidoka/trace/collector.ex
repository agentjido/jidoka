defmodule Jidoka.Trace.Collector do
  @moduledoc """
  Bounded in-memory trace collector for Jidoka and Jido.AI telemetry.

  The collector is supervised by the Jidoka application supervisor and is
  intentionally internal. Public callers should use `Jidoka.Trace`.
  """

  use GenServer

  alias Jidoka.Trace.Event

  @handler_id "jidoka-trace-collector"
  @default_max_traces 100
  @default_max_events_per_trace 300

  @ai_events [
    [:jido, :ai, :request, :start],
    [:jido, :ai, :request, :complete],
    [:jido, :ai, :request, :failed],
    [:jido, :ai, :request, :cancelled],
    [:jido, :ai, :llm, :start],
    [:jido, :ai, :llm, :complete],
    [:jido, :ai, :llm, :error],
    [:jido, :ai, :tool, :start],
    [:jido, :ai, :tool, :complete],
    [:jido, :ai, :tool, :error],
    [:jido, :ai, :tool, :timeout]
  ]

  @jidoka_events [
    [:jidoka, :hook, :event],
    [:jidoka, :guardrail, :event],
    [:jidoka, :memory, :event],
    [:jidoka, :workflow, :event],
    [:jidoka, :subagent, :event],
    [:jidoka, :handoff, :event],
    [:jidoka, :mcp, :event],
    [:jidoka, :output, :event],
    [:jidoka, :credential, :event],
    [:jidoka, :schedule, :event]
  ]

  defstruct enabled?: true,
            max_traces: @default_max_traces,
            max_events_per_trace: @default_max_events_per_trace,
            seq: 0,
            traces: %{},
            order: [],
            by_agent: %{},
            by_request: %{},
            by_run: %{},
            by_trace: %{}

  @type t :: %__MODULE__{
          enabled?: boolean(),
          max_traces: pos_integer(),
          max_events_per_trace: pos_integer(),
          seq: non_neg_integer(),
          traces: map(),
          order: [term()],
          by_agent: map(),
          by_request: map(),
          by_run: map(),
          by_trace: map()
        }

  @type target_ref :: %{optional(:agent_id) => term(), optional(:request_id) => String.t()}

  @doc "Starts the trace collector process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the latest trace matching an agent or request reference."
  @spec latest(target_ref(), keyword()) :: {:ok, map()} | {:error, term()}
  def latest(ref, opts \\ []) when is_map(ref) do
    GenServer.call(__MODULE__, {:latest, ref, opts})
  end

  @doc "Returns the trace for a specific request id."
  @spec for_request(target_ref(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def for_request(ref, request_id, opts \\ []) when is_map(ref) and is_binary(request_id) do
    GenServer.call(__MODULE__, {:for_request, ref, request_id, opts})
  end

  @doc "Lists retained traces matching an agent reference."
  @spec list(target_ref(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(ref, opts \\ []) when is_map(ref) do
    GenServer.call(__MODULE__, {:list, ref, opts})
  end

  @doc false
  def handle_telemetry(event_name, measurements, metadata, _config)
      when is_list(event_name) and is_map(measurements) and is_map(metadata) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, {:telemetry_event, event_name, measurements, metadata})
    end
  end

  @impl true
  def init(_opts) do
    attach_handlers()
    {:ok, struct(__MODULE__, trace_config())}
  end

  @impl true
  def handle_call({:latest, ref, opts}, _from, state) do
    trace =
      case Map.get(ref, :request_id) do
        request_id when is_binary(request_id) -> trace_by_request(state, request_id)
        _ -> latest_for_agent(state, Map.get(ref, :agent_id))
      end

    {:reply, maybe_reply_trace(trace, opts), state}
  end

  def handle_call({:for_request, _ref, request_id, opts}, _from, state) do
    {:reply, maybe_reply_trace(trace_by_request(state, request_id), opts), state}
  end

  def handle_call({:list, ref, opts}, _from, state) do
    traces =
      case Map.get(ref, :agent_id) do
        nil -> Enum.map(state.order, &Map.fetch!(state.traces, &1))
        agent_id -> traces_for_agent(state, agent_id)
      end
      |> maybe_limit(Keyword.get(opts, :limit))

    {:reply, {:ok, traces}, state}
  end

  @impl true
  def handle_info({:telemetry_event, event_name, measurements, metadata}, %{enabled?: true} = state) do
    {:noreply, record_event(state, event_name, measurements, metadata)}
  end

  def handle_info({:telemetry_event, _event_name, _measurements, _metadata}, state), do: {:noreply, state}

  defp attach_handlers do
    _ = :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach_many(
        @handler_id,
        @ai_events ++ @jidoka_events,
        &__MODULE__.handle_telemetry/4,
        nil
      )
  end

  defp trace_config do
    config = Application.get_env(:jidoka, :trace, [])

    %{
      enabled?: config_value(config, :enabled?, true),
      max_traces:
        normalize_positive_integer(config_value(config, :max_traces, @default_max_traces), @default_max_traces),
      max_events_per_trace:
        normalize_positive_integer(
          config_value(config, :max_events_per_trace, @default_max_events_per_trace),
          @default_max_events_per_trace
        )
    }
  end

  defp config_value(config, key, default) when is_list(config), do: Keyword.get(config, key, default)
  defp config_value(config, key, default) when is_map(config), do: Map.get(config, key, default)
  defp config_value(_config, _key, default), do: default

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_value, default), do: default

  defp record_event(state, event_name, measurements, metadata) do
    seq = state.seq + 1

    case normalize_event(seq, event_name, measurements, metadata) do
      nil ->
        %{state | seq: seq}

      %Event{} = event ->
        key = trace_key(event)
        trace = state.traces |> Map.get(key, new_trace(event)) |> append_event(event, state.max_events_per_trace)
        traces = Map.put(state.traces, key, trace)
        order = append_order(state.order, key)

        %{state | seq: seq, traces: traces, order: order}
        |> prune_traces()
        |> rebuild_indexes()
    end
  end

  defp normalize_event(seq, event_name, measurements, metadata) do
    with {:ok, source, category, event} <- event_shape(event_name, metadata) do
      sanitized_measurements = Jidoka.Sanitize.payload(measurements)
      sanitized_metadata = Jidoka.Sanitize.payload(metadata)
      request_id = string_value(metadata, :request_id)
      run_id = string_value(metadata, :run_id) || request_id
      trace_id = string_value(metadata, :jido_trace_id) || string_value(metadata, :trace_id) || run_id || request_id

      %Event{
        seq: seq,
        at_ms: event_time_ms(measurements, metadata),
        source: source,
        category: category,
        event: event,
        phase: atom_value(metadata, :phase) || atom_value(metadata, :stage),
        name: event_name_label(category, metadata),
        status: event_status(category, event, metadata),
        duration_ms: duration_ms(measurements),
        request_id: request_id,
        run_id: run_id,
        trace_id: trace_id || "trace_unattributed_#{seq}",
        span_id: string_value(metadata, :jido_span_id) || string_value(metadata, :span_id),
        parent_span_id: string_value(metadata, :jido_parent_span_id) || string_value(metadata, :parent_span_id),
        measurements: sanitized_measurements,
        metadata: sanitized_metadata
      }
    else
      _other -> nil
    end
  end

  defp event_shape([:jido, :ai, :request, event], _metadata), do: {:ok, :jido_ai, :request, event}
  defp event_shape([:jido, :ai, :llm, event], _metadata), do: {:ok, :jido_ai, :model, event}
  defp event_shape([:jido, :ai, :tool, event], _metadata), do: {:ok, :jido_ai, :tool, event}

  defp event_shape([:jidoka, category, :event], metadata) when is_atom(category) do
    {:ok, :jidoka, category, atom_value(metadata, :event) || :event}
  end

  defp event_shape(_event_name, _metadata), do: :error

  defp event_time_ms(measurements, metadata) do
    cond do
      is_integer(get_value(metadata, :at_ms)) ->
        get_value(metadata, :at_ms)

      is_integer(get_value(measurements, :system_time)) ->
        System.convert_time_unit(get_value(measurements, :system_time), :nanosecond, :millisecond)

      true ->
        System.system_time(:millisecond)
    end
  end

  defp duration_ms(measurements) do
    cond do
      is_number(get_value(measurements, :duration_ms)) and get_value(measurements, :duration_ms) > 0 ->
        round(get_value(measurements, :duration_ms))

      is_integer(get_value(measurements, :duration)) and get_value(measurements, :duration) > 0 ->
        System.convert_time_unit(get_value(measurements, :duration), :nanosecond, :millisecond)

      true ->
        nil
    end
  end

  defp event_name_label(:request, metadata), do: string_value(metadata, :agent_id)
  defp event_name_label(:model, metadata), do: string_value(metadata, :model)
  defp event_name_label(:tool, metadata), do: string_value(metadata, :tool_name)
  defp event_name_label(:workflow, metadata), do: string_value(metadata, :workflow) || string_value(metadata, :name)
  defp event_name_label(:subagent, metadata), do: string_value(metadata, :subagent) || string_value(metadata, :name)
  defp event_name_label(:handoff, metadata), do: string_value(metadata, :handoff) || string_value(metadata, :name)
  defp event_name_label(:guardrail, metadata), do: string_value(metadata, :guardrail) || string_value(metadata, :label)
  defp event_name_label(:hook, metadata), do: string_value(metadata, :hook) || string_value(metadata, :label)
  defp event_name_label(:memory, metadata), do: string_value(metadata, :namespace)
  defp event_name_label(:compaction, metadata), do: string_value(metadata, :compaction) || string_value(metadata, :name)
  defp event_name_label(:mcp, metadata), do: string_value(metadata, :endpoint)
  defp event_name_label(:output, metadata), do: string_value(metadata, :output) || string_value(metadata, :name)

  defp event_name_label(:credential, metadata),
    do: string_value(metadata, :provider) || string_value(metadata, :tool_name)

  defp event_name_label(:schedule, metadata), do: string_value(metadata, :schedule_id) || string_value(metadata, :name)
  defp event_name_label(_category, metadata), do: string_value(metadata, :name)

  defp event_status(:request, :start, _metadata), do: :running
  defp event_status(:request, :complete, _metadata), do: :completed
  defp event_status(:request, :failed, _metadata), do: :failed
  defp event_status(:request, :cancelled, _metadata), do: :cancelled
  defp event_status(_category, event, _metadata) when event in [:start, :started], do: :running

  defp event_status(_category, event, _metadata) when event in [:stop, :complete, :completed, :ok, :allow],
    do: :completed

  defp event_status(:compaction, event, _metadata) when event in [:summarized, :skipped], do: :completed

  defp event_status(_category, event, _metadata) when event in [:error, :failed, :timeout, :block], do: :failed
  defp event_status(_category, event, _metadata) when event in [:interrupt, :interrupted], do: :interrupted

  defp event_status(_category, _event, metadata),
    do: atom_value(metadata, :status) || outcome_status(get_value(metadata, :outcome))

  defp outcome_status(:ok), do: :completed
  defp outcome_status(:allow), do: :completed
  defp outcome_status(:block), do: :failed
  defp outcome_status(:error), do: :failed
  defp outcome_status(:interrupt), do: :interrupted
  defp outcome_status({:error, _reason}), do: :failed
  defp outcome_status({:interrupt, _interrupt}), do: :interrupted
  defp outcome_status(_outcome), do: nil

  defp new_trace(%Event{} = event) do
    %{
      trace_id: event.trace_id,
      run_id: event.run_id,
      request_id: event.request_id,
      agent_id: get_value(event.metadata, :agent_id),
      status: event.status,
      started_at_ms: event.at_ms,
      completed_at_ms: nil,
      events: [],
      summary: %{}
    }
  end

  defp append_event(%{events: events} = trace, %Event{} = event, max_events) do
    events = Enum.take(events ++ [event], -max_events)
    status = terminal_status(event.status) || trace.status || event.status

    %{
      trace
      | trace_id: trace.trace_id || event.trace_id,
        run_id: trace.run_id || event.run_id,
        request_id: trace.request_id || event.request_id,
        agent_id: trace.agent_id || get_value(event.metadata, :agent_id),
        status: status,
        started_at_ms: min_time(trace.started_at_ms, event.at_ms),
        completed_at_ms: completed_at(trace.completed_at_ms, event),
        events: events,
        summary: trace_summary(events, status)
    }
  end

  defp completed_at(current, %Event{status: status, at_ms: at_ms})
       when status in [:completed, :failed, :cancelled, :interrupted],
       do: at_ms || current

  defp completed_at(current, _event), do: current

  defp min_time(nil, at_ms), do: at_ms
  defp min_time(current, nil), do: current
  defp min_time(current, at_ms), do: min(current, at_ms)

  defp terminal_status(status) when status in [:completed, :failed, :cancelled, :interrupted], do: status
  defp terminal_status(_status), do: nil

  defp trace_summary(events, status) do
    %{
      status: status,
      event_count: length(events),
      model_events: count_category(events, :model),
      tool_events: count_category(events, :tool),
      workflow_events: count_category(events, :workflow),
      subagent_events: count_category(events, :subagent),
      handoff_events: count_category(events, :handoff),
      guardrail_events: count_category(events, :guardrail),
      memory_events: count_category(events, :memory),
      compaction_events: count_category(events, :compaction),
      output_events: count_category(events, :output),
      schedule_events: count_category(events, :schedule),
      error_events: Enum.count(events, &(&1.status == :failed))
    }
  end

  defp count_category(events, category), do: Enum.count(events, &(&1.category == category))

  defp trace_key(%Event{request_id: request_id}) when is_binary(request_id), do: {:request, request_id}
  defp trace_key(%Event{run_id: run_id}) when is_binary(run_id), do: {:run, run_id}
  defp trace_key(%Event{trace_id: trace_id}) when is_binary(trace_id), do: {:trace, trace_id}
  defp trace_key(%Event{seq: seq}), do: {:event, seq}

  defp append_order(order, key) do
    if key in order, do: order, else: order ++ [key]
  end

  defp prune_traces(%__MODULE__{} = state) do
    extra_count = length(state.order) - state.max_traces

    if extra_count > 0 do
      {drop, keep} = Enum.split(state.order, extra_count)
      %{state | order: keep, traces: Map.drop(state.traces, drop)}
    else
      state
    end
  end

  defp rebuild_indexes(%__MODULE__{} = state) do
    indexes =
      Enum.reduce(state.traces, %{by_agent: %{}, by_request: %{}, by_run: %{}, by_trace: %{}}, fn {key, trace}, acc ->
        acc
        |> put_index(:by_agent, trace.agent_id, key)
        |> put_index(:by_request, trace.request_id, key)
        |> put_index(:by_run, trace.run_id, key)
        |> put_index(:by_trace, trace.trace_id, key)
      end)

    Map.merge(state, indexes)
  end

  defp put_index(acc, _index, nil, _key), do: acc

  defp put_index(acc, :by_agent = index, value, key) do
    update_in(acc[index], fn values -> Map.update(values, value, [key], &append_order(&1, key)) end)
  end

  defp put_index(acc, index, value, key), do: update_in(acc[index], &Map.put(&1, value, key))

  defp trace_by_request(state, request_id) do
    case Map.fetch(state.by_request, request_id) do
      {:ok, key} -> Map.get(state.traces, key)
      :error -> nil
    end
  end

  defp latest_for_agent(_state, nil), do: nil

  defp latest_for_agent(state, agent_id) do
    state.by_agent
    |> Map.get(agent_id, [])
    |> List.last()
    |> case do
      nil -> nil
      key -> Map.get(state.traces, key)
    end
  end

  defp traces_for_agent(state, agent_id) do
    state.by_agent
    |> Map.get(agent_id, [])
    |> Enum.map(&Map.fetch!(state.traces, &1))
  end

  defp maybe_reply_trace(nil, opts) do
    request_id = Keyword.get(opts, :request_id)
    {:error, Jidoka.Error.Normalize.debug_error(:request_not_found, request_id: request_id)}
  end

  defp maybe_reply_trace(%{} = trace, _opts), do: {:ok, trace}

  defp maybe_limit(values, nil), do: values
  defp maybe_limit(values, limit) when is_integer(limit) and limit >= 0, do: Enum.take(values, limit)
  defp maybe_limit(values, _limit), do: values

  defp get_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp string_value(map, key) do
    case get_value(map, key) do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      value when is_float(value) -> Float.to_string(value)
      _ -> nil
    end
  end

  defp atom_value(map, key) do
    case get_value(map, key) do
      value when is_atom(value) -> value
      value when is_binary(value) and value != "" -> existing_atom(value)
      _ -> nil
    end
  end

  defp existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end
end
