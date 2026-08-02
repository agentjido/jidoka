defmodule Jidoka.Adapter.Runic.TurnCompiler do
  @moduledoc "Compiles `Jidoka.Turn.Plan` data into small Runic workflows."

  require Runic

  alias Jidoka.Turn
  alias Jidoka.Runtime.Spine.Steps
  alias Runic.Workflow

  @doc "Compiles a turn plan into the pure Runic model-turn workflow."
  @spec model_turn_workflow(Turn.Plan.t()) :: Workflow.t()
  def model_turn_workflow(%Turn.Plan{} = _plan) do
    assemble_prompt =
      Runic.step(&Steps.assemble_prompt/1,
        name: :assemble_prompt
      )

    plan_model_effect =
      Runic.step(&Steps.plan_model_effect/1,
        name: :plan_model_effect
      )

    Workflow.new(name: :jidoka_model_turn)
    |> Workflow.add(assemble_prompt)
    |> Workflow.add(plan_model_effect, to: :assemble_prompt)
  end

  @doc "Runs the model-turn workflow and returns its planned turn state."
  @spec run_model_turn(Turn.Plan.t(), Turn.State.t()) :: Turn.State.t() | nil
  def run_model_turn(%Turn.Plan{} = plan, %Turn.State{} = state) do
    plan
    |> model_turn_workflow()
    |> Workflow.react_until_satisfied(state)
    |> Workflow.raw_productions(:plan_model_effect)
    |> Enum.filter(&match?(%Turn.State{}, &1))
    |> List.last()
  end
end
