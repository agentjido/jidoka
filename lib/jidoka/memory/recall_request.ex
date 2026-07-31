defmodule Jidoka.Memory.RecallRequest do
  @moduledoc "Request sent to a memory store before prompt assembly."

  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              agent_id: Schema.non_empty_string(),
              session_id: Schema.non_empty_string() |> Zoi.nullish(),
              scope: Schema.atom_enum(Jidoka.Agent.Spec.Memory.scopes()) |> Zoi.default(:agent),
              query: Schema.non_empty_string(),
              limit: Zoi.integer() |> Zoi.positive() |> Zoi.default(5),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a memory recall request."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a memory recall request from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds a memory recall request and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "memory recall request")
end
