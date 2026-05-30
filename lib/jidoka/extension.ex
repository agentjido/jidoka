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

  @callback name() :: atom()
  @callback dsl_sections() :: [Spark.Dsl.Section.t()]
  @callback verifiers() :: [module()]
  @callback spec_patch(module() | map(), context()) ::
              {:ok, Jidoka.Extension.Patch.t()} | {:error, term()}
  @callback workflow_steps(Jidoka.Turn.Plan.t()) :: [term()]
  @callback runtime_requirements(Jidoka.Agent.Spec.t()) :: [term()]
  @callback events() :: [atom()]

  defmacro __using__(_opts) do
    quote do
      @behaviour Jidoka.Extension

      @impl true
      def dsl_sections, do: []

      @impl true
      def verifiers, do: []

      @impl true
      def spec_patch(_source, _context), do: {:ok, Jidoka.Extension.Patch.new!()}

      @impl true
      def workflow_steps(_plan), do: []

      @impl true
      def runtime_requirements(_spec), do: []

      @impl true
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
