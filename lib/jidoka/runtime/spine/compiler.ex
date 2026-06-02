defmodule Jidoka.Runtime.Spine.Compiler do
  @moduledoc "Compiles `Jidoka.Turn.Plan` data into small Runic workflows."

  require Runic

  alias Jidoka.Turn
  alias Jidoka.Runtime.Spine.Steps
  alias Runic.Workflow

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
end
