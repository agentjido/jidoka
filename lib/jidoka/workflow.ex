defmodule Jidoka.Workflow do
  @moduledoc """
  Deterministic workflow contract and DSL for Jidoka.

  Workflows are application-owned deterministic processes exposed to an agent
  as one model-callable operation. Callback workflows implement `run/2`
  directly. Declarative workflows use `workflow do`, `steps do`, and `output`
  and execute through a Runic workflow.
  """

  alias Jidoka.Schema
  alias Jidoka.Workflow.Resolver
  alias Jidoka.Workflow.Spec

  @doc "Runs a callback workflow with normalized input and runtime context."
  @callback run(input :: map(), context :: map()) :: {:ok, term()} | {:error, term()} | term()

  @doc "Returns the stable workflow identifier."
  @callback id() :: String.t()

  @doc "Returns the optional description shown to the model."
  @callback description() :: String.t() | nil

  @doc "Returns the optional JSON-compatible input schema."
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
  @spec __using__(keyword()) :: Macro.t()
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
  @spec __before_compile__(Macro.Env.t()) :: Macro.t()
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
      @spec id() :: String.t()
      def id do
        Jidoka.Workflow.normalize_id!(
          Keyword.get(unquote(Macro.escape(opts)), :id) ||
            Keyword.get(unquote(Macro.escape(opts)), :name) ||
            __MODULE__
        )
      end

      @impl Jidoka.Workflow
      @spec description() :: String.t() | nil
      def description do
        Keyword.get(unquote(Macro.escape(opts)), :description)
      end

      @impl Jidoka.Workflow
      @spec parameters_schema() :: map() | nil
      def parameters_schema do
        Keyword.get(unquote(Macro.escape(opts)), :parameters_schema) ||
          Keyword.get(unquote(Macro.escape(opts)), :input_schema)
      end

      @doc false
      @spec __jidoka_workflow__() :: Jidoka.Workflow.Spec.t()
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
  def definition(workflow_module), do: Resolver.definition(workflow_module)

  @doc "Returns a workflow definition or raises when the workflow module is invalid."
  @spec definition!(module()) :: definition()
  def definition!(workflow_module), do: Resolver.definition!(workflow_module)

  @doc """
  Runs a workflow with normalized map input.

  Options:

  * `:context` - runtime context passed to workflow functions, actions, and agent steps.
  * `:timeout` - total workflow wall-clock timeout in milliseconds.
  * `:async` - when `true`, independent workflow steps may execute concurrently.
  * `:max_concurrency` - maximum concurrent workflow steps when `:async` is enabled.
  * `:agent_opts` - options forwarded to nested agent steps.
  """
  @spec run(module(), map() | keyword(), keyword()) ::
          {:ok, term()} | {:hibernate, Jidoka.Workflow.Snapshot.t()} | {:error, term()}
  def run(workflow_module, input, opts \\ []) when is_atom(workflow_module) and is_list(opts) do
    with {:ok, spec} <- definition(workflow_module) do
      run_spec(spec, input, opts)
    end
  end

  defp run_spec(%Spec{mode: :dsl} = spec, input, opts) do
    Jidoka.Adapter.Runic.Workflow.run(spec, input, opts)
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

  @doc "Resumes a declarative workflow from a serialized or decoded snapshot."
  @spec resume(Jidoka.Workflow.Snapshot.t() | binary(), keyword()) ::
          {:ok, term()} | {:hibernate, Jidoka.Workflow.Snapshot.t()} | {:error, term()}
  def resume(snapshot, opts \\ []) when is_list(opts) do
    with {:ok, snapshot} <- normalize_snapshot(snapshot) do
      Jidoka.Adapter.Runic.Workflow.resume(snapshot, opts)
    end
  end

  defp normalize_snapshot(%Jidoka.Workflow.Snapshot{} = snapshot),
    do: Jidoka.Workflow.Snapshot.normalize(snapshot)

  defp normalize_snapshot(binary) when is_binary(binary), do: Jidoka.Workflow.Snapshot.deserialize(binary)
  defp normalize_snapshot(other), do: {:error, {:invalid_workflow_snapshot, other}}

  @doc false
  @spec normalize_id(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize_id(id), do: Resolver.normalize_id(id)

  @doc false
  @spec normalize_id!(term()) :: String.t()
  def normalize_id!(id), do: Resolver.normalize_id!(id)

  defp normalize_input(input) when is_list(input) do
    if Keyword.keyword?(input) do
      {:ok, Map.new(input)}
    else
      {:error, {:invalid_workflow_input, input}}
    end
  end

  defp normalize_input(input) when is_map(input), do: {:ok, Schema.normalize_attrs(input)}
  defp normalize_input(input), do: {:error, {:invalid_workflow_input, input}}

  defp normalize_context(%Jidoka.Context{} = context), do: {:ok, context}

  defp normalize_context(context) when is_list(context) or is_map(context) do
    case Jidoka.Context.from_data(context) do
      {:ok, context} -> {:ok, context}
      {:error, _reason} -> {:error, {:invalid_workflow_context, context}}
    end
  end

  defp normalize_context(context), do: {:error, {:invalid_workflow_context, context}}
end
