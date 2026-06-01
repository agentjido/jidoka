defmodule Jidoka.Agent.State do
  @moduledoc "Durable semantic state for an agent session."

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              messages: Zoi.array(Zoi.lazy({Agent.Message, :schema, []})) |> Zoi.default([]),
              operation_results: Zoi.array(Zoi.lazy({Effect.OperationResult, :schema, []})) |> Zoi.default([]),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for durable agent session state."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds validated durable agent session state."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ [])
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds durable agent session state or raises when validation fails."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs \\ []), do: Schema.parse!(@schema, attrs, "agent state")

  @doc "Normalizes nil, an existing state struct, a keyword list, or a map into agent state."
  @spec from_input(t() | keyword() | map() | nil) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = state), do: new(state)
  def from_input(nil), do: new()
  def from_input(input), do: new(input)
end
