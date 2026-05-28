defmodule Jidoka.Agent.Compiler.Resolvers.Core do
  @moduledoc false

  @behaviour Jidoka.Agent.Compiler.Resolver

  alias Jidoka.Agent.Compiler.Context

  alias Jidoka.Agent.Definition.{Basics, ContextConfig, OutputConfig}

  @impl true
  def name, do: :core

  @impl true
  def dsl_paths, do: [[:jidoka]]

  @impl true
  def resolve(%Context{} = context) do
    owner_module = context.owner_module
    agent = Jidoka.Agent.Definition.agent_contract!(owner_module)

    id = Basics.resolve_agent_id!(owner_module, agent.id)
    configured_model = agent.model || :fast
    resolved_model = Basics.resolve_model!(owner_module, configured_model)
    configured_instructions = agent.instructions
    configured_character = agent.character

    Basics.require_instructions!(owner_module, configured_instructions)
    character_spec = Basics.resolve_character!(owner_module, configured_character)

    {runtime_system_prompt, dynamic_system_prompt} =
      case Basics.resolve_instructions!(owner_module, configured_instructions) do
        {:static, prompt} -> {prompt, nil}
        {:dynamic, spec} -> {nil, spec}
      end

    context_schema = ContextConfig.resolve_schema!(agent.context, owner_module)
    default_context = ContextConfig.resolve_defaults!(owner_module, context_schema)

    values = %{
      agent_contract: agent,
      id: id,
      name: id,
      description: agent.description,
      configured_model: configured_model,
      model: resolved_model,
      configured_instructions: configured_instructions,
      configured_character: configured_character,
      character_spec: character_spec,
      runtime_system_prompt: runtime_system_prompt,
      dynamic_system_prompt: dynamic_system_prompt,
      context_schema: context_schema,
      context: default_context,
      result: OutputConfig.resolve!(owner_module, agent.result),
      schedules: [],
      compaction: nil
    }

    {:ok, %{context | agent: agent} |> Context.merge_values(values)}
  end
end

defmodule Jidoka.Agent.Compiler.Resolvers.Controls do
  @moduledoc false

  @behaviour Jidoka.Agent.Compiler.Resolver

  alias Jidoka.Agent.Compiler.Context
  alias Jidoka.Agent.Definition.{Capabilities, LifecycleConfig}

  @impl true
  def name, do: :controls

  @impl true
  def dsl_paths, do: [[:tools], [:controls]]

  @impl true
  def resolve(%Context{} = context) do
    owner_module = context.owner_module
    operation_entities = Spark.Dsl.Extension.get_entities(owner_module, [:tools])

    skill_refs =
      Enum.filter(
        operation_entities,
        &(match?(%Jidoka.Agent.Dsl.SkillRef{}, &1) or
            match?(%Jidoka.Agent.Dsl.SkillPath{}, &1))
      )

    guardrails =
      owner_module
      |> Jidoka.Agent.Definition.guardrail_entities([:controls])
      |> LifecycleConfig.resolve_guardrails!(owner_module)

    values = %{
      operation_entities: operation_entities,
      memory: nil,
      skills: Capabilities.resolve_skills!(owner_module, skill_refs, Path.dirname(context.env.file)),
      mcp_tools:
        operation_entities
        |> Enum.filter(&match?(%Jidoka.Agent.Dsl.MCPTools{}, &1))
        |> Capabilities.resolve_mcp!(owner_module),
      web:
        operation_entities
        |> Enum.filter(&match?(%Jidoka.Agent.Dsl.Web{}, &1))
        |> Capabilities.resolve_web!(owner_module),
      hooks: Jidoka.Hooks.default_stage_map(),
      guardrails: guardrails,
      lifecycle_timeouts: Jidoka.Lifecycle.Timeouts.default()
    }

    {:ok, Context.merge_values(context, values)}
  end
end

