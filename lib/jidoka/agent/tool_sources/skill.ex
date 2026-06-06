defmodule Jidoka.Agent.ToolSources.Skill do
  @moduledoc false

  alias Jidoka.Agent.Dsl.{SkillPath, SkillRef}
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Agent.ToolSources.Common

  @spec action_modules(term()) :: [module()]
  def action_modules(%SkillRef{skill: skill}), do: Jidoka.Skill.action_modules([skill])

  @spec operations!(term()) :: [Jidoka.Agent.Spec.Operation.t()]
  def operations!(%SkillRef{skill: skill}) do
    [skill]
    |> Jidoka.Skill.action_modules()
    |> Enum.map(&Common.operation_from_action!/1)
    |> Enum.map(&tag_operation(&1, skill))
  end

  @spec metadata!(term(), [String.t()]) :: [map()]
  def metadata!(%SkillRef{skill: skill}, load_paths) do
    case Jidoka.Skill.metadata([skill], load_paths: load_paths) do
      {:ok, metadata} -> metadata
      {:error, reason} -> raise ArgumentError, "invalid skill metadata: #{inspect(reason)}"
    end
  end

  @spec load_path_metadata!(term(), Path.t()) :: [map()]
  def load_path_metadata!(%SkillPath{} = skill_path, base_dir) do
    [
      %{
        "source" => "skill_path",
        "path" => skill_path.path,
        "expanded_path" => Path.expand(skill_path.path, base_dir)
      }
    ]
  end

  @spec prompt!([term()], [String.t()]) :: String.t() | nil
  def prompt!(skill_refs, load_paths) do
    skills = Enum.map(skill_refs, & &1.skill)

    case Jidoka.Skill.prompt(skills, load_paths: load_paths) do
      {:ok, prompt} -> prompt
      {:error, reason} -> raise ArgumentError, "invalid skill prompt: #{inspect(reason)}"
    end
  end

  defp tag_operation(%Operation{} = operation, skill) do
    skill_name = skill_name(skill)

    %Operation{
      operation
      | metadata:
          operation.metadata
          |> Map.merge(%{
            "source" => "skill",
            "kind" => "skill",
            "skill" => skill_name,
            "action" => operation.name
          })
    }
  end

  defp skill_name(skill) when is_atom(skill) do
    skill
    |> Jido.AI.Skill.manifest()
    |> Map.get(:name)
  rescue
    _exception -> inspect(skill)
  end

  defp skill_name(skill) when is_binary(skill), do: String.trim(skill)
end
