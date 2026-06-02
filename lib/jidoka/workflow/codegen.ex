defmodule Jidoka.Workflow.Codegen do
  @moduledoc false

  alias Jidoka.Workflow.Spec

  @spec emit(Spec.t()) :: Macro.t()
  def emit(%Spec{} = spec) do
    quote location: :keep do
      @doc false
      @spec __jidoka_workflow__() :: Jidoka.Workflow.Spec.t()
      def __jidoka_workflow__, do: unquote(Macro.escape(spec))

      @doc "Returns the stable public workflow id."
      @spec id() :: String.t()
      def id, do: unquote(spec.id)

      @doc "Returns the workflow description."
      @spec description() :: String.t() | nil
      def description, do: unquote(spec.description)

      @doc "Returns the configured Zoi workflow input schema."
      @spec input_schema() :: Zoi.schema()
      def input_schema, do: unquote(Macro.escape(spec.input_schema))

      @doc "Returns the provider-facing parameters schema derived from workflow input."
      @spec parameters_schema() :: map()
      def parameters_schema, do: unquote(Macro.escape(spec.parameters_schema))

      @doc "Returns the compiled workflow steps."
      @spec steps() :: [Jidoka.Workflow.Step.t()]
      def steps, do: unquote(Macro.escape(spec.steps))

      @doc "Returns the workflow output selector."
      @spec output() :: term()
      def output, do: unquote(Macro.escape(spec.output))

      @doc "Runs this workflow through Jidoka's workflow runtime."
      @spec run(map() | keyword(), map()) :: {:ok, term()} | {:error, term()}
      def run(input, context), do: Jidoka.Workflow.Runtime.run(__jidoka_workflow__(), input, context: context)
    end
  end
end
