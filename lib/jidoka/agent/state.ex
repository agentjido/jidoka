defmodule Jidoka.Agent.State do
  @moduledoc "Durable semantic state for an agent session."

  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              messages: Zoi.array(Zoi.map()) |> Zoi.default([]),
              operation_results: Zoi.array(Zoi.map()) |> Zoi.default([]),
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
  def new(attrs \\ [])
  def new(attrs), do: Schema.parse(@schema, attrs)

  @spec new!(keyword() | map()) :: t()
  def new!(attrs \\ []), do: Schema.parse!(@schema, attrs, "agent state")

  @spec from_input(t() | keyword() | map() | nil) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = state), do: new(state)
  def from_input(nil), do: new()
  def from_input(input), do: new(input)
end
