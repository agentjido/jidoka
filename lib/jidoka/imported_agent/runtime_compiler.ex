defmodule Jidoka.ImportedAgent.RuntimeCompiler do
  @moduledoc false

  alias Jidoka.ImportedAgent.{Definition, Spec}

  @spec ensure_runtime_module(
          struct(),
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
          map()
        ) :: {:ok, module()} | {:error, term()}
  def ensure_runtime_module(
        %Spec{} = spec,
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
        guardrail_modules
      ) do
    runtime_plugins = runtime_plugins(plugin_modules, spec.memory)

    # Imported runtimes are content-addressed modules. We intentionally reuse an
    # already-loaded module for identical spec/registry inputs rather than trying
    # to unload generated code; the BEAM does not have a safe per-caller cleanup
    # story for modules that may still be referenced by running agents.
    runtime_module =
      generated_module(
        spec,
        character_spec,
        tool_modules,
        skill_refs,
        mcp_tools,
        subagents,
        workflows,
        handoffs,
        web,
        runtime_plugins,
        hook_modules,
        guardrail_modules
      )

    if Code.ensure_loaded?(runtime_module) do
      {:ok, runtime_module}
    else
      create_runtime_module(
        runtime_module,
        spec,
        character_spec,
        tool_modules,
        skill_refs,
        mcp_tools,
        subagents,
        workflows,
        handoffs,
        web,
        plugin_modules,
        runtime_plugins,
        hook_modules,
        guardrail_modules
      )
    end
  end

  @spec generated_tool_module_base(struct(), [map()], [map()], [map()]) :: module()
  def generated_tool_module_base(%Spec{} = spec, subagents, workflows, handoffs) do
    suffix =
      %{
        spec: Spec.to_external_map(spec),
        subagents:
          Enum.map(subagents, fn subagent ->
            %{
              name: subagent.name,
              agent: inspect(subagent.agent),
              target: externalize_subagent_target(subagent.target),
              timeout: subagent.timeout,
              forward_context: inspect(subagent.forward_context),
              result: subagent.result
            }
          end),
        workflows:
          Enum.map(workflows, fn workflow ->
            %{
              name: workflow.name,
              workflow: inspect(workflow.workflow),
              timeout: workflow.timeout,
              forward_context: inspect(workflow.forward_context),
              result: workflow.result
            }
          end),
        handoffs:
          Enum.map(handoffs, fn handoff ->
            %{
              name: handoff.name,
              agent: inspect(handoff.agent),
              target: externalize_handoff_target(handoff.target),
              forward_context: inspect(handoff.forward_context)
            }
          end)
      }
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)
      |> String.upcase()

    Module.concat([Jidoka.ImportedRuntime, "Tools#{suffix}"])
  end

  @spec request_transformer(struct(), module()) :: module()
  def request_transformer(%Spec{}, runtime_module) do
    Module.concat(runtime_module, RequestTransformer)
  end

  defp generated_module(
         %Spec{} = spec,
         character_spec,
         tool_modules,
         skill_refs,
         mcp_tools,
         subagents,
         workflows,
         handoffs,
         web,
         runtime_plugins,
         hook_modules,
         guardrail_modules
       ) do
    suffix =
      %{
        spec: Spec.to_external_map(spec),
        character: inspect(character_spec),
        tools: Enum.map(tool_modules, &inspect/1),
        skills:
          Enum.map(skill_refs, fn
            module when is_atom(module) -> inspect(module)
            name when is_binary(name) -> name
          end),
        mcp_tools: mcp_tools,
        subagents:
          Enum.map(subagents, fn subagent ->
            %{
              name: subagent.name,
              agent: inspect(subagent.agent),
              target: externalize_subagent_target(subagent.target)
            }
          end),
        workflows:
          Enum.map(workflows, fn workflow ->
            %{
              name: workflow.name,
              workflow: inspect(workflow.workflow)
            }
          end),
        handoffs:
          Enum.map(handoffs, fn handoff ->
            %{
              name: handoff.name,
              agent: inspect(handoff.agent),
              target: externalize_handoff_target(handoff.target)
            }
          end),
        web:
          Enum.map(web, fn capability ->
            %{
              mode: capability.mode,
              tools: Enum.map(capability.tools, &inspect/1)
            }
          end),
        plugins: Enum.map(runtime_plugins, &inspect/1),
        hooks:
          Enum.into(hook_modules, %{}, fn {stage, modules} ->
            {stage, Enum.map(modules, &inspect/1)}
          end),
        guardrails:
          Enum.into(guardrail_modules, %{}, fn {stage, modules} ->
            {stage, Enum.map(modules, &inspect/1)}
          end)
      }
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)
      |> String.upcase()

    Module.concat([Jidoka.ImportedRuntime, "Runtime#{suffix}"])
  end

  defp create_runtime_module(
         runtime_module,
         %Spec{} = spec,
         character_spec,
         tool_modules,
         skill_refs,
         mcp_tools,
         subagents,
         workflows,
         handoffs,
         web,
         plugin_modules,
         runtime_plugins,
         hook_modules,
         guardrail_modules
       ) do
    request_transformer_module = Module.concat(runtime_module, RequestTransformer)
    skill_config = %{refs: skill_refs, load_paths: spec.skill_paths}

    effective_request_transformer = request_transformer_module
    generated_tool_modules = generated_tool_module_ast(spec, subagents, workflows, handoffs)

    quoted =
      quote location: :keep do
        if unquote(Macro.escape(effective_request_transformer)) do
          defmodule unquote(request_transformer_module) do
            @moduledoc false
            @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

            @system_prompt_spec unquote(Macro.escape(spec.instructions))
            @character_spec unquote(Macro.escape(character_spec))
            @skills_config unquote(Macro.escape(skill_config))

            @impl true
            def transform_request(request, state, config, runtime_context) do
              Jidoka.Agent.RequestTransformer.transform_request(
                @system_prompt_spec,
                @character_spec,
                @skills_config,
                request,
                state,
                config,
                runtime_context
              )
            end
          end
        end

        unquote_splicing(generated_tool_modules)

        use Jido.AI.Agent,
          name: unquote(spec.id),
          system_prompt: unquote(spec.instructions),
          model: unquote(Macro.escape(spec.model)),
          tools: unquote(Macro.escape(tool_modules)),
          plugins: unquote(Macro.escape(runtime_plugins)),
          default_plugins: unquote(Macro.escape(Jidoka.Memory.default_plugins(spec.memory))),
          request_transformer: unquote(Macro.escape(effective_request_transformer))

        unquote(
          Jidoka.Agent.Runtime.hook_runtime_ast(
            hook_modules,
            spec.context,
            guardrail_modules,
            spec.compaction,
            spec.memory,
            spec.output,
            skill_config,
            mcp_tools
          )
        )

        @doc false
        @spec __jidoka_owner_module__() :: nil
        def __jidoka_owner_module__, do: nil

        @doc false
        @spec __jidoka_definition__() :: map()
        def __jidoka_definition__ do
          unquote(
            Macro.escape(
              Definition.map(
                spec,
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
                effective_request_transformer
              )
            )
          )
        end
      end

    {:module, ^runtime_module, _binary, _term} =
      Module.create(runtime_module, quoted, Macro.Env.location(__ENV__))

    {:ok, runtime_module}
  rescue
    error in [ArgumentError] ->
      if Code.ensure_loaded?(runtime_module) do
        {:ok, runtime_module}
      else
        {:error, error}
      end
  end

  defp generated_tool_module_ast(spec, subagents, workflows, handoffs) do
    tool_module_base = generated_tool_module_base(spec, subagents, workflows, handoffs)

    subagent_tool_modules =
      subagents
      |> Enum.with_index()
      |> Enum.map(fn {subagent, index} ->
        tool_module = Jidoka.Subagent.tool_module(tool_module_base, subagent, index)
        Jidoka.Subagent.tool_module_ast(tool_module, subagent)
      end)

    workflow_tool_modules =
      workflows
      |> Enum.with_index()
      |> Enum.map(fn {workflow, index} ->
        tool_module = Jidoka.Workflow.Capability.tool_module(tool_module_base, workflow, index)
        Jidoka.Workflow.Capability.tool_module_ast(tool_module, workflow)
      end)

    handoff_tool_modules =
      handoffs
      |> Enum.with_index()
      |> Enum.map(fn {handoff, index} ->
        tool_module = Jidoka.Handoff.Capability.tool_module(tool_module_base, handoff, index)
        Jidoka.Handoff.Capability.tool_module_ast(tool_module, handoff)
      end)

    subagent_tool_modules ++ workflow_tool_modules ++ handoff_tool_modules
  end

  defp externalize_subagent_target(:ephemeral), do: %{"target" => "ephemeral"}

  defp externalize_subagent_target({:peer, peer_id}) when is_binary(peer_id) do
    %{"target" => "peer", "peer_id" => peer_id}
  end

  defp externalize_subagent_target({:peer, {:context, key}}) do
    %{"target" => "peer", "peer_id_context_key" => to_string(key)}
  end

  defp externalize_handoff_target(:auto), do: %{"target" => "auto"}

  defp externalize_handoff_target({:peer, peer_id}) when is_binary(peer_id) do
    %{"target" => "peer", "peer_id" => peer_id}
  end

  defp externalize_handoff_target({:peer, {:context, key}}) do
    %{"target" => "peer", "peer_id_context_key" => to_string(key)}
  end

  defp runtime_plugins(plugin_modules, _memory_config), do: [Jidoka.Plugins.RuntimeCompat | plugin_modules]
end
