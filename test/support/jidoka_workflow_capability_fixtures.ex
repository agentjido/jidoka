defmodule JidokaTest.WorkflowCapability.AddOne do
  @moduledoc false

  use Jidoka.Tool,
    name: "workflow_capability_add_one",
    description: "Adds one to a workflow value.",
    schema: Zoi.object(%{value: Zoi.integer()})

  @impl true
  def run(%{value: value}, _context), do: {:ok, %{value: value + 1}}
end

defmodule JidokaTest.WorkflowCapability.DoubleValue do
  @moduledoc false

  use Jidoka.Tool,
    name: "workflow_capability_double_value",
    description: "Doubles a workflow value.",
    schema: Zoi.object(%{value: Zoi.integer()})

  @impl true
  def run(%{value: value}, _context), do: {:ok, %{value: value * 2}}
end

defmodule JidokaTest.WorkflowCapability.Fail do
  @moduledoc false

  use Jidoka.Tool,
    name: "workflow_capability_fail",
    description: "Fails with a caller-provided reason.",
    schema: Zoi.object(%{reason: Zoi.string()})

  @impl true
  def run(%{reason: reason}, _context), do: {:error, reason}
end

defmodule JidokaTest.WorkflowCapability.Fns do
  @moduledoc false

  def echo_context(%{topic: topic, suffix: suffix}, _context), do: {:ok, "#{topic}:#{suffix}"}
end

defmodule JidokaTest.WorkflowCapability.MathWorkflow do
  @moduledoc false

  use Jidoka.Workflow

  workflow do
    id :workflow_capability_math
    description "Adds one and doubles the result."
    input Zoi.object(%{value: Zoi.integer()})
  end

  steps do
    tool :add, JidokaTest.WorkflowCapability.AddOne, input: %{value: input(:value)}
    tool :double, JidokaTest.WorkflowCapability.DoubleValue, input: from(:add)
  end

  output from(:double)
end

defmodule JidokaTest.WorkflowCapability.ContextWorkflow do
  @moduledoc false

  use Jidoka.Workflow

  workflow do
    id :workflow_capability_context
    input Zoi.object(%{topic: Zoi.string()})
  end

  steps do
    function :echo, {JidokaTest.WorkflowCapability.Fns, :echo_context, 2},
      input: %{
        topic: input(:topic),
        suffix: context(:suffix)
      }
  end

  output from(:echo)
end

defmodule JidokaTest.WorkflowCapability.FailingWorkflow do
  @moduledoc false

  use Jidoka.Workflow

  workflow do
    id :workflow_capability_failure
    input Zoi.object(%{reason: Zoi.string()})
  end

  steps do
    tool :fail, JidokaTest.WorkflowCapability.Fail, input: %{reason: input(:reason)}
  end

  output from(:fail)
end

defmodule JidokaTest.WorkflowCapability.DuplicateNameTool do
  @moduledoc false

  use Jidoka.Tool,
    name: "workflow_capability_math",
    description: "Conflicts with the default workflow capability name.",
    schema: Zoi.object(%{value: Zoi.integer()})

  @impl true
  def run(params, _context), do: {:ok, params}
end

defmodule JidokaTest.WorkflowCapability.MathAgent do
  @moduledoc false

  use Jidoka.Agent

  agent :workflow_capability_agent do
    instructions "Use deterministic workflows for known tasks."
  end

  capabilities do
    workflow(JidokaTest.WorkflowCapability.MathWorkflow,
      as: :run_math,
      result: :structured
    )
  end
end

defmodule JidokaTest.WorkflowCapability.ContextAgent do
  @moduledoc false

  use Jidoka.Agent

  agent :workflow_context_capability_agent do
    instructions "Use deterministic workflows with forwarded context."
  end

  capabilities do
    workflow(JidokaTest.WorkflowCapability.ContextWorkflow,
      as: :context_echo,
      forward_context: {:only, [:suffix]}
    )
  end
end

defmodule JidokaTest.WorkflowCapability.FailingAgent do
  @moduledoc false

  use Jidoka.Agent

  agent :workflow_failure_capability_agent do
    instructions "Expose a failing workflow for tests."
  end

  capabilities do
    workflow(JidokaTest.WorkflowCapability.FailingWorkflow, as: :fail_workflow)
  end
end
