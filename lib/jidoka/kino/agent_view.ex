defmodule Jidoka.Kino.AgentView do
  @moduledoc false

  alias Jidoka.Kino.Render

  @spec debug_agent(module() | struct() | pid() | String.t() | map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def debug_agent(target, opts \\ []) do
    case inspect_agent_target(target) do
      {:ok, inspection} ->
        render_agent_debug(inspection, opts)
        {:ok, inspection}

      {:error, reason} ->
        message = Jidoka.Error.format(reason)
        Render.markdown("### Agent Debug\n\n#{Render.escape_markdown(message)}")
        {:error, message}
    end
  end

  @spec debug_request(Jidoka.Session.t() | pid() | String.t() | Jido.Agent.t() | map(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def debug_request(target, opts \\ []) do
    case inspect_request_target(target, opts) do
      {:ok, summary} ->
        render_request_debug(summary, opts)
        {:ok, summary}

      {:error, reason} ->
        message = Jidoka.Error.format(reason)
        Render.markdown("### Request Debug\n\n#{Render.escape_markdown(message)}")
        {:error, message}
    end
  end

  @spec agent_diagram(module() | struct() | pid() | String.t() | map(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def agent_diagram(target, opts \\ []) do
    case inspect_agent_target(target) do
      {:ok, inspection} ->
        markdown = build_agent_diagram(inspection, opts)
        Render.markdown(markdown)
        {:ok, markdown}

      {:error, reason} ->
        message = Jidoka.Error.format(reason)
        Render.markdown("### Agent Diagram\n\n#{Render.escape_markdown(message)}")
        {:error, message}
    end
  end

  defp inspect_agent_target(%{kind: _kind} = inspection), do: {:ok, inspection}
  defp inspect_agent_target(target), do: Jidoka.Inspection.inspect_agent(target)

  defp inspect_request_target(%{request_id: _request_id} = summary, _opts), do: {:ok, summary}

  defp inspect_request_target(target, opts) do
    case Keyword.get(opts, :request_id) do
      request_id when is_binary(request_id) -> Jidoka.inspect_request(target, request_id)
      _ -> Jidoka.inspect_request(target)
    end
  end

  defp render_agent_debug(inspection, _opts) do
    Render.table("Agent summary", agent_summary_rows(inspection), keys: [:property, :value])

    definition = inspection_definition(inspection)

    Render.table("Agent capabilities", capability_rows(definition), keys: [:surface, :count, :names])

    Render.table("Agent lifecycle", lifecycle_rows(definition), keys: [:surface, :summary])

    case Map.get(inspection, :last_request) do
      nil -> :ok
      request -> render_request_debug(request, title: "Latest request")
    end
  end

  defp render_request_debug(request, opts) when is_map(request) do
    title = Keyword.get(opts, :title, "Request debug")

    Render.table(title, request_rows(request), keys: [:property, :value])
    render_optional_table("Prompt preview", prompt_preview_rows(request), [:surface, :preview])
    render_optional_table("Capability calls", request_call_rows(request), [:surface, :count, :summary])
  end

  defp agent_summary_rows(%{kind: :running_agent} = inspection) do
    definition = inspection_definition(inspection)

    [
      %{property: "kind", value: "running agent"},
      %{property: "id", value: Map.get(inspection, :id)},
      %{property: "name", value: Map.get(inspection, :name)},
      %{property: "runtime", value: Render.format_module(Map.get(inspection, :runtime_module))},
      %{property: "owner", value: Render.format_module(Map.get(inspection, :owner_module))},
      %{
        property: "model",
        value: Render.inspect_value(Map.get(definition, :model) || Map.get(definition, :configured_model))
      },
      %{property: "requests", value: Map.get(inspection, :request_count, 0)},
      %{property: "last request", value: Map.get(inspection, :last_request_id)}
    ]
    |> Render.reject_blank_rows()
  end

  defp agent_summary_rows(definition) when is_map(definition) do
    [
      %{property: "kind", value: Map.get(definition, :kind)},
      %{property: "id", value: Map.get(definition, :id)},
      %{property: "name", value: Map.get(definition, :name)},
      %{property: "module", value: Render.format_module(Map.get(definition, :module))},
      %{property: "runtime", value: Render.format_module(Map.get(definition, :runtime_module))},
      %{
        property: "model",
        value: Render.inspect_value(Map.get(definition, :model) || Map.get(definition, :configured_model))
      },
      %{property: "description", value: Map.get(definition, :description)}
    ]
    |> Render.reject_blank_rows()
  end

  defp capability_rows(definition) when is_map(definition) do
    [
      capability_row("tools", list_value(definition, [:tool_names])),
      capability_row("plugins", list_value(definition, [:plugin_names, :plugins])),
      capability_row("skills", list_value(definition, [:skill_names, :skills])),
      capability_row("workflows", list_value(definition, [:workflow_names, :workflows])),
      capability_row("subagents", list_value(definition, [:subagent_names, :subagents])),
      capability_row("handoffs", list_value(definition, [:handoff_names, :handoffs])),
      capability_row("web", list_value(definition, [:web_tool_names, :web])),
      scalar_capability_row("ash", Map.get(definition, :ash_domain) || Map.get(definition, :ash)),
      capability_row("mcp", list_value(definition, [:mcp_tool_names, :mcp_tools, :mcp]))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp capability_row(surface, names) when is_list(names) do
    %{surface: surface, count: length(names), names: Render.format_list(names)}
  end

  defp scalar_capability_row(_surface, nil), do: nil

  defp scalar_capability_row(surface, value) do
    %{surface: surface, count: 1, names: Render.inspect_value(value)}
  end

  defp lifecycle_rows(definition) when is_map(definition) do
    [
      %{surface: "compaction", summary: Render.inspect_value(Map.get(definition, :compaction))},
      %{surface: "memory", summary: Render.inspect_value(Map.get(definition, :memory))},
      %{surface: "result", summary: Render.inspect_value(Map.get(definition, :result))},
      %{surface: "hooks", summary: Render.inspect_value(Map.get(definition, :hooks, %{}))},
      %{surface: "guardrails", summary: Render.inspect_value(Map.get(definition, :guardrails, %{}))}
    ]
  end

  defp request_rows(request) when is_map(request) do
    [
      %{property: "request id", value: Map.get(request, :request_id)},
      %{property: "status", value: Map.get(request, :status)},
      %{property: "model", value: Render.inspect_value(Map.get(request, :model))},
      %{property: "input", value: text_preview(Map.get(request, :input_message))},
      %{property: "user message", value: text_preview(Map.get(request, :user_message))},
      %{property: "tools", value: Render.format_list(Map.get(request, :tool_names, []))},
      %{property: "mcp tools", value: Render.format_list(Map.get(request, :mcp_tools, []))},
      %{property: "context", value: Render.format_list(Map.get(request, :context_preview, []))},
      %{property: "memory", value: Render.inspect_value(Map.get(request, :memory))},
      %{property: "subagents", value: length(Map.get(request, :subagents, []))},
      %{property: "workflows", value: length(Map.get(request, :workflows, []))},
      %{property: "handoffs", value: length(Map.get(request, :handoffs, []))},
      %{property: "interrupt", value: Render.inspect_value(Map.get(request, :interrupt))},
      %{property: "error", value: request_error_preview(Map.get(request, :error))},
      %{property: "usage", value: Render.inspect_value(Map.get(request, :usage))},
      %{property: "duration ms", value: Map.get(request, :duration_ms)},
      %{property: "messages", value: Map.get(request, :message_count)}
    ]
    |> Render.reject_blank_rows()
  end

  defp prompt_preview_rows(request) when is_map(request) do
    preview = Map.get(request, :prompt_preview) || %{}

    [
      %{
        surface: "system prompt",
        preview: Map.get(preview, :system_prompt) || text_preview(Map.get(request, :system_prompt))
      },
      %{
        surface: "user message",
        preview: Map.get(preview, :user_message) || text_preview(Map.get(request, :user_message))
      },
      %{surface: "message count", preview: Map.get(preview, :message_count)},
      %{surface: "tools offered", preview: Render.format_list(Map.get(preview, :tool_names, []))}
    ]
    |> Enum.reject(fn row -> Render.blank?(Map.get(row, :preview)) end)
  end

  defp request_call_rows(request) when is_map(request) do
    [
      request_call_row("subagents", Map.get(request, :subagents, [])),
      request_call_row("workflows", Map.get(request, :workflows, [])),
      request_call_row("handoffs", Map.get(request, :handoffs, [])),
      request_call_row("memory", Map.get(request, :memory)),
      request_call_row("compaction", Map.get(request, :compaction))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp request_call_row(_surface, []), do: nil
  defp request_call_row(_surface, nil), do: nil

  defp request_call_row(surface, calls) when is_list(calls) do
    %{surface: surface, count: length(calls), summary: Render.inspect_value(calls, 8)}
  end

  defp request_call_row(surface, %{} = summary) do
    %{surface: surface, count: 1, summary: Render.inspect_value(summary, 8)}
  end

  defp render_optional_table(_title, [], _keys), do: :ok

  defp render_optional_table(title, rows, keys) do
    Render.table(title, rows, keys: keys)
  end

  defp text_preview(nil), do: nil
  defp text_preview(text) when is_binary(text), do: Jidoka.Sanitize.preview(text, 240)
  defp text_preview(value), do: Jidoka.Sanitize.preview(value, 240)

  defp request_error_preview(nil), do: nil
  defp request_error_preview(error), do: error |> Jidoka.Error.to_map() |> Render.inspect_value(10)

  defp inspection_definition(value) when is_map(value) do
    cond do
      Map.get(value, :kind) == :running_agent and is_map(Map.get(value, :definition)) ->
        Map.get(value, :definition)

      is_map(Map.get(value, :definition)) ->
        Map.get(value, :definition)

      true ->
        value
    end
  end

  defp build_agent_diagram(inspection, opts) do
    definition = inspection_definition(inspection)
    agent_label = Map.get(inspection, :name) || Map.get(definition, :name) || Map.get(definition, :id) || "agent"
    model = Map.get(definition, :model) || Map.get(definition, :configured_model) || "model"
    context_keys = definition |> Map.get(:context, %{}) |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    lifecycle = lifecycle_labels(definition)

    capability_nodes =
      [
        {:Tools, "tools", list_value(definition, [:tool_names])},
        {:Workflows, "workflows", list_value(definition, [:workflow_names, :workflows])},
        {:Subagents, "subagents", list_value(definition, [:subagent_names, :subagents])},
        {:Handoffs, "handoffs", list_value(definition, [:handoff_names, :handoffs])},
        {:Web, "web", list_value(definition, [:web_tool_names, :web])},
        {:MCP, "mcp", list_value(definition, [:mcp_tool_names, :mcp_tools, :mcp])}
      ]
      |> Enum.reject(fn {_id, _label, names} -> names == [] end)

    direction = Keyword.get(opts, :direction, "LR")

    nodes = [
      "flowchart #{direction}",
      "  Agent[\"#{Render.mermaid_label(["Agent", agent_label])}\"]",
      "  Model[\"#{Render.mermaid_label(["Model", Render.inspect_value(model, 10)])}\"]",
      "  Context[\"#{Render.mermaid_label(["Context", Render.format_list(context_keys)])}\"]",
      "  Lifecycle[\"#{Render.mermaid_label(["Lifecycle", Render.format_list(lifecycle)])}\"]",
      "  Model --> Agent",
      "  Context --> Agent",
      "  Lifecycle -.-> Agent"
    ]

    capability_lines =
      Enum.flat_map(capability_nodes, fn {node_id, label, names} ->
        [
          "  #{node_id}[\"#{Render.mermaid_label([String.capitalize(label), Render.format_list(names)])}\"]",
          "  Agent --> #{node_id}"
        ]
      end)

    ["```mermaid", Enum.join(nodes ++ capability_lines, "\n"), "```"]
    |> Enum.join("\n")
  end

  defp lifecycle_labels(definition) do
    [
      if_present(Map.get(definition, :compaction), "compaction"),
      if_present(Map.get(definition, :memory), "memory"),
      if_present(Map.get(definition, :result), "result"),
      if_present(Map.get(definition, :hooks), "hooks"),
      if_present(Map.get(definition, :guardrails), "guardrails")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp if_present(nil, _label), do: nil
  defp if_present(%{} = value, _label) when map_size(value) == 0, do: nil
  defp if_present([], _label), do: nil
  defp if_present(_value, label), do: label

  defp list_value(definition, keys) do
    Enum.find_value(keys, [], fn key ->
      definition
      |> Map.get(key)
      |> normalize_names()
      |> case do
        [] -> nil
        names -> names
      end
    end)
  end

  defp normalize_names(nil), do: []

  defp normalize_names(names) when is_list(names),
    do: names |> Enum.map(&normalize_name/1) |> Enum.reject(&Render.blank?/1)

  defp normalize_names(%{} = map), do: map |> Map.keys() |> Enum.map(&normalize_name/1) |> Enum.reject(&Render.blank?/1)
  defp normalize_names(value), do: [normalize_name(value)] |> Enum.reject(&Render.blank?/1)

  defp normalize_name(value) when is_binary(value), do: value
  defp normalize_name(value) when is_atom(value), do: value |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  defp normalize_name(%{name: name}), do: normalize_name(name)
  defp normalize_name(%{"name" => name}), do: normalize_name(name)
  defp normalize_name(value), do: Render.inspect_value(value, 8)
end
