defmodule Jidoka.Effect.ToolCall do
  @moduledoc """
  Durable record for one provider-neutral tool call.

  The Jidoka interaction and group identifiers are stable across provider
  retries and snapshot restore. The provider call identifier is optional
  because the constrained JSON protocol does not supply one.
  """

  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              interaction_id: Schema.non_empty_string(),
              group_id: Schema.non_empty_string(),
              provider_call_id: Schema.non_empty_string() |> Zoi.nullish(),
              call_index: Zoi.integer() |> Zoi.gte(0),
              name: Schema.non_empty_string(),
              arguments: Zoi.map() |> Zoi.default(%{}),
              provider_metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a tool call."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a tool call from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds a tool call and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "tool call")

  @doc "Normalizes an existing tool call, keyword list, or map."
  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = call), do: new(call)
  def from_input(input), do: new(input)

  @doc "Projects a tool call to durable data."
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = call) do
    call
    |> Map.from_struct()
    |> Map.reject(fn
      {_key, nil} -> true
      {:provider_metadata, metadata} when metadata == %{} -> true
      {_key, _value} -> false
    end)
  end
end
