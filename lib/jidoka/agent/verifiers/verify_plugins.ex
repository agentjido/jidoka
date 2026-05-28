defmodule Jidoka.Agent.Verifiers.VerifyPlugins do
  @moduledoc false

  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    Spark.Dsl.Verifier.get_entities(dsl_state, [:tools])
    |> Enum.filter(&match?(%Jidoka.Agent.Dsl.Plugin{}, &1))
    |> Enum.reduce_while({:ok, MapSet.new()}, fn plugin_ref, {:ok, seen_names} ->
      module = plugin_ref.module

      case Jidoka.Plugin.plugin_name(module) do
        {:ok, name} ->
          if MapSet.member?(seen_names, name) do
            {:halt, {:error, duplicate_plugin_error(dsl_state, plugin_ref, name)}}
          else
            {:cont, {:ok, MapSet.put(seen_names, name)}}
          end

        {:error, message} ->
          {:halt, {:error, plugin_error(dsl_state, plugin_ref, message)}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp duplicate_plugin_error(dsl_state, plugin_ref, name) do
    Spark.Error.DslError.exception(
      message: "plugin #{inspect(name)} is defined more than once",
      path: [:tools, :plugin],
      module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
      location: Spark.Dsl.Entity.anno(plugin_ref)
    )
  end

  defp plugin_error(dsl_state, plugin_ref, message) do
    Spark.Error.DslError.exception(
      message: message,
      path: [:tools, :plugin],
      module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
      location: Spark.Dsl.Entity.anno(plugin_ref)
    )
  end
end
