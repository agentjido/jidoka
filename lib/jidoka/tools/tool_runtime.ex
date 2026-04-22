defmodule Jidoka.Tools.ToolRuntime do
  @moduledoc false

  alias Jidoka.Tools.{Context, Permission}

  @spec run(map(), module(), map(), Permission.requirement(), (-> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def run(context, tool_module, params, required_permission, fun)
      when is_map(context) and is_atom(tool_module) and is_map(params) and is_function(fun, 0) do
    tool_name = tool_module.name()
    permission_mode = Context.permission_mode(context)
    workspace_path = Context.workspace_path(context)

    metadata = %{
      tool: tool_name,
      params: params,
      permission_mode: permission_mode,
      required_permission: required_permission,
      workspace_path: workspace_path
    }

    :ok = safe_report(context, :tool_requested, "tool requested: #{tool_name}", metadata)

    case Permission.check(permission_mode, required_permission) do
      :ok ->
        :ok =
          safe_report(
            context,
            :tool_permission_granted,
            "tool permission granted: #{tool_name}",
            metadata
          )

        execute_tool(context, tool_name, metadata, fun)

      {:error, reason} ->
        :ok =
          safe_report(
            context,
            :tool_permission_denied,
            "tool permission denied: #{tool_name}",
            Map.put(metadata, :reason, reason)
          )

        {:error, reason}
    end
  end

  defp execute_tool(context, tool_name, metadata, fun) do
    start_ms = System.monotonic_time(:millisecond)
    :ok = safe_report(context, :tool_started, "tool started: #{tool_name}", metadata)

    case fun.() do
      {:ok, result} when is_map(result) ->
        duration_ms = System.monotonic_time(:millisecond) - start_ms

        :ok =
          safe_report(
            context,
            :tool_completed,
            "tool completed: #{tool_name}",
            Map.merge(metadata, %{
              duration_ms: duration_ms,
              result_summary: summarize_result(result)
            })
          )

        {:ok, result}

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start_ms

        :ok =
          safe_report(
            context,
            :tool_failed,
            "tool failed: #{tool_name}",
            Map.merge(metadata, %{duration_ms: duration_ms, reason: reason})
          )

        {:error, reason}
    end
  rescue
    error ->
      :ok =
        safe_report(
          context,
          :tool_failed,
          "tool failed: #{tool_name}",
          Map.merge(metadata, %{reason: Exception.message(error), exception: error.__struct__})
        )

      {:error, %{type: :tool_exception, message: Exception.message(error)}}
  end

  defp summarize_result(result) do
    result
    |> Enum.map(fn {key, value} -> {key, summarize_value(value)} end)
    |> Map.new()
  end

  defp summarize_value(value) when is_binary(value), do: %{type: :string, bytes: byte_size(value)}
  defp summarize_value(value) when is_list(value), do: %{type: :list, count: length(value)}
  defp summarize_value(value) when is_map(value), do: %{type: :map, keys: map_size(value)}
  defp summarize_value(value), do: value

  defp safe_report(context, label, message, metadata) do
    case Context.report_progress(context, label, message, metadata) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end
end
