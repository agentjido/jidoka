defmodule Jidoka.Agent.Definition.Capabilities do
  @moduledoc false

  @spec resolve_handoffs!([struct()], module()) :: [Jidoka.Handoff.Capability.t()]
  def resolve_handoffs!(entities, owner_module) do
    handoffs =
      Enum.map(entities, fn entity ->
        case Jidoka.Handoff.Capability.new(entity.agent,
               as: entity.as,
               description: entity.description,
               target: entity.target,
               forward_context: entity.forward_context
             ) do
          {:ok, handoff} ->
            handoff

          {:error, message} ->
            raise Jidoka.Agent.Dsl.Error.exception(
                    message: message,
                    path: [:capabilities, :handoff],
                    value: entity.agent,
                    hint: "Use a compiled Jidoka agent module and valid handoff options.",
                    module: owner_module
                  )
        end
      end)

    case Jidoka.Handoff.Capability.handoff_names(handoffs) do
      {:ok, _names} ->
        handoffs

      {:error, message} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: message,
                path: [:capabilities, :handoff],
                value: Enum.map(handoffs, & &1.name),
                hint: "Give each handoff a unique `as:` name.",
                module: owner_module
              )
    end
  end

  @spec resolve_skills!(module(), [struct()], Path.t()) :: Jidoka.Skill.config() | nil
  def resolve_skills!(owner_module, entries, base_dir)
      when is_list(entries) and is_binary(base_dir) do
    case Jidoka.Skill.normalize_dsl(entries, base_dir) do
      {:ok, normalized} ->
        normalized

      {:error, message} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: message,
                path: [:capabilities],
                hint: "Declare skills with `skill` or `load_path` inside `capabilities`.",
                module: owner_module
              )
    end
  end

  @spec resolve_mcp!([struct()], module()) :: Jidoka.MCP.config()
  def resolve_mcp!(entries, owner_module) when is_list(entries) do
    case Jidoka.MCP.normalize_dsl(entries) do
      {:ok, normalized} ->
        normalized

      {:error, message} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: message,
                path: [:capabilities, :mcp_tools],
                hint: "Declare MCP endpoints as `mcp_tools endpoint: ...` inside `capabilities`.",
                module: owner_module
              )
    end
  end

  @spec resolve_web!([struct()], module()) :: [Jidoka.Web.t()]
  def resolve_web!(entries, owner_module) when is_list(entries) do
    case Jidoka.Web.normalize_dsl(entries) do
      {:ok, normalized} ->
        normalized

      {:error, message} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: message,
                path: [:capabilities, :web],
                hint: "Declare `web :search` or `web :read_only` at most once inside `capabilities`.",
                module: owner_module
              )
    end
  end

  @spec resolve_subagents!([struct()], module()) :: [Jidoka.Subagent.t()]
  def resolve_subagents!(entries, owner_module) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn %Jidoka.Agent.Dsl.Subagent{} = entry, {:ok, acc} ->
      case Jidoka.Subagent.new(
             entry.agent,
             as: entry.as,
             description: entry.description,
             target: entry.target,
             timeout: entry.timeout,
             forward_context: entry.forward_context,
             result: entry.result
           ) do
        {:ok, subagent} ->
          {:cont, {:ok, acc ++ [subagent]}}

        {:error, message} ->
          {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, subagents} ->
        case Jidoka.Subagent.subagent_names(subagents) do
          {:ok, _names} ->
            subagents

          {:error, message} ->
            raise Jidoka.Agent.Dsl.Error.exception(
                    message: message,
                    path: [:capabilities, :subagent],
                    hint: "Give each subagent a unique published tool name.",
                    module: owner_module
                  )
        end

      {:error, message} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: message,
                path: [:capabilities, :subagent],
                hint: "Declare subagents inside `capabilities` with a Jidoka-compatible module.",
                module: owner_module
              )
    end
  end

  @spec resolve_workflows!([struct()], module()) :: [Jidoka.Workflow.Capability.t()]
  def resolve_workflows!(entries, owner_module) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn %Jidoka.Agent.Dsl.Workflow{} = entry, {:ok, acc} ->
      case Jidoka.Workflow.Capability.new(
             entry.workflow,
             as: entry.as,
             description: entry.description,
             timeout: entry.timeout,
             forward_context: entry.forward_context,
             result: entry.result
           ) do
        {:ok, workflow} ->
          {:cont, {:ok, acc ++ [workflow]}}

        {:error, message} ->
          {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, workflows} ->
        case Jidoka.Workflow.Capability.workflow_names(workflows) do
          {:ok, _names} ->
            workflows

          {:error, message} ->
            raise Jidoka.Agent.Dsl.Error.exception(
                    message: message,
                    path: [:capabilities, :workflow],
                    hint: "Give each workflow capability a unique published tool name.",
                    module: owner_module
                  )
        end

      {:error, message} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: message,
                path: [:capabilities, :workflow],
                hint: "Declare workflows inside `capabilities` with a Jidoka workflow module.",
                module: owner_module
              )
    end
  end

  @spec resolve_tool_names!(module(), [module()], [atom()]) :: [String.t()]
  def resolve_tool_names!(owner_module, tool_modules, path) do
    case Jidoka.Tool.tool_names(tool_modules) do
      {:ok, tool_names} ->
        tool_names

      {:error, message} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: message,
                path: path,
                hint: "Use Jidoka action modules that publish valid names.",
                module: owner_module
              )
    end
  end

  @spec resolve_plugin_tools!(module(), [module()]) :: {[String.t()], [module()], [String.t()]}
  def resolve_plugin_tools!(owner_module, plugin_modules) do
    plugin_names =
      case Jidoka.Plugin.plugin_names(plugin_modules) do
        {:ok, plugin_names} ->
          plugin_names

        {:error, message} ->
          raise Jidoka.Agent.Dsl.Error.exception(
                  message: message,
                  path: [:capabilities, :plugin],
                  hint: "Ensure each plugin module uses `Jidoka.Plugin` and declares a unique name.",
                  module: owner_module
                )
      end

    plugin_tool_modules =
      case Jidoka.Plugin.plugin_actions(plugin_modules) do
        {:ok, plugin_tool_modules} ->
          plugin_tool_modules

        {:error, message} ->
          raise Jidoka.Agent.Dsl.Error.exception(
                  message: message,
                  path: [:capabilities, :plugin],
                  hint: "Ensure each plugin returns valid action-backed tool modules.",
                  module: owner_module
                )
      end

    plugin_tool_names =
      case Jidoka.Tool.action_names(plugin_tool_modules) do
        {:ok, plugin_tool_names} ->
          plugin_tool_names

        {:error, message} ->
          raise Jidoka.Agent.Dsl.Error.exception(
                  message: message,
                  path: [:capabilities, :plugin],
                  hint: "Plugin-provided tools must publish valid unique tool names.",
                  module: owner_module
                )
      end

    {plugin_names, plugin_tool_modules, plugin_tool_names}
  end

  def resolve_web_tool_names!(_owner_module, []), do: []

  @spec resolve_web_tool_names!(module(), [Jidoka.Web.t()]) :: [String.t()]
  def resolve_web_tool_names!(owner_module, configured_web) do
    case Jidoka.Web.tool_names(configured_web) do
      {:ok, web_tool_names} ->
        web_tool_names

      {:error, message} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: message,
                path: [:capabilities, :web],
                hint: "Use a supported Jidoka web mode such as `web :search` or `web :read_only`.",
                module: owner_module
              )
    end
  end

  @spec resolve_skill_tools!(module(), Jidoka.Skill.config() | nil) :: {[String.t()], [module()], [String.t()]}
  def resolve_skill_tools!(owner_module, configured_skills) do
    skill_tool_modules = Jidoka.Skill.action_modules(configured_skills)

    case Jidoka.Tool.action_names(skill_tool_modules) do
      {:ok, skill_tool_names} ->
        {Jidoka.Skill.skill_names(configured_skills), skill_tool_modules, skill_tool_names}

      {:error, message} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: message,
                path: [:capabilities, :skill],
                hint: "Skill-provided tools must publish valid unique tool names.",
                module: owner_module
              )
    end
  end

  @spec resolve_ash_resources!(module(), [module()]) :: map()
  def resolve_ash_resources!(owner_module, ash_resources) do
    case Jidoka.Agent.AshResources.expand(ash_resources) do
      {:ok, ash_resource_info} ->
        ash_resource_info

      {:error, message} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: message,
                path: [:capabilities, :ash_resource],
                hint: "Use an Ash resource extended with AshJido.",
                module: owner_module
              )
    end
  end

  @spec ensure_unique_tool_names!(module(), [String.t()]) :: :ok
  def ensure_unique_tool_names!(owner_module, tool_names) do
    if Enum.uniq(tool_names) != tool_names do
      duplicates =
        tool_names
        |> Enum.frequencies()
        |> Enum.filter(fn {_name, count} -> count > 1 end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      raise Jidoka.Agent.Dsl.Error.exception(
              message: "duplicate operation names in Jidoka agent: #{Enum.join(duplicates, ", ")}",
              path: [:capabilities],
              value: duplicates,
              hint:
                "Rename or remove one of the conflicting operations across direct actions, Ash, MCP, skill, plugin, web, subagent, workflow, and handoff sources.",
              module: owner_module
            )
    end

    :ok
  end

  @spec ash_tool_config(map()) :: map() | nil
  def ash_tool_config(%{resources: []}), do: nil

  def ash_tool_config(ash_resource_info) do
    %{
      resources: ash_resource_info.resources,
      domain: ash_resource_info.domain,
      require_actor?: true
    }
  end
end
