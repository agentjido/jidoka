defmodule Jidoka.Lifecycle.Graph do
  @moduledoc false

  require Runic

  alias Jidoka.Lifecycle.Phase
  alias Runic.Workflow

  @spec build([Phase.t()], keyword()) :: Workflow.t()
  def build(phases, opts \\ []) when is_list(phases) do
    name = Keyword.get(opts, :name, :jidoka_lifecycle)

    phases
    |> Enum.reduce({Workflow.new(name: name), nil}, fn %Phase{} = phase, {workflow, previous} ->
      step = phase_step(phase)

      workflow =
        case previous do
          nil -> Workflow.add(workflow, step, validate: :off)
          previous -> Workflow.add(workflow, step, to: previous, validate: :off)
        end

      {workflow, phase.name}
    end)
    |> elem(0)
  end

  @spec phase_names([Phase.t()]) :: [atom()]
  def phase_names(phases) when is_list(phases), do: Enum.map(phases, & &1.name)

  defp phase_step(%Phase{} = phase) do
    Runic.step(fn state -> Phase.run(phase, state) end, name: phase.name)
  end
end