defmodule Jidoka.Agent.Compiler.Resolvers.Tools do
  @moduledoc false

  @behaviour Jidoka.Agent.Compiler.Resolver

  alias Jidoka.Agent.Compiler.Context
  alias Jidoka.Agent.Definition.Capabilities

  @impl true
  def name, do: :tools

  @impl true
  def dsl_paths, do: [[:tools]]

  @impl true
  def resolve(%Context{} = context) do
    owner_module = context.owner_module
    operation_entities = context.values.operation_entities

    subagents =
      operation_entities
      |> Enum.filter(&match?(%Jidoka.Agent.Dsl.Subagent{}, &1))
      |> Capabilities.resolve_subagents!(owner_module)

    workflows =
      operation_entities
      |> Enum.filter(&match?(%Jidoka.Agent.Dsl.Workflow{}, &1))
      |> Capabilities.resolve_workflows!(owner_module)

    handoffs =
      operation_entities
      |> Enum.filter(&match?(%Jidoka.Agent.Dsl.Handoff{}, &1))
      |> Capabilities.resolve_handoffs!(owner_module)

    direct_tool_modules =
      operation_entities
      |> Enum.filter(&match?(%Jidoka.Agent.Dsl.Tool{}, &1))
      |> Enum.map(& &1.module)

    ash_resources =
      operation_entities
      |> Enum.filter(&match?(%Jidoka.Agent.Dsl.AshResource{}, &1))
      |> Enum.map(& &1.resource)

    plugin_modules =
      operation_entities
      |> Enum.filter(&match?(%Jidoka.Agent.Dsl.Plugin{}, &1))
      |> Enum.map(& &1.module)

    direct_tool_names = Capabilities.resolve_tool_names!(owner_module, direct_tool_modules, [:tools, :action])

    {plugin_names, plugin_tool_modules, plugin_tool_names} =
      Capabilities.resolve_plugin_tools!(owner_module, plugin_modules)

    web_tool_modules = Jidoka.Web.tool_modules(context.values.web)
    web_tool_names = Capabilities.resolve_web_tool_names!(owner_module, context.values.web)

    {skill_names, skill_tool_modules, skill_tool_names} =
      Capabilities.resolve_skill_tools!(owner_module, context.values.skills)

    ash_resource_info = Capabilities.resolve_ash_resources!(owner_module, ash_resources)

    subagent_tool_modules = tool_modules(subagents, &Jidoka.Subagent.tool_module(owner_module, &1, &2))
    subagent_tool_names = Enum.map(subagents, & &1.name)

    workflow_tool_modules = tool_modules(workflows, &Jidoka.Workflow.Capability.tool_module(owner_module, &1, &2))
    workflow_tool_names = Enum.map(workflows, & &1.name)

    handoff_tool_modules = tool_modules(handoffs, &Jidoka.Handoff.Capability.tool_module(owner_module, &1, &2))
    handoff_tool_names = Enum.map(handoffs, & &1.name)

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

    values = %{
      direct_tool_modules: direct_tool_modules,
      direct_tool_names: direct_tool_names,
      ash_resource_info: ash_resource_info,
      ash_resources: ash_resource_info.resources,
      ash_domain: ash_resource_info.domain,
      requires_actor?: ash_resource_info.require_actor?,
      plugin_modules: plugin_modules,
      plugin_names: plugin_names,
      plugin_tool_modules: plugin_tool_modules,
      plugin_tool_names: plugin_tool_names,
      skill_names: skill_names,
      skill_tool_modules: skill_tool_modules,
      skill_tool_names: skill_tool_names,
      web_tool_modules: web_tool_modules,
      web_tool_names: web_tool_names,
      subagents: subagents,
      subagent_tool_modules: subagent_tool_modules,
      subagent_names: subagent_tool_names,
      workflows: workflows,
      workflow_tool_modules: workflow_tool_modules,
      workflow_names: workflow_tool_names,
      handoffs: handoffs,
      handoff_tool_modules: handoff_tool_modules,
      handoff_names: handoff_tool_names,
      tools: tool_modules,
      tool_names: tool_names,
      ash_tool_config: Capabilities.ash_tool_config(ash_resource_info)
    }

    context =
      Enum.reduce(tool_modules, Context.merge_values(context, values), fn module, acc ->
        Context.add_generated_module(acc, module)
      end)

    {:ok, context}
  end

  defp tool_modules(entries, fun) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> fun.(entry, index) end)
  end
end

defmodule Jidoka.Agent.Compiler.Resolvers.Runtime do
  @moduledoc false

  @behaviour Jidoka.Agent.Compiler.Resolver

  alias Jidoka.Agent.Compiler.Context

  @impl true
  def name, do: :runtime

  @impl true
  def dsl_paths, do: []

  @impl true
  def resolve(%Context{} = context) do
    owner_module = context.owner_module
    values = context.values

    runtime_module = Module.concat(owner_module, Runtime)
    request_transformer_module = Module.concat(owner_module, RuntimeRequestTransformer)
    request_transformer_system_prompt = values.dynamic_system_prompt || values.runtime_system_prompt
    effective_request_transformer = request_transformer_module
    runtime_plugins = Jidoka.Agent.Runtime.runtime_plugins(values.plugin_modules, values.memory)

    public_definition = %{
      kind: :agent_definition,
      module: owner_module,
      runtime_module: runtime_module,
      id: values.id,
      name: values.id,
      description: values.description,
      instructions: values.configured_instructions,
      character: values.configured_character,
      character_spec: values.character_spec,
      request_transformer: effective_request_transformer,
      configured_model: values.configured_model,
      model: values.model,
      context_schema: values.context_schema,
      context: values.context,
      result: values.result,
      skills: values.skills,
      tools: values.tools,
      tool_names: values.tool_names,
      mcp_tools: values.mcp_tools,
      web: values.web,
      web_tool_names: values.web_tool_names,
      subagents: values.subagents,
      subagent_names: values.subagent_names,
      workflows: values.workflows,
      workflow_names: values.workflow_names,
      handoffs: values.handoffs,
      handoff_names: values.handoff_names,
      plugins: values.plugin_modules,
      plugin_names: values.plugin_names,
      guardrails: values.guardrails,
      ash_resources: values.ash_resources,
      ash_domain: values.ash_domain,
      requires_actor?: values.requires_actor?
    }

    definition =
      values
      |> Map.merge(%{
        module: owner_module,
        runtime_module: runtime_module,
        request_transformer_module: request_transformer_module,
        request_transformer_system_prompt: request_transformer_system_prompt,
        effective_request_transformer: effective_request_transformer,
        output: values.result,
        runtime_plugins: runtime_plugins,
        plugins: values.plugin_modules,
        public_definition: public_definition
      })
      |> Map.drop([:agent_contract, :operation_entities, :dynamic_system_prompt])

    context =
      context
      |> Context.merge_values(%{definition: definition})
      |> Context.merge_public_fields(public_definition)
      |> Context.add_generated_module(runtime_module)
      |> Context.add_generated_module(request_transformer_module)
      |> Context.put_runtime_hook(:request_transformer, effective_request_transformer)
      |> Context.put_trace_name(:agent, values.id)

    {:ok, context}
  end
end
