defmodule Jidoka.Lifecycle.Runner do
  @moduledoc false

  alias Jidoka.Lifecycle.{Config, Graph, Phase, PhaseRegistry, State}
  alias Runic.Workflow

  @type before_fun :: (Jido.Agent.t(), term() -> {:ok, Jido.Agent.t(), term()} | term())
  @type after_fun :: (Jido.Agent.t(), term(), [term()] -> {:ok, Jido.Agent.t(), [term()]} | term())

  @spec run_before(module(), Jido.Agent.t(), term(), Config.t(), before_fun()) ::
          {:ok, Jido.Agent.t(), term()} | term()
  def run_before(runtime_module, agent, action, %Config{} = config, super_fun)
      when is_atom(runtime_module) and is_function(super_fun, 2) do
    phases = PhaseRegistry.before_phases(runtime_module, config, super_fun)
    state = State.new!(agent: agent, action: action)

    phases
    |> run_phases(state, :jidoka_before_lifecycle)
    |> before_result()
  end

  @spec run_after(module(), Jido.Agent.t(), term(), [term()], Config.t(), after_fun()) ::
          {:ok, Jido.Agent.t(), [term()]} | term()
  def run_after(runtime_module, agent, action, directives, %Config{} = config, super_fun)
      when is_atom(runtime_module) and is_list(directives) and is_function(super_fun, 3) do
    phases = PhaseRegistry.after_phases(runtime_module, config, super_fun)
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
