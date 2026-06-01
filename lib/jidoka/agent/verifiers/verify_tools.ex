defmodule Jidoka.Agent.Verifiers.VerifyTools do
  @moduledoc false

  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Spark.Dsl.Verifier.get_entities([:tools])
    |> Enum.reduce_while({:ok, MapSet.new()}, &verify_tool_source(&1, &2, module))
    |> case do
      {:ok, _seen_names} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp verify_tool_source(%Jidoka.Agent.Dsl.Tool{} = tool_ref, {:ok, seen_names}, module) do
    case tool_name(tool_ref.module) do
      {:ok, tool_name} -> verify_unique_tool_name(tool_ref, tool_name, seen_names, module)
      {:error, message} -> {:halt, {:error, dsl_error(message, module, [:tools, :action], tool_ref)}}
    end
  end

  defp verify_tool_source(%Jidoka.Agent.Dsl.SkillRef{} = skill_ref, {:ok, seen_names}, module) do
    case Jidoka.Skill.validate_ref(skill_ref.skill) do
      :ok -> {:cont, {:ok, seen_names}}
      {:error, message} -> {:halt, {:error, dsl_error(message, module, [:tools, :skill], skill_ref)}}
    end
  end

  defp verify_tool_source(%Jidoka.Agent.Dsl.SkillPath{} = skill_path, {:ok, seen_names}, module) do
    case Jidoka.Skill.validate_load_path(skill_path.path) do
      :ok -> {:cont, {:ok, seen_names}}
      {:error, message} -> {:halt, {:error, dsl_error(message, module, [:tools, :load_path], skill_path)}}
    end
  end

  defp verify_tool_source(_tool_source, {:ok, seen_names}, _module), do: {:cont, {:ok, seen_names}}

  defp verify_unique_tool_name(tool_ref, tool_name, seen_names, module) do
    if MapSet.member?(seen_names, tool_name) do
      {:halt,
       {:error, dsl_error("tool #{inspect(tool_name)} is defined more than once", module, [:tools, :action], tool_ref)}}
    else
      {:cont, {:ok, MapSet.put(seen_names, tool_name)}}
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
