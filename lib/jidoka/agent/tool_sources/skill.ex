defmodule Jidoka.Agent.ToolSources.Skill do
  @moduledoc false

  alias Jidoka.Adapter.Jido.Skill.{Resolution, ResolvedSkill}
  alias Jidoka.Agent.Dsl.{SkillPath, SkillRef}
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Agent.ToolSources.Common
  alias Jidoka.Operation.Source.JidoAction

  @spec resolve!([SkillRef.t()], [String.t()]) :: Resolution.t()
  def resolve!(skill_refs, load_paths) when is_list(skill_refs) and is_list(load_paths) do
    refs = Enum.map(skill_refs, & &1.skill)

    case Jidoka.Skill.resolve(refs, load_paths: load_paths) do
      {:ok, resolution} -> resolution
      {:error, reason} -> raise ArgumentError, "invalid skill resolution: #{inspect(reason)}"
    end
  end

  @spec action_modules(ResolvedSkill.t()) :: [module()]
  def action_modules(%ResolvedSkill{action_modules: action_modules}), do: action_modules

  @spec source!(ResolvedSkill.t()) :: JidoAction.t()
  def source!(%ResolvedSkill{} = skill) do
    JidoAction.new!(action_modules(skill), operations!(skill), metadata: [skill.metadata])
  end

  @spec operations!(ResolvedSkill.t()) :: [Jidoka.Agent.Spec.Operation.t()]
  def operations!(%ResolvedSkill{} = skill) do
    skill
    |> action_modules()
    |> Enum.map(&Common.operation_from_action!/1)
    |> Enum.map(&tag_operation(&1, skill.spec.name))
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

  @spec prompt(Resolution.t()) :: String.t() | nil
  def prompt(%Resolution{prompt: prompt}), do: prompt

  defp tag_operation(%Operation{} = operation, skill_name) do
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
end
