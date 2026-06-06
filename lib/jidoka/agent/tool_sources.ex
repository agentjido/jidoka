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
          Jidoka.Runtime.Capabilities.operation_capability()
  def operation_capability(agent_module, opts \\ []) when is_atom(agent_module) do
    context = Keyword.get(opts, :context, %{})
    action_capability = Jidoka.Runtime.JidoActions.operations(action_modules(agent_module), context: context)
    source_capability = source_capability(agent_module, context)

    fn intent, journal ->
      case action_capability.(intent, journal) do
        {:error, {:missing_jido_action, _name}} -> source_capability.(intent, journal)
        result -> result
      end
      |> normalize_missing_action_error()
    end
  end

  @spec operations!(module()) :: [Operation.t()]
  def operations!(agent_module) when is_atom(agent_module) do
    operations =
      agent_module
      |> entities()
      |> Enum.flat_map(&operations_from_entity!(agent_module, &1))

    validate_unique_operations!(agent_module, operations)
    operations
  end

  @spec source_metadata!(module()) :: [map()]
  def source_metadata!(agent_module) when is_atom(agent_module) do
    agent_module
    |> entities()
    |> Enum.flat_map(&source_metadata_from_entity!(agent_module, &1))
  end

  @spec validate!(module()) :: :ok
  def validate!(agent_module) when is_atom(agent_module) do
    _operations = operations!(agent_module)
    :ok
  end

  defp action_modules_from_entity(%Tool{} = tool), do: ToolSources.Action.action_modules(tool)

  defp action_modules_from_entity(%AshResource{} = ash_resource),
    do: ToolSources.AshResource.action_modules(ash_resource)

  defp action_modules_from_entity(%Browser{} = browser), do: ToolSources.Browser.action_modules(browser)
  defp action_modules_from_entity(%SkillRef{} = skill_ref), do: ToolSources.Skill.action_modules(skill_ref)
  defp action_modules_from_entity(_entity), do: []

  defp operations_from_entity!(agent_module, %Tool{} = tool) do
    wrap!(agent_module, [:tools, :action], fn -> ToolSources.Action.operations!(tool) end)
  end

  defp operations_from_entity!(agent_module, %AshResource{} = ash_resource) do
    wrap!(agent_module, [:tools, :ash_resource], fn -> ToolSources.AshResource.operations!(ash_resource) end)
  end

  defp operations_from_entity!(agent_module, %Browser{} = browser) do
    wrap!(agent_module, [:tools, :browser], fn -> ToolSources.Browser.operations!(browser) end)
  end

  defp operations_from_entity!(agent_module, %MCPTools{} = mcp_tools) do
    wrap!(agent_module, [:tools, :mcp_tools], fn -> ToolSources.MCP.operations!(mcp_tools) end)
  end

  defp operations_from_entity!(agent_module, %Catalog{} = catalog) do
    wrap!(agent_module, [:tools, :catalog], fn -> ToolSources.Catalog.operations!(catalog) end)
  end

  defp operations_from_entity!(agent_module, %Subagent{} = subagent) do
    wrap!(agent_module, [:tools, :subagent], fn -> ToolSources.Subagent.operations!(subagent) end)
  end

  defp operations_from_entity!(agent_module, %Handoff{} = handoff) do
    wrap!(agent_module, [:tools, :handoff], fn -> ToolSources.Handoff.operations!(handoff) end)
  end

  defp operations_from_entity!(agent_module, %Workflow{} = workflow) do
    wrap!(agent_module, [:tools, :workflow], fn -> ToolSources.Workflow.operations!(workflow) end)
  end

  defp operations_from_entity!(agent_module, %SkillRef{} = skill_ref) do
    wrap!(agent_module, [:tools, :skill], fn -> ToolSources.Skill.operations!(skill_ref) end)
  end

  defp operations_from_entity!(_agent_module, _entity), do: []

  defp source_metadata_from_entity!(agent_module, %AshResource{} = ash_resource) do
    wrap!(agent_module, [:tools, :ash_resource], fn -> ToolSources.AshResource.metadata!(ash_resource) end)
  end

  defp source_metadata_from_entity!(agent_module, %Browser{} = browser) do
    wrap!(agent_module, [:tools, :browser], fn -> ToolSources.Browser.metadata!(browser) end)
  end

  defp source_metadata_from_entity!(agent_module, %MCPTools{} = mcp_tools) do
    wrap!(agent_module, [:tools, :mcp_tools], fn -> ToolSources.MCP.metadata!(mcp_tools) end)
  end

  defp source_metadata_from_entity!(agent_module, %Catalog{} = catalog) do
    wrap!(agent_module, [:tools, :catalog], fn -> ToolSources.Catalog.metadata!(catalog) end)
  end

  defp source_metadata_from_entity!(agent_module, %Subagent{} = subagent) do
    wrap!(agent_module, [:tools, :subagent], fn -> ToolSources.Subagent.metadata!(subagent) end)
  end

  defp source_metadata_from_entity!(agent_module, %Handoff{} = handoff) do
    wrap!(agent_module, [:tools, :handoff], fn -> ToolSources.Handoff.metadata!(handoff) end)
  end

  defp source_metadata_from_entity!(agent_module, %Workflow{} = workflow) do
    wrap!(agent_module, [:tools, :workflow], fn -> ToolSources.Workflow.metadata!(workflow) end)
  end

  defp source_metadata_from_entity!(agent_module, %SkillRef{} = skill_ref) do
    wrap!(agent_module, [:tools, :skill], fn ->
      ToolSources.Skill.metadata!(skill_ref, skill_load_paths(agent_module))
    end)
  end

  defp source_metadata_from_entity!(agent_module, %SkillPath{} = skill_path) do
    wrap!(agent_module, [:tools, :load_path], fn ->
      ToolSources.Skill.load_path_metadata!(skill_path, agent_base_dir(agent_module))
    end)
  end

  defp source_metadata_from_entity!(_agent_module, _entity), do: []

  defp operation_sources!(agent_module) do
    agent_module
    |> entities()
    |> Enum.flat_map(fn
      %MCPTools{} = mcp_tools ->
        [wrap!(agent_module, [:tools, :mcp_tools], fn -> ToolSources.MCP.source!(mcp_tools) end)]

      %Catalog{} = catalog ->
        [wrap!(agent_module, [:tools, :catalog], fn -> ToolSources.Catalog.source!(catalog) end)]

      %Subagent{} = subagent ->
        [wrap!(agent_module, [:tools, :subagent], fn -> ToolSources.Subagent.source!(subagent) end)]

      %Handoff{} = handoff ->
        [wrap!(agent_module, [:tools, :handoff], fn -> ToolSources.Handoff.source!(handoff) end)]

      %Workflow{} = workflow ->
        [wrap!(agent_module, [:tools, :workflow], fn -> ToolSources.Workflow.source!(workflow) end)]

      _entity ->
        []
    end)
  end

  defp source_capability(agent_module, context) do
    case Source.compile(operation_sources!(agent_module), context: context) do
      {:ok, %{capability: capability}} ->
        capability

      {:error, reason} ->
        fn _intent, _journal -> {:error, reason} end
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

  defp normalize_missing_action_error({:error, {:missing_jido_action, name}}),
    do: {:error, {:missing_operation_handler, name}}

  defp normalize_missing_action_error(result), do: result

  defp validate_unique_operations!(agent_module, operations) do
    operations
    |> Enum.reduce_while(MapSet.new(), fn %Operation{name: name}, seen ->
      if MapSet.member?(seen, name) do
        {:halt, {:duplicate, name}}
      else
        {:cont, MapSet.put(seen, name)}
      end
    end)
    |> case do
      %MapSet{} ->
        :ok

      {:duplicate, name} ->
        raise Spark.Error.DslError.exception(
                message: "tool #{inspect(name)} is defined more than once",
                path: [:tools],
                module: agent_module
              )
    end
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
