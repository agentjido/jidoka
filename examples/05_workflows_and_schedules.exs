Mix.Task.run("app.start")

defmodule JidokaExamples.Workflows.AddOne do
  use Jidoka.Action,
    name: "example_add_one",
    description: "Adds one to the input value.",
    schema: Zoi.object(%{value: Zoi.integer()})

  @impl true
  def run(%{value: value}, _context), do: {:ok, %{value: value + 1}}
end

defmodule JidokaExamples.Workflows.DoubleValue do
  use Jidoka.Action,
    name: "example_double_value",
    description: "Doubles the input value.",
    schema: Zoi.object(%{value: Zoi.integer()})

  @impl true
  def run(%{value: value}, _context), do: {:ok, %{value: value * 2}}
end

defmodule JidokaExamples.Workflows.MathWorkflow do
  use Jidoka.Workflow

  workflow do
    id :example_math_workflow
    description "Adds one and doubles the result."
    input Zoi.object(%{value: Zoi.integer()})
  end

  steps do
    action(:add_one, JidokaExamples.Workflows.AddOne, input: %{value: input(:value)})
    action(:double, JidokaExamples.Workflows.DoubleValue, input: from(:add_one))
  end

  output from(:double)
end

defmodule JidokaExamples.Workflows.MathAgent do
  use Jidoka.Agent

  agent :example_workflow_agent do
    model :fast
    instructions "Use the workflow tool when arithmetic needs deterministic execution."
  end

  capabilities do
    workflow(JidokaExamples.Workflows.MathWorkflow,
      as: :run_math,
      result: :structured
    )
  end
end

alias JidokaExamples.Workflows.{MathAgent, MathWorkflow}

{:ok, workflow_result} = MathWorkflow.run(%{value: 3})

schedule_id = "example-math-#{System.unique_integer([:positive])}"

{:ok, _schedule} =
  Jidoka.schedule_workflow(MathWorkflow,
    id: schedule_id,
    cron: "0 9 * * *",
    input: %{value: 5},
    enabled?: false
  )

{:ok, scheduled_run} = Jidoka.run_schedule(schedule_id)

IO.inspect(
  %{
    workflow_result: workflow_result,
    agent_tool_names: MathAgent.tool_names(),
    scheduled_result: scheduled_run.result
  },
  label: "workflows_and_schedules"
)

Jidoka.cancel_schedule(schedule_id)
