defmodule JidokaExample.LuaToolsAgent.Controls.RequireLuaExecution do
  @moduledoc false

  use Jidoka.Control, name: "require_lua_execution"

  @impl true
  def call(%{boundary: :output, agent_state: %{operation_results: operation_results}})
      when is_list(operation_results) do
    executions = Enum.filter(operation_results, &(&1.operation == "lua_tools_execute"))

    cond do
      Enum.any?(executions, &completed?/1) ->
        :cont

      executions != [] ->
        %{output: output} = List.last(executions)
        {:block, {:lua_execution_not_completed, status(output), reason(output)}}

      true ->
        {:block, :missing_lua_tools_execute}
    end
  end

  def call(%{boundary: :output}), do: {:block, :missing_operation_results}

  def call(_context), do: :cont

  defp completed?(%{output: %{"status" => "completed"}}), do: true
  defp completed?(%{output: %{status: "completed"}}), do: true
  defp completed?(_result), do: false

  defp status(%{} = output), do: Map.get(output, "status", Map.get(output, :status))
  defp status(_output), do: nil

  defp reason(%{} = output), do: Map.get(output, "reason", Map.get(output, :reason))
  defp reason(_output), do: nil
end
