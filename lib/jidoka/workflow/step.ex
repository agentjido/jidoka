defmodule Jidoka.Workflow.Step do
  @moduledoc "Data contract for one deterministic workflow step."

  alias Jidoka.Schema

  @kinds [:function, :action, :agent]

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.atom(),
              kind: Schema.atom_enum(@kinds),
              target: Zoi.any(),
              input: Zoi.any() |> Zoi.default(%{}),
              prompt: Zoi.any() |> Zoi.nullish(),
              context: Zoi.any() |> Zoi.default(%{}),
              after: Zoi.array(Zoi.atom()) |> Zoi.default([]),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for workflow steps."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns the supported deterministic workflow step kinds."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "Parses workflow step attributes into a validated step."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Parses workflow step attributes into a validated step or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "workflow step")
end
