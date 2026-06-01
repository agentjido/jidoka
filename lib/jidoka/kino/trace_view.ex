defmodule Jidoka.Kino.TraceView do
  @moduledoc false

  alias Jidoka.Harness
  alias Jidoka.Inspection.Preflight
  alias Jidoka.Kino.Render
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

  @doc false
  @spec trace(String.t(), (-> result), keyword()) :: result when result: term()
  def trace(label, fun, opts \\ []) when is_binary(label) and is_function(fun, 0) do
    result = fun.()

    if Keyword.get(opts, :render_trace?, true) do
      _ = timeline(result, Keyword.put(opts, :title, "#{label} timeline"))
    end

    result
  end

  @doc false
  @spec timeline(term(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def timeline(target, opts \\ []) do
    case resolve_timeline(target) do
      {:ok, timeline} ->
        Render.table(Keyword.get(opts, :title, "Trace timeline"), timeline, keys: timeline_keys(timeline))
        {:ok, timeline}

      {:error, message} ->
        Render.markdown("### Trace Timeline\n\n#{Render.escape_markdown(message)}")
        {:error, message}
    end
  end

  @doc false
  @spec trace_table(term(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def trace_table(target, opts \\ []), do: timeline(target, Keyword.put_new(opts, :title, "Trace events"))

  @doc false
  @spec call_graph(term(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def call_graph(target, opts \\ []) do
    case resolve_timeline(target) do
      {:ok, timeline} ->
        markdown = build_call_graph(timeline, opts)
        Render.markdown(markdown)
        {:ok, markdown}

      {:error, message} ->
        Render.markdown("### Trace Call Graph\n\n#{Render.escape_markdown(message)}")
        {:error, message}
    end
  end

  defp resolve_timeline({:ok, %Turn.Result{} = result}), do: resolve_timeline(result)

  defp resolve_timeline({:ok, %Harness.Session{} = session, %Turn.Result{} = result}),
    do: resolve_timeline([session, result])

  defp resolve_timeline({:ok, %Harness.Session{} = session, _content}), do: resolve_timeline(session)
  defp resolve_timeline({:hibernate, %AgentSnapshot{} = snapshot}), do: resolve_timeline(snapshot)

  defp resolve_timeline({:hibernate, %Harness.Session{} = session, %AgentSnapshot{} = snapshot}),
    do: resolve_timeline([session, snapshot])

  defp resolve_timeline({:error, reason}), do: {:error, Jidoka.Error.format(reason)}

  defp resolve_timeline(%Turn.Result{events: events}), do: {:ok, Jidoka.Extensions.Trace.timeline(events)}
  defp resolve_timeline(%Turn.State{events: events}), do: {:ok, Jidoka.Extensions.Trace.timeline(events)}

  defp resolve_timeline(%AgentSnapshot{turn_state: %Turn.State{events: events}}),
    do: {:ok, Jidoka.Extensions.Trace.timeline(events)}

  defp resolve_timeline(%Preflight{timeline: timeline}), do: {:ok, timeline}
  defp resolve_timeline(%Harness.Replay{timeline: timeline}), do: {:ok, timeline}

  defp resolve_timeline(%Harness.Session{} = session) do
    case Jidoka.Session.replay(session) do
      {:ok, %Harness.Replay{timeline: timeline}} -> {:ok, timeline}
      {:error, reason} -> {:error, Jidoka.Error.format(reason)}
    end
  end

  defp resolve_timeline([%Jidoka.Event{} | _rest] = events), do: {:ok, Jidoka.Extensions.Trace.timeline(events)}
  defp resolve_timeline([%{} | _rest] = timeline), do: {:ok, timeline}

  defp resolve_timeline(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      case resolve_timeline(target) do
        {:ok, timeline} -> {:cont, {:ok, acc ++ timeline}}
        {:error, _message} -> {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "No Jidoka timeline data found."}
      {:ok, timeline} -> {:ok, Enum.uniq_by(timeline, &timeline_identity/1)}
    end
  end

  defp resolve_timeline(%{timeline: timeline}) when is_list(timeline), do: {:ok, timeline}
  defp resolve_timeline(%{replay: %{timeline: timeline}}) when is_list(timeline), do: {:ok, timeline}
  defp resolve_timeline(%{events: events}) when is_list(events), do: resolve_timeline(events)

  defp resolve_timeline(target) do
    case Jidoka.inspect(target) do
      inspected when inspected != target -> resolve_timeline(inspected)
      _other -> {:error, "No Jidoka timeline data found."}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp timeline_identity(%{} = event) do
    {
      Map.get(event, :request_id),
      Map.get(event, :seq),
      Map.get(event, :category),
      Map.get(event, :phase),
      Map.get(event, :event),
      Map.get(event, :operation),
      Map.get(event, :effect_id)
    }
  end

  defp timeline_keys([]), do: [:seq, :category, :phase, :event, :operation, :status]

  defp timeline_keys(timeline) do
    preferred = [:seq, :category, :phase, :event, :operation, :effect_kind, :status]
    present = timeline |> Enum.flat_map(&Map.keys/1) |> MapSet.new()

    Enum.filter(preferred, &MapSet.member?(present, &1))
  end

  defp build_call_graph(timeline, opts) do
    direction = Keyword.get(opts, :direction, "TD")
    agent_label = agent_label(timeline)

    nodes = [
      "flowchart #{direction}",
      "  Agent[\"#{Render.mermaid_label(["Agent", agent_label])}\"]"
    ]

    graph_lines =
      timeline
      |> Enum.filter(&graph_event?/1)
      |> Enum.uniq_by(fn event ->
        {Map.get(event, :category), Map.get(event, :operation), Map.get(event, :effect_kind), Map.get(event, :phase)}
      end)
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {event, index} ->
        node_id = "N#{index}"

        [
          "  #{node_id}[\"#{Render.mermaid_label(graph_label(event))}\"]",
          "  Agent --> #{node_id}"
        ]
      end)

    ["```mermaid", Enum.join(nodes ++ graph_lines, "\n"), "```"]
    |> Enum.join("\n")
  end

  defp agent_label([%{} = event | _events]), do: Map.get(event, :agent_id) || "agent"
  defp agent_label(_timeline), do: "agent"

  defp graph_event?(%{} = event) do
    not is_nil(Map.get(event, :operation)) or
      Map.get(event, :category) in [:effect, :control, :memory, :review, :llm, :workflow]
  end

  defp graph_label(event) do
    [
      event |> Map.get(:category) |> label_part(),
      Map.get(event, :operation) || Map.get(event, :effect_kind) || Map.get(event, :phase),
      Map.get(event, :event),
      Map.get(event, :status)
    ]
  end

  defp label_part(nil), do: nil
  defp label_part(value) when is_atom(value), do: value |> Atom.to_string() |> String.capitalize()
  defp label_part(value), do: to_string(value)
end
