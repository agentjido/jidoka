defmodule Jidoka.Agent.Runtime do
  @moduledoc false

  @spec hook_runtime_ast(
          Jidoka.Hooks.stage_map(),
          map(),
          Jidoka.Guardrails.stage_map(),
          Jidoka.Compaction.config() | nil,
          Jidoka.Memory.config() | nil,
          Jidoka.Output.t() | nil,
          Jidoka.Skill.config() | nil,
          Jidoka.MCP.config(),
          Jidoka.Lifecycle.Timeouts.t()
        ) :: Macro.t()
  def hook_runtime_ast(
        default_hooks,
        default_context \\ %{},
        default_guardrails \\ Jidoka.Guardrails.default_stage_map(),
        default_compaction \\ nil,
        default_memory \\ nil,
        default_output \\ nil,
        default_skills \\ nil,
        default_mcp_tools \\ [],
        default_timeouts \\ Jidoka.Lifecycle.Timeouts.default()
      ) do
    lifecycle_config =
      Jidoka.Lifecycle.Config.new!(
        hooks: default_hooks,
        context: default_context,
        guardrails: default_guardrails,
        timeouts: default_timeouts,
        compaction: default_compaction,
        memory: default_memory,
        output: default_output,
        skills: default_skills,
        mcp_tools: default_mcp_tools
      )

    quote location: :keep do
      @jidoka_lifecycle_config unquote(Macro.escape(lifecycle_config))

      @impl true
      def on_before_cmd(agent, action) do
        Jidoka.Lifecycle.Runner.run_before(
          __MODULE__,
          agent,
          action,
          @jidoka_lifecycle_config,
          fn agent, action -> super(agent, action) end
        )
      end

      @impl true
      def on_after_cmd(agent, action, directives) do
        Jidoka.Lifecycle.Runner.run_after(
          __MODULE__,
          agent,
          action,
          directives,
          @jidoka_lifecycle_config,
          fn agent, action, directives -> super(agent, action, directives) end
        )
      end
    end
  end

  @spec runtime_plugins([module()], Jidoka.Memory.config() | nil) :: [module() | {module(), map()}]
  def runtime_plugins(plugin_modules, _memory_config), do: [Jidoka.Plugins.RuntimeCompat | plugin_modules]
end
