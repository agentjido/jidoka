defmodule Jidoka.Workflow.Spec do
  @moduledoc "Data contract for a deterministic Jidoka workflow."

  alias Jidoka.Schema
  alias Jidoka.Workflow.Step

  @modes [:callback, :dsl]

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Schema.non_empty_string(),
              module: Zoi.atom(),
              description: Zoi.string() |> Zoi.nullish(),
              mode: Schema.atom_enum(@modes) |> Zoi.default(:callback),
              input_schema: Zoi.any() |> Zoi.nullish(),
              parameters_schema: Zoi.map() |> Zoi.nullish(),
              steps: Zoi.array(Zoi.lazy({Step, :schema, []})) |> Zoi.default([]),
              dependencies: Zoi.map() |> Zoi.default(%{}),
              output: Zoi.any() |> Zoi.nullish(),
              input_refs: Zoi.array(Zoi.any()) |> Zoi.default([]),
              context_refs: Zoi.array(Zoi.any()) |> Zoi.default([]),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for workflow specs."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns the supported workflow definition modes."
  @spec modes() :: [atom()]
  def modes, do: @modes

  @doc "Parses workflow spec attributes into a validated spec."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Parses workflow spec attributes into a validated spec or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "workflow spec")
end
