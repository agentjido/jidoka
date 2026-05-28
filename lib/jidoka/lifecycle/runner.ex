defmodule Jidoka.Lifecycle.Runner do
  @moduledoc false

  alias Jidoka.Lifecycle.{Config, Graph, Phase, State}
  alias Runic.Workflow

  @type before_fun :: (Jido.Agent.t(), term() -> {:ok, Jido.Agent.t(), term()} | term())
  @type after_fun :: (Jido.Agent.t(), term(), [term()] -> {:ok, Jido.Agent.t(), [term()]} | term())

  @spec run_before(module(), Jido.Agent.t(), term(), Config.t(), before_fun()) ::
          {:ok, Jido.Agent.t(), term()} | term()
  def run_before(runtime_module, agent, action, %Config{} = config, super_fun)
      when is_atom(runtime_module) and is_function(super_fun, 2) do
    phases = before_phases(runtime_module, config, super_fun)
    state = State.new!(agent: agent, action: action)

    phases
    |> run_phases(state, :jidoka_before_lifecycle)
    |> before_result()
  end

  @spec run_after(module(), Jido.Agent.t(), term(), [term()], Config.t(), after_fun()) ::
          {:ok, Jido.Agent.t(), [term()]} | term()
  def run_after(runtime_module, agent, action, directives, %Config{} = config, super_fun)
      when is_atom(runtime_module) and is_list(directives) and is_function(super_fun, 3) do
    phases = after_phases(runtime_module, config, super_fun)
    state = State.new!(agent: agent, action: action, directives: directives)

    phases
    |> run_phases(state, :jidoka_after_lifecycle)
    |> after_result()
  end

  @doc false
  @spec run_phases([Phase.t()], State.t(), atom()) :: State.t()
  def run_phases([], %State{} = state, _name), do: state

  def run_phases(phases, %State{} = state, name) when is_list(phases) and is_atom(name) do
    # Run each phase through its own bounded workflow. A single open-ended
    # workflow can re-match generic lifecycle state facts against earlier phases.
    Enum.reduce_while(phases, state, fn %Phase{} = phase, %State{} = state ->
      next_state = run_phase_workflow(phase, state, name)

      case next_state do
        %State{status: :halt} -> {:halt, next_state}
        %State{} -> {:cont, next_state}
      end
    end)
  end

  @doc false
  @spec before_phases(module(), Config.t(), before_fun()) :: [Phase.t()]
  def before_phases(runtime_module, %Config{} = config, super_fun)
      when is_atom(runtime_module) and is_function(super_fun, 2) do
    [
      before_phase(:jido_ai_before, :jido_ai, super_fun),
      before_phase(:compaction_before, :compaction, fn agent, action ->
        Jidoka.Compaction.on_before_cmd(agent, action, config.compaction, config.context)
      end),
      before_phase(:memory_before, :memory, fn agent, action ->
        Jidoka.Memory.on_before_cmd(agent, action, config.memory, config.context)
      end),
      before_phase(:hooks_before, :hooks, fn agent, action ->
        Jidoka.Hooks.on_before_cmd(runtime_module, agent, action, config.hooks, config.context)
      end),
      before_phase(:output_before, :output, fn agent, action ->
        Jidoka.Output.on_before_cmd(agent, action, config.output)
      end),
      before_phase(:skills_before, :skills, fn agent, action ->
        Jidoka.Skill.on_before_cmd(agent, action, config.skills)
      end),
      before_phase(:controls_before, :controls, fn agent, action ->
        Jidoka.Guardrails.on_before_cmd(agent, action, config.guardrails)
      end),
      before_phase(:mcp_before, :mcp, fn agent, action ->
        Jidoka.MCP.on_before_cmd(agent, action, config.mcp_tools)
      end),
      before_phase(:subagent_before, :subagent, &Jidoka.Subagent.on_before_cmd/2),
      before_phase(:handoff_before, :handoff, &Jidoka.Handoff.Capability.on_before_cmd/2)
    ]
  end

  @doc false
  @spec after_phases(module(), Config.t(), after_fun()) :: [Phase.t()]
  def after_phases(runtime_module, %Config{} = config, super_fun)
      when is_atom(runtime_module) and is_function(super_fun, 3) do
    [
      after_phase(:jido_ai_after, :jido_ai, super_fun),
      after_phase(:hooks_after, :hooks, fn agent, action, directives ->
        Jidoka.Hooks.on_after_cmd(runtime_module, agent, action, directives, config.hooks)
      end),
      after_phase(:output_after, :output, fn agent, action, directives ->
        Jidoka.Output.on_after_cmd(agent, action, directives, config.output)
      end),
      after_phase(:controls_after, :controls, fn agent, action, directives ->
        Jidoka.Guardrails.on_after_cmd(agent, action, directives, config.guardrails)
      end),
      after_phase(:memory_after, :memory, fn agent, action, directives ->
        Jidoka.Memory.on_after_cmd(agent, action, directives, config.memory)
      end),
      after_phase(:subagent_after, :subagent, &Jidoka.Subagent.on_after_cmd/3),
      after_phase(:workflow_after, :workflow, &Jidoka.Workflow.Capability.on_after_cmd/3),
      after_phase(:handoff_after, :handoff, &Jidoka.Handoff.Capability.on_after_cmd/3)
    ]
  end

  defp before_phase(name, feature, fun) do
    Phase.new!(
      name: name,
      stage: :before,
      feature: feature,
      runner: fn %State{} = state ->
        case fun.(state.agent, state.action) do
          {:ok, agent, action} -> {:ok, State.put_agent_action(state, agent, action)}
          other -> {:halt, other}
        end
      end
    )
  end

  defp after_phase(name, feature, fun) do
    Phase.new!(
      name: name,
      stage: :after,
      feature: feature,
      runner: fn %State{} = state ->
        case fun.(state.agent, state.action, state.directives) do
          {:ok, agent, directives} -> {:ok, State.put_agent_directives(state, agent, directives)}
          other -> {:halt, other}
        end
      end
    )
  end

  defp before_result(%State{status: :halt, result: result}), do: result
  defp before_result(%State{agent: agent, action: action}), do: {:ok, agent, action}

  defp after_result(%State{status: :halt, result: result}), do: result
  defp after_result(%State{agent: agent, directives: directives}), do: {:ok, agent, directives}

  defp run_phase_workflow(%Phase{} = phase, %State{} = state, name) do
    workflow_name = :"#{name}_#{phase.name}"

    workflow =
      [phase]
      |> Graph.build(name: workflow_name)
      |> Workflow.react(state)

    workflow
    |> Workflow.raw_productions(phase.name)
    |> List.last()
    |> case do
      %State{} = state -> Phase.raise_if_failed(state)
      other -> State.halt(state, {:error, {:invalid_lifecycle_result, other}})
    end
  end
end
