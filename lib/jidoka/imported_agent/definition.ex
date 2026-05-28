defmodule Jidoka.ImportedAgent.Definition do
  @moduledoc false

  alias Jidoka.ImportedAgent.Spec

  @spec map(
          struct(),
          module(),
          Jidoka.Character.spec(),
          [module()],
          [term()],
          [map()],
          [Jidoka.Subagent.t()],
          [struct()],
          [struct()],
          [Jidoka.Web.t()],
          [module()],
          map(),
          map(),
          module()
        ) :: map()
  def map(
        %Spec{} = spec,
        runtime_module,
        character_spec,
        tool_modules,
        skill_refs,
        mcp_tools,
        subagents,
        workflows,
        handoffs,
        web,
        plugin_modules,
        hook_modules,
        guardrail_modules,
        request_transformer
      ) do
    {:ok, plugin_names} = Jidoka.Plugin.plugin_names(plugin_modules)

    %{
      kind: :imported_agent_definition,
      module: nil,
      runtime_module: runtime_module,
      id: spec.id,
      name: spec.id,
      description: spec.description,
      instructions: spec.instructions,
      character: spec.character,
      character_spec: character_spec,
      request_transformer: request_transformer,
      configured_model: spec.model,
      model: Jidoka.Model.model(spec.model),
      context_schema: nil,
      context: spec.context,
      output: spec.output,
      compaction: spec.compaction,
      memory: spec.memory,
      skills: %{refs: skill_refs, load_paths: spec.skill_paths},
      tools: tool_modules,
      tool_names: tool_names(tool_modules, subagents, workflows, handoffs),
      mcp_tools: mcp_tools,
      web: web,
      web_tool_names: web_tool_names(web),
      subagents: subagents,
      subagent_names: Enum.map(subagents, & &1.name),
      workflows: workflows,
      workflow_names: Enum.map(workflows, & &1.name),
      handoffs: handoffs,
      handoff_names: Enum.map(handoffs, & &1.name),
      plugins: plugin_modules,
      plugin_names: plugin_names,
      hooks: hook_modules,
      guardrails: guardrail_modules,
      lifecycle_timeouts: Jidoka.Lifecycle.Timeouts.default(),
      ash_resources: [],
      ash_domain: nil,
      requires_actor?: false
    }
  end

  defp tool_names(tool_modules, subagents, workflows, handoffs) do
    loaded_names =
      tool_modules
      |> Enum.reduce([], fn module, acc ->
        if Code.ensure_loaded?(module) and function_exported?(module, :name, 0) do
          [module.name() | acc]
        else
          acc
        end
      end)

    (Enum.reverse(loaded_names) ++
       Enum.map(subagents, & &1.name) ++ Enum.map(workflows, & &1.name) ++ Enum.map(handoffs, & &1.name))
    |> Enum.uniq()
  end

  defp web_tool_names(web) do
    case Jidoka.Web.tool_names(web) do
      {:ok, names} -> names
      {:error, _reason} -> []
    end
  end
end
