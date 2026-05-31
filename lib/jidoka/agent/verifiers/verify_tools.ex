defmodule Jidoka.Agent.Verifiers.VerifyTools do
  @moduledoc false

  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Spark.Dsl.Verifier.get_entities([:tools])
    |> Enum.reduce_while({:ok, MapSet.new()}, fn
      %Jidoka.Agent.Dsl.Tool{} = tool_ref, {:ok, seen_names} ->
        with {:ok, tool_name} <- tool_name(tool_ref.module) do
          if MapSet.member?(seen_names, tool_name) do
            {:halt,
             {:error,
              dsl_error(
                "tool #{inspect(tool_name)} is defined more than once",
                module,
                [:tools, :action],
                tool_ref
              )}}
          else
            {:cont, {:ok, MapSet.put(seen_names, tool_name)}}
          end
        else
          {:error, message} ->
            {:halt, {:error, dsl_error(message, module, [:tools, :action], tool_ref)}}
        end

      _tool_source, {:ok, seen_names} ->
        {:cont, {:ok, seen_names}}
    end)
    |> case do
      {:ok, _seen_names} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp tool_name(action) when is_atom(action) do
    with {:module, _module} <- Code.ensure_compiled(action),
         true <- function_exported?(action, :to_tool, 0) do
      tool = action.to_tool()
      {:ok, tool.name}
    else
      {:error, reason} ->
        {:error, "could not compile action #{inspect(action)}: #{inspect(reason)}"}

      false ->
        {:error, "#{inspect(action)} must expose `to_tool/0`"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp dsl_error(message, module, path, entity) do
    Spark.Error.DslError.exception(
      message: message,
      path: path,
      module: module,
      location: Spark.Dsl.Entity.anno(entity)
    )
  end
end
