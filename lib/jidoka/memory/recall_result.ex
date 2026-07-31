defmodule Jidoka.Memory.RecallResult do
  @moduledoc "Memory entries recalled for a turn."

  alias Jidoka.Memory.Entry
  alias Jidoka.Memory.RecallRequest
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              request: Zoi.lazy({RecallRequest, :schema, []}),
              entries: Zoi.array(Zoi.lazy({Entry, :schema, []})) |> Zoi.default([]),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a memory recall result."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a memory recall result from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds a memory recall result and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "memory recall result")
end
