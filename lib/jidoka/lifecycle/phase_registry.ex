defmodule Jidoka.Lifecycle.PhaseRegistry do
  @moduledoc false

  alias Jidoka.Lifecycle.{Config, Foundation, Phase, PhaseSpec}

  @type before_fun :: Foundation.before_fun()
  @type after_fun :: Foundation.after_fun()

  @spec before_phases(module(), Config.t(), before_fun()) :: [Phase.t()]
  def before_phases(runtime_module, %Config{} = config, super_fun)
      when is_atom(runtime_module) and is_function(super_fun, 2) do
    runtime_module
    |> before_phase_specs(config, super_fun)
    |> PhaseSpec.compile_all()
  end

  @spec after_phases(module(), Config.t(), after_fun()) :: [Phase.t()]
  def after_phases(runtime_module, %Config{} = config, super_fun)
      when is_atom(runtime_module) and is_function(super_fun, 3) do
    runtime_module
    |> after_phase_specs(config, super_fun)
    |> PhaseSpec.compile_all()
  end

  @spec before_phase_specs(module(), Config.t(), before_fun()) :: [PhaseSpec.t()]
  def before_phase_specs(runtime_module, %Config{} = config, super_fun) do
    Foundation.before_phase_specs(super_fun) ++
      Jidoka.Compaction.before_phase_specs(config.compaction, config.context) ++
      Jidoka.Memory.before_phase_specs(config.memory, config.context) ++
      Jidoka.Hooks.before_phase_specs(runtime_module, config.hooks, config.context, config.timeouts.hooks) ++
      Jidoka.Output.before_phase_specs(config.output) ++
      Jidoka.Skill.before_phase_specs(config.skills) ++
      Jidoka.Guardrails.before_phase_specs(config.guardrails, config.timeouts.controls) ++
      Jidoka.MCP.before_phase_specs(config.mcp_tools) ++
      Jidoka.Subagent.before_phase_specs() ++
      Jidoka.Handoff.Capability.before_phase_specs()
  end

  @spec after_phase_specs(module(), Config.t(), after_fun()) :: [PhaseSpec.t()]
  def after_phase_specs(runtime_module, %Config{} = config, super_fun) do
    Foundation.after_phase_specs(super_fun) ++
      Jidoka.Hooks.after_phase_specs(runtime_module, config.hooks, config.timeouts.hooks) ++
      Jidoka.Output.after_phase_specs(config.output) ++
      Jidoka.Guardrails.after_phase_specs(config.guardrails, config.timeouts.controls) ++
      Jidoka.Memory.after_phase_specs(config.memory) ++
      Jidoka.Subagent.after_phase_specs() ++
      Jidoka.Workflow.Capability.after_phase_specs() ++
      Jidoka.Handoff.Capability.after_phase_specs()
  end
end
