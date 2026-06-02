defmodule Jidoka.Workflow do
  @moduledoc """
  Deterministic workflow contract and DSL for Jidoka.

  Workflows are application-owned deterministic processes exposed to an agent
  as one model-callable operation. Callback workflows implement `run/2`
  directly. Declarative workflows use `workflow do`, `steps do`, and `output`
  and execute through a Runic workflow.
  """

  alias Jidoka.Schema
  alias Jidoka.Workflow.Spec

  @callback run(input :: map(), context :: map()) :: {:ok, term()} | {:error, term()} | term()
  @callback id() :: String.t()
  @callback description() :: String.t() | nil
  @callback parameters_schema() :: map() | nil

  @optional_callbacks description: 0, parameters_schema: 0

  @type definition :: Spec.t()

  @doc """
  Defines a deterministic workflow.

  Use callback form for a simple opaque operation:

      use Jidoka.Workflow, id: :my_workflow

      def run(input, context), do: {:ok, %{input: input, context: context}}

  Use DSL form for a validated multi-step workflow:

      use Jidoka.Workflow

      workflow do
        id :my_workflow
        input Zoi.object(%{value: Zoi.integer()})
      end

      steps do
        function :double, {MyApp.Fns, :double, 2}, input: %{value: input(:value)}
      end

      output from(:double)
  """
  defmacro __using__(opts \\ []) do
    if opts == [] do
      quote location: :keep do
        @behaviour Jidoka.Workflow
        @jidoka_workflow_opts []
        @jidoka_workflow_mode :dsl
        use Jidoka.Workflow.SparkDsl
        @before_compile Jidoka.Workflow
      end
    else
      quote location: :keep do
        @behaviour Jidoka.Workflow
        @jidoka_workflow_opts unquote(opts)
        @jidoka_workflow_mode :callback
        use Jidoka.Workflow.SparkDsl
        @before_compile Jidoka.Workflow
      end
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    case Module.get_attribute(env.module, :jidoka_workflow_mode) do
      :dsl ->
        env
        |> Jidoka.Workflow.Definition.build!(Module.get_attribute(env.module, :jidoka_workflow_opts) || [])
        |> Jidoka.Workflow.Codegen.emit()

      _mode ->
        reject_mixed_callback_dsl!(env.module, Module.get_attribute(env.module, :jidoka_workflow_opts) || [])
        callback_codegen(Module.get_attribute(env.module, :jidoka_workflow_opts) || [])
    end
  end

  defp reject_mixed_callback_dsl!(module, opts) do
    configured_id = Spark.Dsl.Extension.get_opt(module, [:workflow], :id)
    steps = Spark.Dsl.Extension.get_entities(module, [:steps])
    output = Spark.Dsl.Extension.get_opt(module, [:workflow_output], :output)

    unless is_nil(configured_id) and steps == [] and is_nil(output) do
      raise Jidoka.Workflow.Dsl.Error.exception(
              message: "Jidoka.Workflow cannot mix callback options with the workflow DSL.",
              path: [:workflow],
              value: opts,
              hint:
                "Use either `use Jidoka.Workflow, id: ...` with `run/2`, or `use Jidoka.Workflow` with `workflow do ... end`.",
              module: module
            )
    end
  end

  defp callback_codegen(opts) do
    quote location: :keep do
      @impl Jidoka.Workflow
      def id do
        Jidoka.Workflow.normalize_id!(
          Keyword.get(unquote(Macro.escape(opts)), :id) ||
            Keyword.get(unquote(Macro.escape(opts)), :name) ||
            __MODULE__
        )
      end

      @impl Jidoka.Workflow
      def description do
        Keyword.get(unquote(Macro.escape(opts)), :description)
      end

      @impl Jidoka.Workflow
      def parameters_schema do
        Keyword.get(unquote(Macro.escape(opts)), :parameters_schema) ||
          Keyword.get(unquote(Macro.escape(opts)), :input_schema)
      end

      @doc false
      def __jidoka_workflow__ do
        Jidoka.Workflow.callback_spec!(
          __MODULE__,
          id: id(),
          description: description(),
          parameters_schema: parameters_schema()
        )
      end

      defoverridable id: 0, description: 0, parameters_schema: 0
    end
  end

  @doc false
  @spec callback_spec!(module(), keyword()) :: Spec.t()
  def callback_spec!(workflow_module, opts) when is_atom(workflow_module) and is_list(opts) do
    Spec.new!(
      id: Keyword.fetch!(opts, :id),
      module: workflow_module,
      description: Keyword.get(opts, :description),
      mode: :callback,
      parameters_schema: Keyword.get(opts, :parameters_schema),
      metadata: %{}
    )
  end

  @doc "Returns the normalized workflow definition for a workflow module."
  @spec definition(module()) :: {:ok, definition()} | {:error, term()}
  def definition(workflow_module) when is_atom(workflow_module) do
    with {:module, _module} <- Code.ensure_compiled(workflow_module),
         {:ok, spec} <- workflow_spec(workflow_module),
         :ok <- validate_runnable(workflow_module, spec) do
      {:ok, spec}
    else
      {:error, reason} -> {:error, {:invalid_workflow_module, workflow_module, reason}}
    end
  end

  def definition(workflow_module), do: {:error, {:invalid_workflow_module, workflow_module}}

  @doc "Returns a workflow definition or raises when the workflow module is invalid."
  @spec definition!(module()) :: definition()
  def definition!(workflow_module) do
    case definition(workflow_module) do
      {:ok, definition} -> definition
      {:error, reason} -> raise ArgumentError, "invalid workflow: #{inspect(reason)}"
    end
  end

  @doc "Runs a workflow with normalized map input and optional context."
  @spec run(module(), map() | keyword(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(workflow_module, input, opts \\ []) when is_atom(workflow_module) and is_list(opts) do
    with {:ok, spec} <- definition(workflow_module) do
      run_spec(spec, input, opts)
    end
  end

  defp run_spec(%Spec{mode: :dsl} = spec, input, opts) do
    Jidoka.Workflow.Runtime.run(spec, input, opts)
  end

  defp run_spec(%Spec{mode: :callback} = spec, input, opts) do
    with {:ok, input} <- normalize_input(input),
         {:ok, context} <- normalize_context(Keyword.get(opts, :context, %{})) do
      case apply(spec.module, :run, [input, context]) do
        {:ok, output} -> {:ok, output}
        {:error, reason} -> {:error, reason}
        output -> {:ok, output}
      end
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  @spec normalize_id(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize_id(id) when is_atom(id) and not is_nil(id) do
    case Atom.to_string(id) do
      "Elixir." <> _module ->
        id
        |> Module.split()
        |> List.last()
        |> Macro.underscore()
        |> normalize_id()

      atom ->
        normalize_id(atom)
    end
  end

  def normalize_id(id) when is_binary(id) do
    id = String.trim(id)

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, id) do
      {:ok, id}
    else
      {:error, {:invalid_workflow_id, id}}
    end
  end

  def normalize_id(id), do: {:error, {:invalid_workflow_id, id}}

  @doc false
  @spec normalize_id!(term()) :: String.t()
  def normalize_id!(id) do
    case normalize_id(id) do
      {:ok, id} -> id
      {:error, reason} -> raise ArgumentError, "invalid workflow id: #{inspect(reason)}"
    end
  end

  defp workflow_spec(workflow_module) do
    cond do
      function_exported?(workflow_module, :__jidoka_workflow__, 0) ->
        case apply(workflow_module, :__jidoka_workflow__, []) do
          %Spec{} = spec -> {:ok, spec}
          other -> {:error, {:invalid_workflow_spec, other}}
        end

      function_exported?(workflow_module, :run, 2) ->
        callback_spec_from_functions(workflow_module)

      true ->
        {:error, :missing_run}
    end
  end

  defp callback_spec_from_functions(workflow_module) do
    with {:ok, id} <- normalize_id(workflow_id(workflow_module)),
         {:ok, description} <- normalize_description(workflow_description(workflow_module)),
         {:ok, parameters_schema} <- normalize_parameters_schema(parameters_schema(workflow_module)) do
      {:ok,
       Spec.new!(
         id: id,
         module: workflow_module,
         description: description,
         mode: :callback,
         parameters_schema: parameters_schema
       )}
    end
  end

  defp validate_runnable(workflow_module, %Spec{mode: :callback}) do
    if function_exported?(workflow_module, :run, 2), do: :ok, else: {:error, :missing_run}
  end

  defp validate_runnable(_workflow_module, %Spec{mode: :dsl}), do: :ok

  defp workflow_id(module) do
    if function_exported?(module, :id, 0), do: apply(module, :id, []), else: module
  end

  defp workflow_description(module) do
    if function_exported?(module, :description, 0), do: apply(module, :description, []), else: nil
  end

  defp parameters_schema(module) do
    if function_exported?(module, :parameters_schema, 0) do
      apply(module, :parameters_schema, [])
    end
  end

  defp normalize_description(nil), do: {:ok, nil}

  defp normalize_description(description) when is_binary(description) do
    case String.trim(description) do
      "" -> {:ok, nil}
      description -> {:ok, description}
    end
  end

  defp normalize_description(description),
    do: {:error, {:invalid_workflow_description, description}}

  defp normalize_parameters_schema(nil), do: {:ok, nil}
  defp normalize_parameters_schema(schema) when is_map(schema), do: {:ok, schema}

  defp normalize_parameters_schema(schema),
    do: {:error, {:invalid_workflow_parameters_schema, schema}}

  defp normalize_input(input) when is_list(input), do: {:ok, Map.new(input)}
  defp normalize_input(input) when is_map(input), do: {:ok, Schema.normalize_attrs(input)}
  defp normalize_input(input), do: {:error, {:invalid_workflow_input, input}}

  defp normalize_context(context) when is_list(context), do: {:ok, Map.new(context)}
  defp normalize_context(context) when is_map(context), do: {:ok, context}
  defp normalize_context(context), do: {:error, {:invalid_workflow_context, context}}
end
