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

  @doc "Returns the Zoi schema for a memory write request."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a memory write request from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds a memory write request and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "memory write request")
end
