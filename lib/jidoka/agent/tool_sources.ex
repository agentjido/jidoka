defmodule Jidoka.Agent.ToolSources do
  @moduledoc false

  alias Jidoka.Agent.Dsl.{
    AshResource,
    Browser,
    Catalog,
    Handoff,
    MCPTools,
    SkillPath,
    SkillRef,
    Subagent,
    Tool,
    Workflow
  }

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Agent.ToolSources
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Defined

  @spec entities(module()) :: [struct()]
  def entities(agent_module) when is_atom(agent_module) do
    Spark.Dsl.Extension.get_entities(agent_module, [:tools])
  end

  @spec action_modules(module()) :: [module()]
  def action_modules(agent_module) when is_atom(agent_module) do
    agent_module
    |> entities()
    |> Enum.flat_map(&action_modules_from_entity/1)
  end

  @spec skill_prompt!(module()) :: String.t() | nil
  def skill_prompt!(agent_module) when is_atom(agent_module) do
    wrap!(agent_module, [:tools, :skill], fn ->
      ToolSources.Skill.prompt!(skill_refs(agent_module), skill_load_paths(agent_module))
    end)
  end

  @spec operation_capability(module(), keyword()) ::
          Jidoka.Operation.Capability.t()
  def operation_capability(agent_module, opts \\ []) when is_atom(agent_module) do
    agent_module
    |> compiled!(opts)
    |> Map.fetch!(:capability)
  end

  @spec operations!(module()) :: [Operation.t()]
  def operations!(agent_module) when is_atom(agent_module) do
    agent_module
    |> compiled!([])
    |> Map.fetch!(:operations)
  end

  @spec source_metadata!(module()) :: [map()]
  def source_metadata!(agent_module) when is_atom(agent_module) do
    compiled_metadata = agent_module |> compiled!([]) |> Map.fetch!(:metadata)

    load_path_metadata =
      agent_module
      |> entities()
      |> Enum.flat_map(fn
        %SkillPath{} = skill_path ->
          wrap!(agent_module, [:tools, :load_path], fn ->
            ToolSources.Skill.load_path_metadata!(skill_path, agent_base_dir(agent_module))
          end)

        _entity ->
          []
      end)

    compiled_metadata ++ load_path_metadata
  end

  @spec validate!(module()) :: :ok
  def validate!(agent_module) when is_atom(agent_module) do
    _compiled = compiled!(agent_module, [])
    :ok
  end

  defp action_modules_from_entity(%Tool{} = tool), do: ToolSources.Action.action_modules(tool)

  defp action_modules_from_entity(%AshResource{} = ash_resource),
    do: ToolSources.AshResource.action_modules(ash_resource)

  defp action_modules_from_entity(%Browser{} = browser), do: ToolSources.Browser.action_modules(browser)
  defp action_modules_from_entity(%SkillRef{} = skill_ref), do: ToolSources.Skill.action_modules(skill_ref)
  defp action_modules_from_entity(_entity), do: []

  defp operation_sources!(agent_module) do
    agent_module
    |> entities()
    |> Enum.flat_map(fn
      %Tool{} = tool ->
        [wrap!(agent_module, [:tools, :action], fn -> ToolSources.Action.source!(tool) end)]

      %AshResource{} = ash_resource ->
        [
          wrap!(agent_module, [:tools, :ash_resource], fn ->
            ToolSources.AshResource.source!(ash_resource)
          end)
        ]

      %Browser{} = browser ->
        [wrap!(agent_module, [:tools, :browser], fn -> ToolSources.Browser.source!(browser) end)]

      %MCPTools{} = mcp_tools ->
        [
          wrap!(agent_module, [:tools, :mcp_tools], fn ->
            Defined.new!(
              ToolSources.MCP.source!(mcp_tools),
              ToolSources.MCP.operations!(mcp_tools),
              ToolSources.MCP.metadata!(mcp_tools)
            )
          end)
        ]

      %Catalog{} = catalog ->
        [
          wrap!(agent_module, [:tools, :catalog], fn ->
            Defined.new!(
              ToolSources.Catalog.source!(catalog),
              ToolSources.Catalog.operations!(catalog),
              ToolSources.Catalog.metadata!(catalog)
            )
          end)
        ]

      %Subagent{} = subagent ->
        [
          wrap!(agent_module, [:tools, :subagent], fn ->
            Defined.new!(
              ToolSources.Subagent.source!(subagent),
              ToolSources.Subagent.operations!(subagent),
              ToolSources.Subagent.metadata!(subagent)
            )
          end)
        ]

      %Handoff{} = handoff ->
        [
          wrap!(agent_module, [:tools, :handoff], fn ->
            Defined.new!(
              ToolSources.Handoff.source!(handoff),
              ToolSources.Handoff.operations!(handoff),
              ToolSources.Handoff.metadata!(handoff)
            )
          end)
        ]

      %Workflow{} = workflow ->
        [
          wrap!(agent_module, [:tools, :workflow], fn ->
            Defined.new!(
              ToolSources.Workflow.source!(workflow),
              ToolSources.Workflow.operations!(workflow),
              ToolSources.Workflow.metadata!(workflow)
            )
          end)
        ]

      %SkillRef{} = skill_ref ->
        [
          wrap!(agent_module, [:tools, :skill], fn ->
            ToolSources.Skill.source!(skill_ref, skill_load_paths(agent_module))
          end)
        ]

      _entity ->
        []
    end)
  end

  defp compiled!(agent_module, opts) do
    case Source.compile(operation_sources!(agent_module), opts) do
      {:ok, compiled} ->
        compiled

      {:error, {:duplicate_operation_source_name, name}} ->
        raise Spark.Error.DslError,
          message: "tool #{inspect(name)} is defined more than once",
          path: [:tools],
          module: agent_module

      {:error, reason} ->
        raise Spark.Error.DslError,
          message: "could not compile operation sources: #{inspect(reason)}",
          path: [:tools],
          module: agent_module
    end
  end

  defp skill_refs(agent_module) do
    agent_module
    |> entities()
    |> Enum.flat_map(fn
      %SkillRef{} = skill_ref -> [skill_ref]
      _entity -> []
    end)
  end

  defp skill_load_paths(agent_module) do
    load_paths =
      agent_module
      |> entities()
      |> Enum.flat_map(fn
        %SkillPath{path: path} -> [path]
        _entity -> []
      end)

    Jidoka.Skill.normalize_load_paths(load_paths, agent_base_dir(agent_module))
  end

  defp wrap!(agent_module, path, fun) when is_function(fun, 0) do
    fun.()
  rescue
    error in [Spark.Error.DslError] ->
      reraise error, __STACKTRACE__

    exception ->
      reraise Spark.Error.DslError.exception(
                message: Exception.message(exception),
                path: path,
                module: agent_module
              ),
              __STACKTRACE__
  end

  defp agent_base_dir(agent_module) do
    source =
      agent_module.module_info(:compile)
      |> Keyword.get(:source)

    source
    |> List.to_string()
    |> Path.dirname()
  rescue
    _exception -> File.cwd!()
  end
end
