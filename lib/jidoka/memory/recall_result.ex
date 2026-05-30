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

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "memory recall result")
end
