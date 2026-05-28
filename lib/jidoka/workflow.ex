defmodule Jidoka.Workflow do
  @moduledoc """
  Spark-backed workflow DSL and runtime facade for Jidoka.

  `Jidoka.Workflow` compiles a small public workflow DSL into an internal
  execution graph. Public code describes inputs, steps, and output wiring;
  Jidoka keeps graph facts, directives, and strategy internals behind the
  runtime.

  Workflows are deterministic application processes. They can be run directly
  with `run/3`, used by schedules, or exposed to an agent as a model-callable
  operation with `tools do workflow MyWorkflow end`. In that agent case Jidoka
  generates an action-backed tool module for the workflow, so the model sees
  one operation while the workflow runtime owns the ordered steps.

  Workflow authoring stays separate from `Jidoka.Action`. Use actions for one
  deterministic operation. Use workflows when Jidoka should understand the
  ordered steps, data dependencies, context refs, and final output selection.
  """

  @doc """
  Runs a compiled Jidoka workflow module.
  """
  @spec run(module(), map() | keyword(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(workflow_module, input, opts \\ []) when is_atom(workflow_module) and is_list(opts) do
    with {:ok, definition} <- definition(workflow_module) do
      Jidoka.Workflow.Runtime.run(definition, input, opts)
    end
  end

  @doc """
  Returns Jidoka's inspection view of a compiled workflow definition.
  """
  @spec inspect_workflow(module()) :: {:ok, map()} | {:error, term()}
  def inspect_workflow(workflow_module) when is_atom(workflow_module) do
    with {:ok, definition} <- definition(workflow_module) do
      {:ok, Jidoka.Workflow.Runtime.inspect_definition(definition)}
    end
  end

  @doc false
  @spec definition(module()) :: {:ok, map()} | {:error, term()}
  def definition(workflow_module) when is_atom(workflow_module) do
    case Code.ensure_compiled(workflow_module) do
      {:module, ^workflow_module} ->
        workflow_definition(workflow_module)

      {:error, reason} ->
        {:error,
         Jidoka.Error.config_error("Module is not a Jidoka workflow.",
           field: :workflow,
           value: workflow_module,
           details: %{module: workflow_module, reason: reason}
         )}
    end
  end

  defp workflow_definition(workflow_module) do
    if function_exported?(workflow_module, :__jidoka__, 0) do
      case workflow_module.__jidoka__() do
        %{kind: :workflow_definition} = definition ->
          {:ok, definition}

        _other ->
          not_workflow_error(workflow_module)
      end
    else
      not_workflow_error(workflow_module)
    end
  end

  defp not_workflow_error(workflow_module) do
    {:error,
     Jidoka.Error.config_error("Module is not a Jidoka workflow.",
       field: :workflow,
       value: workflow_module,
       details: %{module: workflow_module, reason: :not_jidoka_workflow}
     )}
  end

  defmacro __using__(opts \\ []) do
    if opts != [] do
      raise CompileError,
        file: __CALLER__.file,
        line: __CALLER__.line,
        description:
          "Jidoka.Workflow uses a Spark DSL. Use `use Jidoka.Workflow` and configure it inside `workflow do ... end`."
    end

    quote location: :keep do
      use Jidoka.Workflow.SparkDsl

      @before_compile Jidoka.Workflow
    end
  end

  defmacro __before_compile__(env) do
    Jidoka.Workflow.Build.before_compile(env)
  end
end
