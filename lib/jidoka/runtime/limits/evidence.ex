defmodule Jidoka.Runtime.Limits.Evidence do
  @moduledoc "Portable applied, observed, and exceeded runtime-limit evidence."

  alias Jidoka.Runtime.Limits
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.integer() |> Zoi.positive() |> Zoi.default(1),
              status: Schema.atom_enum([:within, :exceeded]),
              applied: Zoi.lazy({Limits.Applied, :schema, []}),
              observed: Zoi.lazy({Limits.Observed, :schema, []}),
              exceeded: Zoi.lazy({Limits.Exceeded, :schema, []}) |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the runtime-limit evidence schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds runtime-limit evidence."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds runtime-limit evidence or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "runtime limit evidence")
end
