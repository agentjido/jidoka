defmodule JidokaTest.Workflow.AddAmount do
  @moduledoc false

  use Jidoka.Action,
    name: "workflow_add_amount",
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

defmodule JidokaTest.Workflow.DoubleValue do
  @moduledoc false

  use Jidoka.Action,
    name: "workflow_double_value",
    description: "Doubles a workflow value.",
    schema: Zoi.object(%{value: Zoi.integer()})

  @impl true
  def run(%{value: value}, _context) do
    {:ok, %{value: value * 2}}
  end
end

defmodule JidokaTest.Workflow.Fail do
  @moduledoc false

  use Jidoka.Action,
    name: "workflow_fail",
    description: "Fails with a caller-provided reason.",
    schema: Zoi.object(%{reason: Zoi.string()})

  @impl true
  def run(%{reason: reason}, _context) do
    {:error, reason}
  end
end

defmodule JidokaTest.Workflow.Fns do
  @moduledoc false

  def normalize(%{topic: topic, suffix: suffix}, _context) do
    {:ok, %{prompt: "#{topic}:#{suffix}"}}
  end

  def build_prompt(%{topic: topic}, _context) do
    {:ok, %{prompt: "draft #{topic}"}}
  end

  def record_step(%{label: label, value: value, notify_pid: notify_pid}, _context) do
    send(notify_pid, {:workflow_step, label, value})
    {:ok, %{value: value + 1}}
  end
end

defmodule JidokaTest.Workflow.EchoAgent do
  @moduledoc false

  defmodule Runtime do
    @moduledoc false

    use Jido.Agent,
      name: "workflow_echo_agent_runtime",
      schema: Zoi.object(%{})
  end

  def start_link(opts \\ []), do: Jidoka.start_agent(Runtime, opts)

  def chat(_pid, message, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    topic = Map.get(context, :topic, Map.get(context, "topic", "none"))
    {:ok, "echo:#{message}:topic=#{topic}"}
  end
end

defmodule JidokaTest.Workflow.ToolOnlyWorkflow do
  @moduledoc false

  use Jidoka.Workflow

  alias JidokaTest.Workflow.{AddAmount, DoubleValue}

  workflow do
    id :tool_only_workflow
    description("Adds and doubles a value.")
    input Zoi.object(%{value: Zoi.integer()})
  end

  steps do
    action(:add, AddAmount,
      input: %{
        value: input(:value),
        amount: value(1)
      }
    )

    action(:double, DoubleValue, input: from(:add))
  end

  output from(:double)
end

defmodule JidokaTest.Workflow.OrderedWorkflow do
  @moduledoc false

  use Jidoka.Workflow

  workflow do
    id :ordered_workflow
    input Zoi.object(%{value: Zoi.integer()})
  end

  steps do
    function :first, {JidokaTest.Workflow.Fns, :record_step, 2},
      input: %{
        label: value(:first),
        value: input(:value),
        notify_pid: context(:notify_pid)
      }

    function :second, {JidokaTest.Workflow.Fns, :record_step, 2},
      input: %{
        label: value(:second),
        value: from(:first, :value),
        notify_pid: context(:notify_pid)
      }
  end

  output from(:second)
end

defmodule JidokaTest.Workflow.FunctionWorkflow do
  @moduledoc false

  use Jidoka.Workflow

  workflow do
    id :function_workflow
    input Zoi.object(%{topic: Zoi.string()})
  end

  steps do
    function :normalize, {JidokaTest.Workflow.Fns, :normalize, 2},
      input: %{
        topic: input(:topic),
        suffix: context(:suffix)
      }
  end

  output from(:normalize, :prompt)
end

defmodule JidokaTest.Workflow.AgentWorkflow do
  @moduledoc false

  use Jidoka.Workflow

  workflow do
    id :agent_workflow
    input Zoi.object(%{topic: Zoi.string()})
  end

  steps do
    function :build_prompt, {JidokaTest.Workflow.Fns, :build_prompt, 2}, input: %{topic: input(:topic)}

    agent :draft, JidokaTest.Workflow.EchoAgent,
      prompt: from(:build_prompt, :prompt),
      context: %{topic: input(:topic)}
  end

  output from(:draft)
end

defmodule JidokaTest.Workflow.ImportedAgentWorkflow do
  @moduledoc false

  use Jidoka.Workflow

  workflow do
    id :imported_agent_workflow
    input Zoi.object(%{topic: Zoi.string()})
  end

  steps do
    agent :review, {:imported, :reviewer},
      prompt: value("review draft"),
      context: %{topic: input(:topic)}
  end

  output from(:review)
end

defmodule JidokaTest.Workflow.FailingWorkflow do
  @moduledoc false

  use Jidoka.Workflow

  workflow do
    id :failing_workflow
    input Zoi.object(%{reason: Zoi.string()})
  end

  steps do
    action(:fail, JidokaTest.Workflow.Fail, input: %{reason: input(:reason)})
  end

  output from(:fail)
end
