defmodule JidokaShowcase.LuaToolsAgent.Controls.RequireLuaExecution do
  @moduledoc false

  use Jidoka.Control, name: "require_lua_execution"

  @impl true
  def call(%{boundary: :output, agent_state: %{operation_results: operation_results}})
      when is_list(operation_results) do
    latest_execution =
      operation_results
      |> Enum.filter(&(&1.operation == "catalog_execute"))
      |> List.last()

    case latest_execution do
      nil ->
        {:block, :missing_catalog_execute}

      execution ->
        if completed?(execution) do
          :cont
        else
          %{output: output} = execution
          {:block, {:lua_execution_not_completed, status(output), reason(output)}}
        end
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
