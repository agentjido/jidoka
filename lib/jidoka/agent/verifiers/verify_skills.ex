defmodule Jidoka.Agent.Verifiers.VerifySkills do
  @moduledoc false

  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    Spark.Dsl.Verifier.get_entities(dsl_state, [:tools])
    |> Enum.reduce_while({:ok, MapSet.new()}, fn
      %Jidoka.Agent.Dsl.SkillRef{skill: skill} = entry, {:ok, seen} ->
        with :ok <- Jidoka.Skill.validate_skill_ref(skill),
             :ok <- ensure_unique_skill(skill, seen) do
          {:cont, {:ok, MapSet.put(seen, skill_identity(skill))}}
        else
          {:error, reason} ->
            {:halt, {:error, skill_error(dsl_state, entry, :skill, reason)}}
        end

      %Jidoka.Agent.Dsl.SkillPath{path: path} = entry, {:ok, seen} ->
        with :ok <- Jidoka.Skill.validate_load_path(path) do
          {:cont, {:ok, MapSet.put(seen, {:path, path})}}
        else
          {:error, reason} ->
            {:halt, {:error, skill_error(dsl_state, entry, :load_path, reason)}}
        end

      _other, {:ok, seen} ->
        {:cont, {:ok, seen}}
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp ensure_unique_skill(skill, seen) do
    identity = skill_identity(skill)

    if MapSet.member?(seen, identity) do
      {:error, "skill #{inspect(skill)} is defined more than once"}
    else
      :ok
    end
  end

  defp skill_identity(module) when is_atom(module), do: {:module, module}
  defp skill_identity(name) when is_binary(name), do: {:name, String.trim(name)}

  defp skill_error(dsl_state, entry, path_name, message) do
    Spark.Error.DslError.exception(
      message: message,
      path: [:tools, path_name],
      module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
      location: Spark.Dsl.Entity.anno(entry)
    )
  end
end
