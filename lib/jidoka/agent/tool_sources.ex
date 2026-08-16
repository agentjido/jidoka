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
  alias Jidoka.Operation.Source.JidoAction

  @spec entities(module()) :: [struct()]
  def entities(agent_module) when is_atom(agent_module) do
    Spark.Dsl.Extension.get_entities(agent_module, [:tools])
  end

  @spec action_modules(module()) :: [module()]
  def action_modules(agent_module) when is_atom(agent_module) do
    agent_module
    |> compile!()
    |> Map.fetch!(:actions)
  end

  @spec skill_prompt!(module()) :: String.t() | nil
  def skill_prompt!(agent_module) when is_atom(agent_module) do
    agent_module
    |> compile!()
    |> Map.fetch!(:skill_prompt)
  end

  @spec operation_capability(module(), keyword()) ::
          Jidoka.Operation.Capability.t()
  def operation_capability(agent_module, opts \\ []) when is_atom(agent_module) do
    agent_module
    |> compile!(opts)
    |> Map.fetch!(:capability)
  end

  @spec operations!(module()) :: [Operation.t()]
  def operations!(agent_module) when is_atom(agent_module) do
    agent_module
    |> compile!()
    |> Map.fetch!(:operations)
  end

  @spec source_metadata!(module()) :: [map()]
  def source_metadata!(agent_module) when is_atom(agent_module) do
    agent_module
    |> compile!()
    |> Map.fetch!(:metadata)
  end

  @spec validate!(module()) :: :ok
  def validate!(agent_module) when is_atom(agent_module) do
    _compiled = compile!(agent_module)
    :ok
  end

  @spec compile!(module(), keyword()) :: map()
  def compile!(agent_module, opts \\ []) when is_atom(agent_module) and is_list(opts) do
    entities = entities(agent_module)
    load_paths = skill_load_paths(agent_module, entities)

    skill_resolution =
      wrap!(agent_module, [:tools, :skill], fn ->
        ToolSources.Skill.resolve!(skill_refs(entities), load_paths)
      end)

    sources = operation_sources!(agent_module, entities, skill_resolution.skills)

    case Source.compile(sources, opts) do
      {:ok, compiled} ->
        Map.merge(compiled, %{
          actions: action_modules_from_sources(sources),
          skill_prompt: ToolSources.Skill.prompt(skill_resolution),
          metadata: compiled.metadata ++ load_path_metadata!(agent_module, entities)
        })

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

  defp operation_sources!(agent_module, entities, resolved_skills) do
    {source_groups, remaining_skills} =
      Enum.map_reduce(entities, resolved_skills, fn
        %Tool{} = tool, skills ->
          {[wrap!(agent_module, [:tools, :action], fn -> ToolSources.Action.source!(tool) end)], skills}

        %AshResource{} = ash_resource, skills ->
          {[
             wrap!(agent_module, [:tools, :ash_resource], fn ->
               ToolSources.AshResource.source!(ash_resource)
             end)
           ], skills}

        %Browser{} = browser, skills ->
          {[wrap!(agent_module, [:tools, :browser], fn -> ToolSources.Browser.source!(browser) end)], skills}

        %MCPTools{} = mcp_tools, skills ->
          {[
             wrap!(agent_module, [:tools, :mcp_tools], fn ->
               ToolSources.MCP.compiled!(mcp_tools)
             end)
           ], skills}

        %Catalog{} = catalog, skills ->
          {[
             wrap!(agent_module, [:tools, :catalog], fn ->
               ToolSources.Catalog.compiled!(catalog)
             end)
           ], skills}

        %Subagent{} = subagent, skills ->
          {[
             wrap!(agent_module, [:tools, :subagent], fn ->
               ToolSources.Subagent.compiled!(subagent)
             end)
           ], skills}

        %Handoff{} = handoff, skills ->
          {[
             wrap!(agent_module, [:tools, :handoff], fn ->
               ToolSources.Handoff.compiled!(handoff)
             end)
           ], skills}

        %Workflow{} = workflow, skills ->
          {[
             wrap!(agent_module, [:tools, :workflow], fn ->
               ToolSources.Workflow.compiled!(workflow)
             end)
           ], skills}

        %SkillRef{skill: skill}, [%{source: skill} = resolved_skill | rest] ->
          {[
             wrap!(agent_module, [:tools, :skill], fn ->
               ToolSources.Skill.source!(resolved_skill)
             end)
           ], rest}

        _entity, skills ->
          {[], skills}
      end)

    case remaining_skills do
      [] -> List.flatten(source_groups)
      skills -> raise ArgumentError, "unused skill resolutions: #{inspect(skills)}"
    end
  end

  defp skill_refs(entities) do
    entities
    |> Enum.flat_map(fn
      %SkillRef{} = skill_ref -> [skill_ref]
      _entity -> []
    end)
  end

  defp skill_load_paths(agent_module, entities) do
    load_paths =
      entities
      |> Enum.flat_map(fn
        %SkillPath{path: path} -> [path]
        _entity -> []
      end)

    Jidoka.Skill.normalize_load_paths(load_paths, agent_base_dir(agent_module))
  end

  defp action_modules_from_sources(sources) do
    Enum.flat_map(sources, fn
      %JidoAction{actions: actions} -> actions
      _source -> []
    end)
  end

  defp load_path_metadata!(agent_module, entities) do
    Enum.flat_map(entities, fn
      %SkillPath{} = skill_path ->
        wrap!(agent_module, [:tools, :load_path], fn ->
          ToolSources.Skill.load_path_metadata!(skill_path, agent_base_dir(agent_module))
        end)

      _entity ->
        []
    end)
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
