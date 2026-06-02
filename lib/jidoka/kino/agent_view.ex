defmodule Jidoka.Kino.AgentView do
  @moduledoc false

  alias Jidoka.Inspection.Preflight
  alias Jidoka.Kino.Render

  @doc false
  @spec debug_agent(term(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def debug_agent(target, opts \\ []) do
    case inspect_target(target, opts) do
      {:ok, inspection} ->
        render_debug(inspection, opts)
        {:ok, inspection}

      {:error, message} ->
        Render.markdown("### Jidoka Debug\n\n#{Render.escape_markdown(message)}")
        {:error, message}
    end
  end

  @doc false
  @spec debug_request(term(), keyword()) :: {:ok, Jidoka.Debug.RequestSummary.t()} | {:error, String.t()}
  def debug_request(target, opts \\ []) do
    case Jidoka.Debug.request(target, opts) do
      {:ok, summary} ->
        render_request_summary(summary)
        {:ok, summary}

      {:error, reason} ->
        message = Jidoka.Error.format(reason)
        Render.markdown("### Request Debug\n\n#{Render.escape_markdown(message)}")
        {:error, message}
    end
  end

  @doc false
  @spec preflight(Jidoka.plan_input() | module(), Jidoka.request_input(), keyword()) ::
          {:ok, Preflight.t()} | {:error, String.t()}
  def preflight(agent_or_plan, request_input, opts \\ []) do
    case Jidoka.preflight(agent_or_plan, request_input, opts) do
      {:ok, %Preflight{} = preflight} ->
        render_preflight(preflight)
        {:ok, preflight}

      {:error, reason} ->
        message = Jidoka.Error.format(reason)
        Render.markdown("### Preflight\n\n#{Render.escape_markdown(message)}")
        {:error, message}
    end
  end

  @doc false
  @spec agent_diagram(term(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def agent_diagram(target, opts \\ []) do
    case inspect_target(target, opts) do
      {:ok, inspection} ->
        markdown = build_agent_diagram(inspection, opts)
        Render.markdown(markdown)
        {:ok, markdown}

      {:error, message} ->
        Render.markdown("### Agent Diagram\n\n#{Render.escape_markdown(message)}")
        {:error, message}
    end
  end

  defp inspect_target(%{kind: _kind} = inspection, _opts), do: {:ok, inspection}

  defp inspect_target(target, opts) do
    case Jidoka.inspect(target, opts) do
      %{kind: _kind} = inspection -> {:ok, inspection}
      other -> {:error, "Expected a Jidoka inspectable value, got: #{inspect(other)}"}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp render_debug(%{kind: kind} = inspection, _opts) when kind in [:agent, :plan] do
    spec = Map.get(inspection, :spec, %{})
    plan = Map.get(inspection, :plan, %{})

    Render.table("Agent summary", agent_summary_rows(inspection, spec, plan), keys: [:property, :value])
    render_optional_table("Operations", operation_rows(spec), [:name, :kind, :idempotency, :source])
    render_optional_table("Controls", control_rows(spec), [:surface, :count, :summary])
    render_optional_table("Workflow", workflow_rows(plan), [:property, :value])
  end

  defp render_debug(%{kind: :session} = inspection, _opts) do
    Render.table("Session summary", session_rows(inspection), keys: [:property, :value])

    inspection
    |> Map.get(:replay, %{})
    |> render_replay_preview()
  end

  defp render_debug(%{kind: :turn} = inspection, _opts) do
    Render.table("Turn summary", turn_rows(inspection), keys: [:property, :value])

    render_optional_table(
      "Turn timeline",
      Map.get(inspection, :timeline, []),
      timeline_keys(Map.get(inspection, :timeline, []))
    )
  end

  defp render_debug(%{kind: kind} = inspection, _opts) do
    rows =
      inspection
      |> Map.take([:kind, :status, :agent_id, :session_id, :request_count, :snapshot_count])
      |> Enum.map(fn {key, value} -> %{property: key, value: value} end)

    Render.table("#{kind} inspection", rows, keys: [:property, :value])
  end

  defp render_preflight(%Preflight{} = preflight) do
    Render.table("Preflight summary", preflight_rows(preflight), keys: [:property, :value])
    render_optional_table("Prompt messages", prompt_message_rows(preflight.prompt.messages), [:role, :content])
    render_optional_table("Preflight timeline", preflight.timeline, timeline_keys(preflight.timeline))
  end

  defp render_request_summary(summary) do
    projected = Jidoka.project(summary)

    Render.table("Request summary", request_summary_rows(projected), keys: [:property, :value])

    prompt_messages =
      projected
      |> get_in([:prompt, :messages])
      |> List.wrap()

    render_optional_table("Prompt messages", prompt_messages, [:role, :content])

    operation_rows =
      projected
      |> Map.get(:operation_results, [])
      |> operation_result_rows()

    render_optional_table("Operation results", operation_rows, [:operation, :preview])

    diagnostic_rows =
      projected
      |> Map.get(:replay_diagnostics)
      |> replay_diagnostic_rows()

    render_optional_table("Replay diagnostics", diagnostic_rows, [:property, :value])

    render_optional_table(
      "Request timeline",
      Map.get(projected, :timeline, []),
      timeline_keys(Map.get(projected, :timeline, []))
    )
  end

  defp request_summary_rows(summary) do
    [
      %{property: "request id", value: Map.get(summary, :request_id)},
      %{property: "session id", value: Map.get(summary, :session_id)},
      %{property: "agent id", value: Map.get(summary, :agent_id)},
      %{property: "status", value: Map.get(summary, :status)},
      %{property: "model", value: Map.get(summary, :model)},
      %{property: "input", value: summary |> Map.get(:input) |> Render.preview(200)},
      %{property: "content", value: summary |> Map.get(:content) |> Render.preview(220)},
      %{property: "operations", value: summary |> Map.get(:operation_names, []) |> Render.format_list()},
      %{property: "usage", value: summary |> Map.get(:usage, %{}) |> Render.inspect_value(12)},
      %{property: "diagnostics", value: summary |> Map.get(:diagnostics, []) |> Render.inspect_value(8)}
    ]
    |> Render.reject_blank_rows()
  end

  defp operation_result_rows(results) when is_list(results) do
    Enum.map(results, fn result ->
      %{
        operation: Map.get(result, :operation),
        preview: result |> Map.get(:output) |> Render.preview(220)
      }
    end)
  end

  defp replay_diagnostic_rows(nil), do: []

  defp replay_diagnostic_rows(diagnostics) do
    [
      %{property: "status", value: Map.get(diagnostics, :status)},
      %{property: "intents", value: Map.get(diagnostics, :intent_count)},
      %{property: "results", value: Map.get(diagnostics, :result_count)},
      %{property: "events", value: Map.get(diagnostics, :event_count)},
      %{property: "missing effect results", value: length(Map.get(diagnostics, :missing_effect_results, []))},
      %{property: "failed effect results", value: length(Map.get(diagnostics, :failed_effect_results, []))},
      %{property: "unsafe effects", value: length(Map.get(diagnostics, :unsafe_effects, []))},
      %{property: "pending reviews", value: length(Map.get(diagnostics, :pending_reviews, []))},
      %{property: "warnings", value: diagnostics |> Map.get(:warnings, []) |> Render.format_list()}
    ]
    |> Render.reject_blank_rows()
  end

  defp agent_summary_rows(inspection, spec, plan) do
    [
      %{property: "kind", value: Map.get(inspection, :kind)},
      %{property: "id", value: Map.get(spec, :id) || Map.get(plan, :spec_id)},
      %{property: "module", value: Map.get(inspection, :module)},
      %{property: "model", value: Map.get(spec, :model)},
      %{property: "instructions", value: Render.preview(Map.get(spec, :instructions), 160)},
      %{property: "operations", value: spec |> Map.get(:operations, []) |> length()},
      %{property: "max turns", value: Map.get(plan, :max_model_turns)},
      %{property: "timeout ms", value: Map.get(plan, :timeout_ms)},
      %{property: "memory", value: Render.inspect_value(Map.get(spec, :memory), 10)},
      %{property: "result", value: Render.inspect_value(Map.get(spec, :result), 10)}
    ]
    |> Render.reject_blank_rows()
  end

  defp operation_rows(spec) do
    spec
    |> Map.get(:operations, [])
    |> Enum.map(fn operation ->
      %{
        name: Map.get(operation, :name),
        kind: Map.get(operation, :kind),
        idempotency: Map.get(operation, :idempotency),
        source: operation |> Map.get(:source, %{}) |> source_summary()
      }
    end)
  end

  defp control_rows(spec) do
    controls = Map.get(spec, :controls, %{})

    [
      control_row("input", Map.get(controls, :inputs, [])),
      control_row("operation", Map.get(controls, :operations, [])),
      control_row("output", Map.get(controls, :outputs, [])),
      scalar_control_row("max_turns", Map.get(controls, :max_turns)),
      scalar_control_row("timeout_ms", Map.get(controls, :timeout_ms))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp workflow_rows(plan) do
    [
      %{property: "profile", value: Map.get(plan, :workflow_profile)},
      %{property: "phases", value: plan |> Map.get(:phases, []) |> Render.format_list()},
      %{property: "metadata", value: plan |> Map.get(:metadata, %{}) |> Render.inspect_value(12)}
    ]
    |> Render.reject_blank_rows()
  end

  defp preflight_rows(%Preflight{} = preflight) do
    [
      %{property: "agent", value: preflight.agent.id},
      %{property: "request", value: preflight.request.request_id},
      %{property: "model", value: preflight.prompt.model},
      %{property: "messages", value: length(preflight.prompt.messages)},
      %{property: "operations", value: length(preflight.prompt.operations)},
      %{property: "memory", value: Render.inspect_value(preflight.prompt.memory, 10)}
    ]
    |> Render.reject_blank_rows()
  end

  defp prompt_message_rows(messages) do
    Enum.map(messages, fn message ->
      %{
        role: Map.get(message, :role),
        content: message |> Map.get(:content) |> Render.preview(240)
      }
    end)
  end

  defp session_rows(inspection) do
    [
      %{property: "session id", value: Map.get(inspection, :session_id)},
      %{property: "agent id", value: Map.get(inspection, :agent_id)},
      %{property: "status", value: Map.get(inspection, :status)},
      %{property: "requests", value: Map.get(inspection, :request_count)},
      %{property: "snapshots", value: Map.get(inspection, :snapshot_count)},
      %{property: "pending reviews", value: inspection |> Map.get(:pending_reviews, []) |> length()}
    ]
    |> Render.reject_blank_rows()
  end

  defp turn_rows(inspection) do
    [
      %{property: "status", value: Map.get(inspection, :status)},
      %{property: "content", value: inspection |> Map.get(:content) |> Render.preview(240)},
      %{property: "events", value: inspection |> Map.get(:timeline, []) |> length()}
    ]
    |> Render.reject_blank_rows()
  end

  defp render_replay_preview(%{timeline: timeline}) when is_list(timeline) do
    render_optional_table("Session timeline", timeline, timeline_keys(timeline))
  end

  defp render_replay_preview(_replay), do: :ok

  defp render_optional_table(_title, [], _keys), do: :ok

  defp render_optional_table(title, rows, keys) do
    Render.table(title, rows, keys: keys)
  end

  defp source_summary(%{type: type, module: module}) when not is_nil(module), do: "#{type}: #{module}"
  defp source_summary(%{type: type}), do: type
  defp source_summary(source), do: Render.inspect_value(source, 8)

  defp control_row(_surface, []), do: nil

  defp control_row(surface, controls) when is_list(controls) do
    %{surface: surface, count: length(controls), summary: control_names(controls)}
  end

  defp scalar_control_row(_surface, nil), do: nil
  defp scalar_control_row(surface, value), do: %{surface: surface, count: 1, summary: value}

  defp control_names(controls) do
    controls
    |> Enum.map(fn control ->
      Map.get(control, :module) || Map.get(control, :name) || Render.inspect_value(control, 8)
    end)
    |> Render.format_list()
  end

  defp timeline_keys([]), do: [:seq, :category, :phase, :event, :operation, :status]

  defp timeline_keys(timeline) when is_list(timeline) do
    preferred = [:seq, :category, :phase, :event, :operation, :effect_kind, :status]
    present = timeline |> Enum.flat_map(&Map.keys/1) |> MapSet.new()

    Enum.filter(preferred, &MapSet.member?(present, &1))
  end

  defp build_agent_diagram(inspection, opts) do
    spec = Map.get(inspection, :spec, %{})
    plan = Map.get(inspection, :plan, %{})
    direction = Keyword.get(opts, :direction, "LR")
    agent_label = Map.get(spec, :id) || Map.get(plan, :spec_id) || "agent"
    model = Map.get(spec, :model) || "model"
    operations = operation_names(spec)
    controls = control_labels(spec)
    memory = if_present(Map.get(spec, :memory), "memory")
    result = if_present(Map.get(spec, :result), "output")

    nodes = [
      "flowchart #{direction}",
      "  Agent[\"#{Render.mermaid_label(["Agent", agent_label])}\"]",
      "  Model[\"#{Render.mermaid_label(["Model", model])}\"]",
      "  Runic[\"#{Render.mermaid_label(["Runic turn spine", Render.format_list(Map.get(plan, :phases, []))])}\"]",
      "  Model --> Runic",
      "  Runic --> Agent"
    ]

    optional_nodes =
      [
        {:Operations, "Operations", operations},
        {:Controls, "Controls", controls},
        {:Memory, "Memory", List.wrap(memory)},
        {:Output, "Output", List.wrap(result)}
      ]
      |> Enum.reject(fn {_id, _label, values} -> Enum.all?(values, &Render.blank?/1) end)
      |> Enum.flat_map(fn {node_id, label, values} ->
        [
          "  #{node_id}[\"#{Render.mermaid_label([label, Render.format_list(values)])}\"]",
          "  Agent --> #{node_id}"
        ]
      end)

    ["```mermaid", Enum.join(nodes ++ optional_nodes, "\n"), "```"]
    |> Enum.join("\n")
  end

  defp operation_names(spec) do
    spec
    |> Map.get(:operations, [])
    |> Enum.map(&(Map.get(&1, :name) || Render.inspect_value(&1, 8)))
  end

  defp control_labels(spec) do
    spec
    |> control_rows()
    |> Enum.map(fn row -> "#{row.surface}: #{row.count}" end)
  end

  defp if_present(nil, _label), do: nil
  defp if_present(%{} = value, _label) when map_size(value) == 0, do: nil
  defp if_present([], _label), do: nil
  defp if_present(_value, label), do: label
end
