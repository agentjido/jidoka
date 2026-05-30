defmodule Jidoka.Memory.WriteRequest do
  @moduledoc "Request to write one memory entry."

  alias Jidoka.Memory.Entry
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              entry: Zoi.lazy({Entry, :schema, []}),
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
  def new!(attrs), do: Schema.parse!(@schema, attrs, "memory write request")
end
