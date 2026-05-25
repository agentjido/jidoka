defmodule Jidoka.Trace do
  @moduledoc """
  Structured run tracing for Jidoka agents.

  Jidoka trace data is a bounded in-memory projection over Jido/Jido.AI
  telemetry, enriched with Jidoka-specific lifecycle events for hooks,
  guardrails, memory, workflows, subagents, handoffs, MCP, and structured
  output.
  """

  alias Jidoka.Trace.{Collector, Event}

  @agent_id_key :__jidoka_agent_id__

  @type t :: %__MODULE__{
          trace_id: String.t() | nil,
          run_id: String.t() | nil,
          request_id: String.t() | nil,
          agent_id: term(),
          status: atom() | nil,
          started_at_ms: integer() | nil,
          completed_at_ms: integer() | nil,
          events: [Event.t()],
          summary: map()
        }

  defstruct [
    :trace_id,
    :run_id,
    :request_id,
    :agent_id,
    :status,
    :started_at_ms,
    :completed_at_ms,
    events: [],
    summary: %{}
  ]

  @doc false
  @spec agent_id_key() :: atom()
  def agent_id_key, do: @agent_id_key

  @doc false
  @spec emit(atom(), map(), map()) :: :ok
  def emit(category, metadata, measurements \\ %{})
      when is_atom(category) and is_map(metadata) and is_map(measurements) do
    metadata =
      metadata
      |> merge_correlation_refs()
      |> Map.put_new(:category, category)
      |> Map.put_new(:source, :jidoka)
      |> Jidoka.Sanitize.payload()

    Jido.Observe.emit_event([:jidoka, category, :event], Jidoka.Sanitize.payload(measurements), metadata)
  end

  @doc false
  @spec correlation_refs(map() | nil) :: map()
  def correlation_refs(nil), do: %{}

  def correlation_refs(%{} = source) do
    source
    |> nested_correlation_refs()
    |> Map.merge(source |> extract_correlation_refs() |> drop_nil_values())
    |> drop_nil_values()
  end

  def correlation_refs(_source), do: %{}

  @doc """
  Returns the latest trace for a running agent PID or Jidoka agent id.
  """
  @spec latest(pid() | String.t() | Jido.Agent.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def latest(target, opts \\ []) do
    target
    |> target_ref()
    |> Collector.latest(opts)
    |> wrap_trace_result()
  end

  @doc """
  Returns the trace associated with `request_id`.
  """
  @spec for_request(pid() | String.t() | Jido.Agent.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def for_request(target, request_id, opts \\ []) when is_binary(request_id) do
    target
    |> target_ref()
    |> Collector.for_request(request_id, opts)
    |> wrap_trace_result()
  end

  @doc """
  Lists retained traces for a running agent PID or Jidoka agent id.
  """
  @spec list(pid() | String.t() | Jido.Agent.t(), keyword()) :: {:ok, [t()]} | {:error, term()}
  def list(target, opts \\ []) do
    target
    |> target_ref()
    |> Collector.list(opts)
    |> case do
      {:ok, traces} -> {:ok, Enum.map(traces, &wrap_trace/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns normalized events for a trace or trace target.
  """
  @spec events(t() | pid() | String.t() | Jido.Agent.t(), keyword()) ::
          {:ok, [Event.t()]} | {:error, term()}
  def events(trace_or_target, opts \\ [])

  def events(%__MODULE__{} = trace, opts) do
    {:ok, maybe_limit(trace.events, Keyword.get(opts, :limit))}
  end

  def events(target, opts) do
    with {:ok, trace} <- latest(target, opts) do
      events(trace, opts)
    end
  end

  @doc """
  Derives coarse spans from a trace or trace target.
  """
  @spec spans(t() | pid() | String.t() | Jido.Agent.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def spans(trace_or_target, opts \\ [])

  def spans(%__MODULE__{} = trace, opts) do
    spans =
      trace.events
      |> Enum.group_by(&span_key/1)
      |> Enum.map(fn {_key, events} -> build_span(events) end)
      |> Enum.sort_by(fn span -> span.started_at_ms || 0 end)
      |> maybe_limit(Keyword.get(opts, :limit))

    {:ok, spans}
  end

  def spans(target, opts) do
    with {:ok, trace} <- latest(target, opts) do
      spans(trace, opts)
    end
  end

  defp target_ref(%Jido.Agent{id: agent_id, state: state}) do
    %{
      agent_id: agent_id,
      request_id: Map.get(state || %{}, :last_request_id)
    }
  end

  defp target_ref(target) do
    case agent_server_state(target) do
      {:ok, %{agent: %Jido.Agent{id: agent_id, state: state}}} ->
        %{
          agent_id: agent_id,
          request_id: Map.get(state || %{}, :last_request_id)
        }

      _ ->
        if is_binary(target), do: %{agent_id: target}, else: %{}
    end
  end

  defp agent_server_state(target) do
    Jido.AgentServer.state(target)
  rescue
    _error -> {:error, :not_found}
  catch
    :exit, _reason -> {:error, :not_found}
  end

  defp merge_correlation_refs(%{} = metadata) do
    metadata
    |> correlation_refs()
    |> Map.merge(metadata)
    |> drop_nil_values()
  end

  defp nested_correlation_refs(%{} = source) do
    [:extra_refs, :refs, :context, :tool_context, :runtime_context]
    |> Enum.reduce(%{}, fn key, acc ->
      case get_value(source, key) do
        %{} = nested -> Map.merge(acc, correlation_refs(nested))
        _ -> acc
      end
    end)
  end

  defp extract_correlation_refs(%{} = source) do
    %{
      session_id: get_value(source, :session_id) || get_value(source, :session),
      conversation_id:
        get_value(source, :conversation_id) ||
          get_value(source, Jidoka.Handoff.context_key()) ||
          get_value(source, :conversation),
      context_ref: get_value(source, :context_ref),
      request_id: get_value(source, :request_id),
      run_id: get_value(source, :run_id),
      trace_id: get_value(source, :trace_id) || get_value(source, :jido_trace_id),
      span_id: get_value(source, :span_id) || get_value(source, :jido_span_id),
      parent_span_id: get_value(source, :parent_span_id) || get_value(source, :jido_parent_span_id)
    }
  end

  defp get_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get_value(map, key) when is_map(map), do: Map.get(map, key)
  defp get_value(_map, _key), do: nil

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp maybe_limit(values, nil), do: values
  defp maybe_limit(values, limit) when is_integer(limit) and limit >= 0, do: Enum.take(values, limit)
  defp maybe_limit(values, _limit), do: values

  defp wrap_trace_result({:ok, trace}), do: {:ok, wrap_trace(trace)}
  defp wrap_trace_result({:error, reason}), do: {:error, reason}

  defp wrap_trace(%__MODULE__{} = trace), do: trace

  defp wrap_trace(trace) when is_map(trace) do
    fields = [
      :trace_id,
      :run_id,
      :request_id,
      :agent_id,
      :status,
      :started_at_ms,
      :completed_at_ms,
      :events,
      :summary
    ]

    struct(__MODULE__, Map.take(trace, fields))
  end

  defp span_key(%Event{} = event) do
    metadata = event.metadata || %{}

    id =
      metadata[:llm_call_id] ||
        metadata[:tool_call_id] ||
        metadata[:child_request_id] ||
        metadata[:conversation_id] ||
        event.name ||
        event.event

    {event.category, id}
  end

  defp build_span(events) do
    events = Enum.sort_by(events, & &1.seq)
    first = List.first(events)
    last = List.last(events)

    %{
      source: first.source,
      category: first.category,
      name: first.name,
      status: span_status(events) || last.status,
      started_at_ms: first.at_ms,
      completed_at_ms: terminal_time(events),
      duration_ms: span_duration(events),
      request_id: first.request_id,
      run_id: first.run_id,
      trace_id: first.trace_id,
      event_count: length(events),
      events: Enum.map(events, & &1.event)
    }
  end

  defp span_status(events) do
    Enum.find_value(Enum.reverse(events), fn event ->
      if event.status in [:completed, :failed, :cancelled, :interrupted] do
        event.status
      end
    end)
  end

  defp terminal_time(events) do
    Enum.find_value(Enum.reverse(events), fn event ->
      if event.status in [:completed, :failed, :cancelled, :interrupted] do
        event.at_ms
      end
    end)
  end

  defp span_duration(events) do
    Enum.find_value(Enum.reverse(events), & &1.duration_ms) ||
      case {List.first(events), terminal_time(events)} do
        {%Event{at_ms: started_at}, completed_at} when is_integer(completed_at) and completed_at >= started_at ->
          completed_at - started_at

        _ ->
          nil
      end
  end
end
