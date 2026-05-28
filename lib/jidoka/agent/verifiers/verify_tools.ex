defmodule Jidoka.Agent.Verifiers.VerifyTools do
  @moduledoc false

  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    Spark.Dsl.Verifier.get_entities(dsl_state, [:tools])
    |> Enum.reduce_while({:ok, MapSet.new()}, fn
      %Jidoka.Agent.Dsl.Tool{} = tool_ref, {:ok, seen_names} ->
        module = tool_ref.module

        case Jidoka.Action.Adapter.tool_name(module) do
          {:ok, name} ->
            if MapSet.member?(seen_names, name) do
              {:halt, {:error, duplicate_tool_error(dsl_state, tool_ref, name)}}
            else
              {:cont, {:ok, MapSet.put(seen_names, name)}}
            end

          {:error, message} ->
            {:halt, {:error, tool_error(dsl_state, tool_ref, message)}}
        end

      %Jidoka.Agent.Dsl.MCPTools{} = mcp_ref, {:ok, seen_names} ->
        case Jidoka.MCP.validate_dsl_entry(mcp_ref) do
          :ok ->
            {:cont, {:ok, seen_names}}

          {:error, message} ->
            {:halt, {:error, mcp_error(dsl_state, mcp_ref, message)}}
        end

      _other, {:ok, seen_names} ->
        {:cont, {:ok, seen_names}}
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp duplicate_tool_error(dsl_state, tool_ref, name) do
    Spark.Error.DslError.exception(
      message: "tool #{inspect(name)} is defined more than once",
      path: [:tools, :action],
      module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
      location: Spark.Dsl.Entity.anno(tool_ref)
    )
  end

  defp tool_error(dsl_state, tool_ref, message) do
    Spark.Error.DslError.exception(
      message: message,
      path: [:tools, :action],
      module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
      location: Spark.Dsl.Entity.anno(tool_ref)
    )
  end

  defp mcp_error(dsl_state, mcp_ref, message) do
    Spark.Error.DslError.exception(
      message: message,
      path: [:tools, :mcp_tools],
      module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
      location: Spark.Dsl.Entity.anno(mcp_ref)
    )
  end
end
