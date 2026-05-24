defmodule JidokaTest.WorkflowSpike.AddAmount do
  @moduledoc false

  use Jidoka.Action,
    name: "workflow_spike_add_amount",
    description: "Adds a fixed amount to a workflow value.",
    schema:
      Zoi.object(%{
        value: Zoi.integer(),
        amount: Zoi.integer() |> Zoi.default(1)
      })

  @impl true
  def run(%{value: value, amount: amount}, _context) do
    {:ok, %{value: value + amount}}
  end
end

defmodule JidokaTest.WorkflowSpike.DoubleValue do
  @moduledoc false

  use Jidoka.Action,
    name: "workflow_spike_double_value",
    description: "Doubles a workflow value.",
    schema: Zoi.object(%{value: Zoi.integer()})

  @impl true
  def run(%{value: value}, _context) do
    {:ok, %{value: value * 2}}
  end
end

defmodule JidokaTest.WorkflowSpike.Fail do
  @moduledoc false

  use Jidoka.Action,
    name: "workflow_spike_fail",
    description: "Fails with a caller-provided reason.",
    schema:
      Zoi.object(%{
        reason: Zoi.string() |> Zoi.default("intentional failure")
      })

  @impl true
  def run(%{reason: reason}, _context) do
    {:error, reason}
  end
end

defmodule JidokaTest.WorkflowSpike do
  @moduledoc false

  alias Jido.Runic.ActionNode
  alias JidokaTest.WorkflowSpike.{AddAmount, DoubleValue, Fail}
  alias Runic.Workflow

  @value_schema [value: [type: :integer, doc: "Current workflow value"]]
  @reason_schema [reason: [type: :string, doc: "Failure reason"]]

  def pipeline_workflow do
    add_node =
      action_node(AddAmount, %{amount: 1},
        name: :add_amount,
        inputs: @value_schema,
        outputs: @value_schema
      )

    double_node =
      action_node(DoubleValue, %{},
        name: :double_value,
        inputs: @value_schema,
        outputs: @value_schema
      )

    Workflow.new(name: :jidoka_workflow_spike_pipeline)
    |> Workflow.add(add_node)
    |> Workflow.add(double_node, to: :add_amount)
  end

  def failing_workflow do
    fail_node =
      action_node(Fail, %{},
        name: :fail,
        inputs: @reason_schema,
        outputs: [error: [type: :string, doc: "Failure reason"]]
      )

    Workflow.new(name: :jidoka_workflow_spike_failure)
    |> Workflow.add(fail_node)
  end

  def action_node(action_mod, params, opts) do
    {inputs, opts} = Keyword.pop(opts, :inputs)
    {outputs, opts} = Keyword.pop(opts, :outputs)

    action_mod
    |> ActionNode.new(params, opts)
    |> maybe_put(:inputs, inputs)
    |> maybe_put(:outputs, outputs)
  end

  defp maybe_put(node, _key, nil), do: node
  defp maybe_put(node, key, value), do: Map.put(node, key, value)
end

defmodule JidokaTest.WorkflowSpike.AgentServerAgent do
  @moduledoc false

  use Jido.Agent,
    name: "jidoka_workflow_spike_agent",
    description: "Test-only agent for proving Jido.Runic.Strategy inside AgentServer.",
    strategy: {Jido.Runic.Strategy, workflow_fn: &__MODULE__.build_workflow/0},
    schema: [
      status: [type: :atom, default: nil],
      value: [type: :any, default: nil]
    ]

  def build_workflow, do: JidokaTest.WorkflowSpike.pipeline_workflow()
end
