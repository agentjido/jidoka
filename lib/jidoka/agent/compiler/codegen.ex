defmodule Jidoka.Agent.Codegen do
  @moduledoc false

  @spec emit(Jidoka.Agent.Definition.t()) :: Macro.t()
  def emit(definition) when is_map(definition) do
    request_transformer_definition = request_transformer_definition(definition)
    subagent_tool_definitions = subagent_tool_definitions(definition)
    workflow_tool_definitions = workflow_tool_definitions(definition)
    handoff_tool_definitions = handoff_tool_definitions(definition)

    quote location: :keep do
      unquote(request_transformer_definition)
      unquote_splicing(subagent_tool_definitions)
      unquote_splicing(workflow_tool_definitions)
      unquote_splicing(handoff_tool_definitions)

      defmodule unquote(definition.runtime_module) do
        use Jido.AI.Agent,
          name: unquote(definition.name),
          system_prompt: unquote(definition.runtime_system_prompt),
          model: unquote(Macro.escape(definition.model)),
          tools: unquote(Macro.escape(definition.tools)),
          plugins: unquote(Macro.escape(definition.runtime_plugins)),
          default_plugins: unquote(Macro.escape(Jidoka.Memory.default_plugins(definition.memory))),
          request_transformer: unquote(definition.effective_request_transformer)

        unquote(
          Jidoka.Agent.Runtime.hook_runtime_ast(
            definition.hooks,
            definition.context,
            definition.guardrails,
            definition.compaction,
            definition.memory,
            definition.output,
            definition.skills,
            definition.mcp_tools
          )
        )

        @doc false
        @spec __jidoka_owner_module__() :: module()
        def __jidoka_owner_module__, do: unquote(definition.module)

        @doc false
        @spec __jidoka_definition__() :: map()
        def __jidoka_definition__, do: unquote(Macro.escape(definition.public_definition))
      end

      unquote(public_agent_functions(definition))
    end
  end

  defp request_transformer_definition(%{effective_request_transformer: nil}) do
    quote do
    end
  end

  defp request_transformer_definition(definition) do
    quote location: :keep do
      defmodule unquote(definition.request_transformer_module) do
        @moduledoc false
        @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

        @system_prompt_spec unquote(Macro.escape(definition.request_transformer_system_prompt))
        @character_spec unquote(Macro.escape(definition.character_spec))
        @skills_config unquote(Macro.escape(definition.skills))

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
  end

  defp subagent_tool_definitions(definition) do
    definition.subagents
    |> Enum.with_index()
    |> Enum.map(fn {subagent, index} ->
      tool_module = Enum.at(definition.subagent_tool_modules, index)
      Jidoka.Subagent.tool_module_ast(tool_module, subagent)
    end)
  end

  defp workflow_tool_definitions(definition) do
    definition.workflows
    |> Enum.with_index()
    |> Enum.map(fn {workflow, index} ->
      tool_module = Enum.at(definition.workflow_tool_modules, index)
      Jidoka.Workflow.Capability.tool_module_ast(tool_module, workflow)
    end)
  end

  defp handoff_tool_definitions(definition) do
    definition.handoffs
    |> Enum.with_index()
    |> Enum.map(fn {handoff, index} ->
      tool_module = Enum.at(definition.handoff_tool_modules, index)
      Jidoka.Handoff.Capability.tool_module_ast(tool_module, handoff)
    end)
  end

  defp public_agent_functions(definition) do
    quote location: :keep do
      @doc """
      Starts this agent under the shared `Jidoka.Runtime` instance.

      For an application-owned Jido instance, pass `runtime_module/0` to that
      instance's `start_agent/2` instead.
      """
      @spec start_link(keyword()) :: DynamicSupervisor.on_start_child()
      def start_link(opts \\ []) do
        Jidoka.Runtime.start_agent(unquote(definition.runtime_module), opts)
      end

      @doc """
      Convenience alias for `ask_sync/3`.
      """
      @spec chat(pid(), String.t(), keyword()) ::
              {:ok, term()}
              | {:ok, Jidoka.Chat.Stream.t()}
              | {:error, term()}
              | {:interrupt, Jidoka.Interrupt.t()}
              | {:handoff, Jidoka.Handoff.t()}
      def chat(pid, message, opts \\ []) when is_pid(pid) and is_binary(message) do
        Jidoka.Chat.chat(pid, message, opts)
      end

      @doc false
      @spec __jidoka__() :: map()
      def __jidoka__, do: unquote(Macro.escape(definition.public_definition))

      @doc """
      Returns the generated Jido/Jido.AI runtime module for this Jidoka agent.

      Use this when graduating into an application-owned Jido runtime:

          MyApp.Jido.start_agent(__MODULE__.runtime_module(), id: "support-router")

      Normal Jidoka callers should use `start_link/1`.
      """
      @spec runtime_module() :: module()
      def runtime_module, do: unquote(definition.runtime_module)

      @doc """
      Returns the stable public agent id.
      """
      @spec id() :: String.t()
      def id, do: unquote(definition.id)

      @doc """
      Returns the configured public agent name.
      """
      @spec name() :: String.t()
      def name, do: unquote(definition.name)

      @doc """
      Returns the configured instructions.
      """
      @spec instructions() :: Jidoka.Agent.SystemPrompt.spec()
      def instructions, do: unquote(Macro.escape(definition.configured_instructions))

      @doc """
      Returns the configured character source, if any.
      """
      @spec character() :: Jidoka.Character.source() | nil
      def character, do: unquote(Macro.escape(definition.configured_character))

      @doc false
      @spec request_transformer() :: module() | nil
      def request_transformer, do: unquote(definition.effective_request_transformer)

      @doc """
      Returns the configured model before alias resolution.
      """
      @spec configured_model() :: term()
      def configured_model, do: unquote(Macro.escape(definition.configured_model))

      @doc """
      Returns the resolved model used by the generated runtime module.
      """
      @spec model() :: term()
      def model, do: unquote(Macro.escape(definition.model))

      @doc """
      Returns the configured Zoi runtime context schema, if any.
      """
      @spec context_schema() :: Jidoka.Context.schema()
      def context_schema, do: unquote(Macro.escape(definition.context_schema))

      @doc """
      Returns the configured default runtime context for this agent.
      """
      @spec context() :: map()
      def context, do: unquote(Macro.escape(definition.context))

      @doc """
      Returns the configured structured result contract, if any.
      """
      @spec result() :: Jidoka.Output.t() | nil
      def result, do: unquote(Macro.escape(definition.result))

      @doc """
      Returns the configured structured result schema, if any.
      """
      @spec result_schema() :: Zoi.schema() | map() | nil
      def result_schema, do: unquote(Macro.escape(output_schema(definition.result)))

      @doc """
      Returns the configured structured result contract, if any.
      """
      @spec output() :: Jidoka.Output.t() | nil
      def output, do: unquote(Macro.escape(definition.output))

      @doc """
      Returns the configured structured result schema, if any.
      """
      @spec output_schema() :: Zoi.schema() | map() | nil
      def output_schema, do: unquote(Macro.escape(output_schema(definition.output)))

      @doc """
      Returns first-class schedules declared for this agent.

      Register these with `Jidoka.Schedule.Manager` or `Jidoka.schedule/2` from
      your application supervision boundary.
      """
      @spec schedules() :: [Jidoka.Schedule.t()]
      def schedules, do: unquote(Macro.escape(definition.schedules))

      @doc """
      Returns the configured compaction settings for this agent, if any.
      """
      @spec compaction() :: Jidoka.Compaction.config() | nil
      def compaction, do: unquote(Macro.escape(definition.compaction))

      @doc """
      Returns the configured memory settings for this agent, if any.
      """
      @spec memory() :: Jidoka.Memory.config() | nil
      def memory, do: unquote(Macro.escape(definition.memory))

      @doc """
      Returns the configured skill settings for this agent, if any.
      """
      @spec skills() :: Jidoka.Skill.config() | nil
      def skills, do: unquote(Macro.escape(definition.skills))

      @doc """
      Returns the configured published skill names.
      """
      @spec skill_names() :: [String.t()]
      def skill_names, do: unquote(Macro.escape(definition.skill_names))

      @doc """
      Returns the configured tool modules.
      """
      @spec tools() :: [module()]
      def tools, do: unquote(Macro.escape(definition.tools))

      @doc """
      Returns the configured published tool names.
      """
      @spec tool_names() :: [String.t()]
      def tool_names, do: unquote(Macro.escape(definition.tool_names))

      @doc """
      Returns the configured MCP tool sync settings.
      """
      @spec mcp_tools() :: Jidoka.MCP.config()
      def mcp_tools, do: unquote(Macro.escape(definition.mcp_tools))

      @doc """
      Returns the configured low-risk web capabilities.
      """
      @spec web() :: [Jidoka.Web.t()]
      def web, do: unquote(Macro.escape(definition.web))

      @doc """
      Returns the configured published web tool names.
      """
      @spec web_tool_names() :: [String.t()]
      def web_tool_names, do: unquote(Macro.escape(definition.web_tool_names))

      @doc """
      Returns the configured subagent definitions.
      """
      @spec subagents() :: [Jidoka.Subagent.t()]
      def subagents, do: unquote(Macro.escape(definition.subagents))

      @doc """
      Returns the configured published subagent names.
      """
      @spec subagent_names() :: [String.t()]
      def subagent_names, do: unquote(Macro.escape(definition.subagent_names))

      @doc """
      Returns the configured workflow capabilities.
      """
      @spec workflows() :: [Jidoka.Workflow.Capability.t()]
      def workflows, do: unquote(Macro.escape(definition.workflows))

      @doc """
      Returns the configured published workflow capability names.
      """
      @spec workflow_names() :: [String.t()]
      def workflow_names, do: unquote(Macro.escape(definition.workflow_names))

      @doc """
      Returns the configured handoff capabilities.
      """
      @spec handoffs() :: [Jidoka.Handoff.Capability.t()]
      def handoffs, do: unquote(Macro.escape(definition.handoffs))

      @doc """
      Returns the configured published handoff names.
      """
      @spec handoff_names() :: [String.t()]
      def handoff_names, do: unquote(Macro.escape(definition.handoff_names))

      @doc """
      Returns the configured Jidoka plugin modules.
      """
      @spec plugins() :: [module()]
      def plugins, do: unquote(Macro.escape(definition.plugins))

      @doc """
      Returns the configured published Jidoka plugin names.
      """
      @spec plugin_names() :: [String.t()]
      def plugin_names, do: unquote(Macro.escape(definition.plugin_names))

      @doc """
      Returns the configured hooks by stage.
      """
      @spec hooks() :: Jidoka.Hooks.stage_map()
      def hooks, do: unquote(Macro.escape(definition.hooks))

      @doc """
      Returns the configured `before_turn` hooks.
      """
      @spec before_turn_hooks() :: [term()]
      def before_turn_hooks, do: unquote(Macro.escape(definition.hooks.before_turn))

      @doc """
      Returns the configured `after_turn` hooks.
      """
      @spec after_turn_hooks() :: [term()]
      def after_turn_hooks, do: unquote(Macro.escape(definition.hooks.after_turn))

      @doc """
      Returns the configured `on_interrupt` hooks.
      """
      @spec interrupt_hooks() :: [term()]
      def interrupt_hooks, do: unquote(Macro.escape(definition.hooks.on_interrupt))

      @doc """
      Returns the configured Jidoka guardrails by stage.
      """
      @spec guardrails() :: Jidoka.Guardrails.stage_map()
      def guardrails, do: unquote(Macro.escape(definition.guardrails))

      @doc """
      Returns the configured input guardrails.
      """
      @spec input_guardrails() :: [Jidoka.Guardrails.guardrail_ref()]
      def input_guardrails, do: unquote(Macro.escape(definition.guardrails.input))

      @doc """
      Returns the configured output guardrails.
      """
      @spec output_guardrails() :: [Jidoka.Guardrails.guardrail_ref()]
      def output_guardrails, do: unquote(Macro.escape(definition.guardrails.output))

      @doc """
      Returns the configured tool guardrails.
      """
      @spec tool_guardrails() :: [Jidoka.Guardrails.guardrail_ref()]
      def tool_guardrails, do: unquote(Macro.escape(definition.guardrails.tool))

      @doc """
      Returns any Ash resources registered through `ash_resource`.
      """
      @spec ash_resources() :: [module()]
      def ash_resources, do: unquote(Macro.escape(definition.ash_resources))

      @doc """
      Returns the inferred Ash domain for `ash_resource` tools, if present.
      """
      @spec ash_domain() :: module() | nil
      def ash_domain, do: unquote(Macro.escape(definition.ash_domain))

      @doc """
      Returns whether this agent requires an explicit `context.actor`.
      """
      @spec requires_actor?() :: boolean()
      def requires_actor?, do: unquote(definition.requires_actor?)
    end
  end

  defp output_schema(%Jidoka.Output{schema: schema}), do: schema
  defp output_schema(_output), do: nil
end
