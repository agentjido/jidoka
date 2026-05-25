defmodule Jidoka.Subagent.Runtime.Trace do
  @moduledoc false

  @spec emit(map(), map(), atom(), map()) :: :ok
  def emit(context, subagent, event, metadata) do
    measurements =
      case Map.get(metadata, :duration_ms) do
        duration_ms when is_integer(duration_ms) -> %{duration_ms: duration_ms}
        _ -> %{}
      end

    Jidoka.Trace.emit(
      :subagent,
      Jidoka.Trace.correlation_refs(context)
      |> Map.merge(%{
        event: event,
        subagent: subagent.name,
        name: subagent.name,
        target: inspect(subagent.target),
        request_id: Map.get(context, Jidoka.Subagent.Context.request_id_key()),
        agent_id: Map.get(context, Jidoka.Trace.agent_id_key())
      })
      |> Map.merge(metadata),
      measurements
    )
  end

  @spec metadata(map(), map()) :: map()
  def metadata(metadata, extra \\ %{}) when is_map(metadata) do
    metadata
    |> Map.take([
      :child_id,
      :child_request_id,
      :context_keys,
      :duration_ms,
      :mode,
      :outcome,
      :result_preview,
      :task_preview
    ])
    |> Map.merge(extra)
  end
end
