defmodule Jidoka.Action do
  @moduledoc """
  Authoring API for an Elixir action that an agent can use as a tool.

  `use Jidoka.Action` delegates execution and validation to `Jido.Action` while
  Jidoka normalizes the action into a model-facing operation.

      defmodule MyApp.LocalTime do
        use Jidoka.Action,
          name: "local_time",
          description: "Returns the local time for a city.",
          schema: Zoi.object(%{city: Zoi.string()})

        @impl true
        def run(%{city: city}, context) do
          tenant = Map.get(context, :tenant)
          {:ok, %{city: city, tenant: tenant, time: "09:30"}}
        end
      end

  ## Options

  The wrapper supplies a snake-case module name and a short description when
  they are omitted. It forwards these options to `Jido.Action`:

  - `:name` and `:description` define the operation shown to the model;
  - `:schema` validates and normalizes input parameters;
  - `:output_schema` validates successful output;
  - `:category`, `:tags`, `:vsn`, and `:compensation` supply Jido action
    metadata and policy.

  A Zoi schema is the preferred parameter form in Jidoka examples. Jido also
  accepts its supported keyword and JSON-schema forms.

  ## `run/2` Contract

  The first argument contains parameters normalized through the declared
  schema. Known string keys become the schema's atom keys, compatible values
  are coerced, and unknown keys follow Jido Action's open-validation behavior.

  The second argument is a map. It contains caller-supplied public context and
  a `:__jidoka__` entry with the complete `Jidoka.Context`. Use
  `Jidoka.Context.get_runtime/3` when the action needs a trusted runtime value.

  Return `{:ok, value}` for success or `{:error, reason}` for failure. Jidoka
  records the normalized value as the operation result. A different return
  shape becomes an `:invalid_action_result` error.

  Declare the action in an agent:

      tools do
        action MyApp.LocalTime
      end

  A DSL agent installs the action capability automatically. Runtime-built
  specs can use `Jidoka.Adapter.Jido.Actions` as advanced extension support.
  """

  @doc false
  defmacro __using__(opts \\ []) do
    module_name =
      __CALLER__.module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    defaults = [
      name: module_name,
      description: "Jidoka action #{module_name}"
    ]

    quote location: :keep do
      use Jido.Action, unquote(Keyword.merge(defaults, opts))
    end
  end
end
