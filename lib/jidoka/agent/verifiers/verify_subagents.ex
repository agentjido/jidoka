defmodule Jidoka.Agent.Verifiers.VerifySubagents do
  @moduledoc false

  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    Spark.Dsl.Verifier.get_entities(dsl_state, [:tools])
    |> Enum.filter(&match?(%Jidoka.Agent.Dsl.Subagent{}, &1))
    |> Enum.reduce_while({:ok, MapSet.new()}, fn subagent_ref, {:ok, seen_names} ->
      with {:ok, subagent} <-
             Jidoka.Subagent.new(
               subagent_ref.agent,
               as: subagent_ref.as,
               description: subagent_ref.description,
               target: subagent_ref.target
             ) do
        if MapSet.member?(seen_names, subagent.name) do
          {:halt, {:error, duplicate_subagent_error(dsl_state, subagent_ref, subagent.name)}}
        else
          {:cont, {:ok, MapSet.put(seen_names, subagent.name)}}
        end
      else
        {:error, message} ->
          {:halt, {:error, subagent_error(dsl_state, subagent_ref, message)}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp duplicate_subagent_error(dsl_state, subagent_ref, name) do
    Spark.Error.DslError.exception(
      message: "subagent #{inspect(name)} is defined more than once",
      path: [:tools, :subagent],
      module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
      location: Spark.Dsl.Entity.anno(subagent_ref)
    )
  end

  defp subagent_error(dsl_state, subagent_ref, message) do
    Spark.Error.DslError.exception(
      message: message,
      path: [:tools, :subagent],
      module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
      location: Spark.Dsl.Entity.anno(subagent_ref)
    )
  end
end
