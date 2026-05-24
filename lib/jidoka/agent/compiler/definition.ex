defmodule Jidoka.Agent.Definition do
  @moduledoc false

  alias Jidoka.Agent.Definition.{
    Basics,
    Capabilities,
    CompactionConfig,
    ContextConfig,
    Legacy,
    LifecycleConfig,
    MemoryConfig,
    OutputConfig,
    ScheduleConfig
  }

  @type t :: map()

  @spec build!(Macro.Env.t()) :: t()
  def build!(%Macro.Env{} = env) do
    owner_module = env.module

    Legacy.reject_legacy_placements!(owner_module)

    agent = agent_contract!(owner_module)

    id = Basics.resolve_agent_id!(owner_module, agent.id)
    description = agent.description

    configured_model = agent.model || :fast
    resolved_model = Basics.resolve_model!(owner_module, configured_model)
    configured_instructions = agent.instructions
    configured_character = agent.character

    Basics.require_instructions!(owner_module, configured_instructions)
    character_spec = Basics.resolve_character!(owner_module, configured_character)

    {runtime_system_prompt, dynamic_system_prompt} =
      case Basics.resolve_instructions!(owner_module, configured_instructions) do
        {:static, prompt} ->
          {prompt, nil}

        {:dynamic, spec} ->
          {nil, spec}
      end

    configured_context_schema = ContextConfig.resolve_schema!(agent.context, owner_module)

    configured_context = ContextConfig.resolve_defaults!(owner_module, configured_context_schema)
    configured_output = OutputConfig.resolve!(owner_module, agent.result)
    configured_schedules = ScheduleConfig.resolve!(owner_module)
    configured_compaction = CompactionConfig.resolve!(owner_module)

    capability_entities = Spark.Dsl.Extension.get_entities(owner_module, [:capabilities])
    tool_entities = Spark.Dsl.Extension.get_entities(owner_module, [:tools])

    configured_subagents =
      owner_module
      |> section_entities([:capabilities], &match?(%Jidoka.Agent.Dsl.Subagent{}, &1))
      |> Capabilities.resolve_subagents!(owner_module)

    configured_workflows =
      owner_module
      |> section_entities([:capabilities], &match?(%Jidoka.Agent.Dsl.Workflow{}, &1))
      |> Capabilities.resolve_workflows!(owner_module)

    configured_handoffs =
      owner_module
      |> section_entities([:capabilities], &match?(%Jidoka.Agent.Dsl.Handoff{}, &1))
      |> Capabilities.resolve_handoffs!(owner_module)

    configured_memory =
      owner_module
      |> MemoryConfig.resolve!(configured_context_schema)

    skill_refs =
      Enum.filter(
        capability_entities,
        &(match?(%Jidoka.Agent.Dsl.SkillRef{}, &1) or
            match?(%Jidoka.Agent.Dsl.SkillPath{}, &1))
      )

    configured_skills = Capabilities.resolve_skills!(owner_module, skill_refs, Path.dirname(env.file))

    configured_mcp_tools =
      capability_entities
      |> Enum.filter(&match?(%Jidoka.Agent.Dsl.MCPTools{}, &1))
      |> Capabilities.resolve_mcp!(owner_module)

    configured_web =
      capability_entities
      |> Enum.filter(&match?(%Jidoka.Agent.Dsl.Web{}, &1))
      |> Capabilities.resolve_web!(owner_module)

    configured_hooks =
      owner_module
      |> section_entities(
        [:lifecycle],
        &(match?(%Jidoka.Agent.Dsl.BeforeTurnHook{}, &1) or
            match?(%Jidoka.Agent.Dsl.AfterTurnHook{}, &1) or
            match?(%Jidoka.Agent.Dsl.InterruptHook{}, &1))
      )
      |> LifecycleConfig.resolve_hooks!(owner_module)

    configured_guardrails =
      (guardrail_entities(owner_module, [:lifecycle]) ++
         guardrail_entities(owner_module, [:controls]))
      |> LifecycleConfig.resolve_guardrails!(owner_module)

    direct_tool_modules =
      (capability_entities ++ tool_entities)
      |> Enum.filter(&match?(%Jidoka.Agent.Dsl.Tool{}, &1))
      |> Enum.map(& &1.module)

    ash_resources =
      capability_entities
      |> Enum.filter(&match?(%Jidoka.Agent.Dsl.AshResource{}, &1))
      |> Enum.map(& &1.resource)

    plugin_modules =
      capability_entities
      |> Enum.filter(&match?(%Jidoka.Agent.Dsl.Plugin{}, &1))
      |> Enum.map(& &1.module)

    direct_tool_names = Capabilities.resolve_tool_names!(owner_module, direct_tool_modules, [:capabilities, :tool])

    {plugin_names, plugin_tool_modules, plugin_tool_names} =
      Capabilities.resolve_plugin_tools!(owner_module, plugin_modules)

    web_tool_modules = Jidoka.Web.tool_modules(configured_web)

    web_tool_names =
      Capabilities.resolve_web_tool_names!(owner_module, configured_web)

    {skill_names, skill_tool_modules, skill_tool_names} =
      Capabilities.resolve_skill_tools!(owner_module, configured_skills)

    ash_resource_info = Capabilities.resolve_ash_resources!(owner_module, ash_resources)

    subagent_tool_modules =
      configured_subagents
      |> Enum.with_index()
      |> Enum.map(fn {subagent, index} ->
        Jidoka.Subagent.tool_module(owner_module, subagent, index)
      end)

    subagent_tool_names = Enum.map(configured_subagents, & &1.name)

    workflow_tool_modules =
      configured_workflows
      |> Enum.with_index()
      |> Enum.map(fn {workflow, index} ->
        Jidoka.Workflow.Capability.tool_module(owner_module, workflow, index)
      end)

    workflow_tool_names = Enum.map(configured_workflows, & &1.name)

    handoff_tool_modules =
      configured_handoffs
      |> Enum.with_index()
      |> Enum.map(fn {handoff, index} ->
        Jidoka.Handoff.Capability.tool_module(owner_module, handoff, index)
      end)

    handoff_tool_names = Enum.map(configured_handoffs, & &1.name)

    runtime_plugins = Jidoka.Agent.Runtime.runtime_plugins(plugin_modules, configured_memory)

    tool_modules =
      direct_tool_modules ++
        ash_resource_info.tool_modules ++
        skill_tool_modules ++
        plugin_tool_modules ++
        web_tool_modules ++
        subagent_tool_modules ++
        workflow_tool_modules ++
        handoff_tool_modules

    tool_names =
      direct_tool_names ++
        ash_resource_info.tool_names ++
        skill_tool_names ++
        plugin_tool_names ++
        web_tool_names ++
        subagent_tool_names ++
        workflow_tool_names ++
        handoff_tool_names

    Capabilities.ensure_unique_tool_names!(owner_module, tool_names)

    runtime_module = Module.concat(owner_module, Runtime)
    request_transformer_module = Module.concat(owner_module, RuntimeRequestTransformer)

    request_transformer_system_prompt = dynamic_system_prompt || runtime_system_prompt
    effective_request_transformer = request_transformer_module

    ash_tool_config = Capabilities.ash_tool_config(ash_resource_info)

    public_definition = %{
      kind: :agent_definition,
      module: owner_module,
      runtime_module: runtime_module,
      id: id,
      name: id,
      description: description,
      instructions: configured_instructions,
      character: configured_character,
      character_spec: character_spec,
      request_transformer: effective_request_transformer,
      configured_model: configured_model,
      model: resolved_model,
      context_schema: configured_context_schema,
      context: configured_context,
      result: configured_output,
      output: configured_output,
      schedules: configured_schedules,
      compaction: configured_compaction,
      memory: configured_memory,
      skills: configured_skills,
      tools: tool_modules,
      tool_names: tool_names,
      mcp_tools: configured_mcp_tools,
      web: configured_web,
      web_tool_names: web_tool_names,
      subagents: configured_subagents,
      subagent_names: subagent_tool_names,
      workflows: configured_workflows,
      workflow_names: workflow_tool_names,
      handoffs: configured_handoffs,
      handoff_names: handoff_tool_names,
      plugins: plugin_modules,
      plugin_names: plugin_names,
      hooks: configured_hooks,
      guardrails: configured_guardrails,
      ash_resources: ash_resource_info.resources,
      ash_domain: ash_resource_info.domain,
      requires_actor?: ash_resource_info.require_actor?
    }

    %{
      module: owner_module,
      runtime_module: runtime_module,
      request_transformer_module: request_transformer_module,
      request_transformer_system_prompt: request_transformer_system_prompt,
      runtime_system_prompt: runtime_system_prompt,
      effective_request_transformer: effective_request_transformer,
      id: id,
      name: id,
      description: description,
      model: resolved_model,
      configured_model: configured_model,
      configured_instructions: configured_instructions,
      configured_character: configured_character,
      character_spec: character_spec,
      context_schema: configured_context_schema,
      context: configured_context,
      result: configured_output,
      output: configured_output,
      schedules: configured_schedules,
      compaction: configured_compaction,
      memory: configured_memory,
      skills: configured_skills,
      skill_names: skill_names,
      mcp_tools: configured_mcp_tools,
      web: configured_web,
      web_tool_modules: web_tool_modules,
      web_tool_names: web_tool_names,
      subagents: configured_subagents,
      subagent_tool_modules: subagent_tool_modules,
      subagent_names: subagent_tool_names,
      workflows: configured_workflows,
      workflow_tool_modules: workflow_tool_modules,
      workflow_names: workflow_tool_names,
      handoffs: configured_handoffs,
      handoff_tool_modules: handoff_tool_modules,
      handoff_names: handoff_tool_names,
      runtime_plugins: runtime_plugins,
      plugins: plugin_modules,
      plugin_names: plugin_names,
      tools: tool_modules,
      tool_names: tool_names,
      hooks: configured_hooks,
      guardrails: configured_guardrails,
      ash_resources: ash_resource_info.resources,
      ash_domain: ash_resource_info.domain,
      requires_actor?: ash_resource_info.require_actor?,
      ash_tool_config: ash_tool_config,
      public_definition: public_definition
    }
  end

  @spec agent_contract!(module()) :: Jidoka.Agent.Dsl.Agent.t()
  def agent_contract!(owner_module) do
    case Spark.Dsl.Extension.get_entities(owner_module, [:jidoka]) do
      [%Jidoka.Agent.Dsl.Agent{} = agent] ->
        agent

      [] ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: "`agent :id do ... end` is required.",
                path: [:agent],
                hint: "Declare `agent :my_agent do instructions \"...\" end`.",
                module: owner_module
              )

      agents ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: "Only one `agent :id do ... end` block is allowed.",
                path: [:agent],
                value: Enum.map(agents, & &1.id),
                hint: "Merge the configuration into a single agent block.",
                module: owner_module
              )
    end
  end

  defp section_entities(owner_module, path, predicate) when is_function(predicate, 1) do
    owner_module
    |> Spark.Dsl.Extension.get_entities(path)
    |> Enum.filter(predicate)
  end

  defp guardrail_entities(owner_module, path) do
    section_entities(
      owner_module,
      path,
      &(match?(%Jidoka.Agent.Dsl.InputGuardrail{}, &1) or
          match?(%Jidoka.Agent.Dsl.OutputGuardrail{}, &1) or
          match?(%Jidoka.Agent.Dsl.ToolGuardrail{}, &1))
    )
  end
end
