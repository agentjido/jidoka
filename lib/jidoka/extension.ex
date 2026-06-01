defmodule Jidoka.Extension do
  @moduledoc """
  Behaviour for small Jidoka feature extensions.

  Extensions are not package plugins. They are modules that contribute to the
  Jidoka data/runtime contract through narrow slots: DSL sections, spec
  patches, workflow steps, runtime requirements, and trace/event definitions.
  The core harness remains responsible for the turn spine, effect journal, and
  snapshot semantics.
  """

  @type context :: map()

  @doc "Returns the stable extension name."
  @callback name() :: atom()

  @doc "Returns additional Spark DSL sections contributed by the extension."
  @callback dsl_sections() :: [Spark.Dsl.Section.t()]

  @doc "Returns Spark verifier modules contributed by the extension."
  @callback verifiers() :: [module()]

  @doc "Returns a data patch for a compiled agent spec."
  @callback spec_patch(module() | map(), context()) ::
              {:ok, Jidoka.Extension.Patch.t()} | {:error, term()}

  @doc "Returns workflow steps contributed to a turn plan."
  @callback workflow_steps(Jidoka.Turn.Plan.t()) :: [term()]

  @doc "Returns runtime requirements needed by an extension."
  @callback runtime_requirements(Jidoka.Agent.Spec.t()) :: [term()]

  @doc "Returns event names contributed by an extension."
  @callback events() :: [atom()]

  @doc "Provides default no-op extension callbacks for extension modules."
  defmacro __using__(_opts) do
    quote do
      @behaviour Jidoka.Extension

      @doc false
      @impl true
      @spec dsl_sections() :: [Spark.Dsl.Section.t()]
      def dsl_sections, do: []

      @doc false
      @impl true
      @spec verifiers() :: [module()]
      def verifiers, do: []

      @doc false
      @impl true
      @spec spec_patch(module() | map(), Jidoka.Extension.context()) ::
              {:ok, Jidoka.Extension.Patch.t()} | {:error, term()}
      def spec_patch(_source, _context), do: {:ok, Jidoka.Extension.Patch.new!()}

      @doc false
      @impl true
      @spec workflow_steps(Jidoka.Turn.Plan.t()) :: [term()]
      def workflow_steps(_plan), do: []

      @doc false
      @impl true
      @spec runtime_requirements(Jidoka.Agent.Spec.t()) :: [term()]
      def runtime_requirements(_spec), do: []

      @doc false
      @impl true
      @spec events() :: [atom()]
      def events, do: []

      defoverridable dsl_sections: 0,
                     verifiers: 0,
                     spec_patch: 2,
                     workflow_steps: 1,
                     runtime_requirements: 1,
                     events: 0
    end
  end
end
