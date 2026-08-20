defmodule Jidoka.Runtime.Limits.Exceeded do
  @moduledoc "Portable evidence for one runtime limit that stopped work."

  alias Jidoka.Schema

  @kinds [
    :model_turns,
    :turn_timeout,
    :capability_timeout,
    :sequence_timeout,
    :provider_attempts,
    :tool_calls_per_group,
    :tool_calls_per_turn,
    :recovery_steps,
    :observation_bytes,
    :result_repairs,
    :total_tokens,
    :total_cost,
    :environment
  ]

  @schema Zoi.struct(
            __MODULE__,
            %{
              kind: Schema.atom_enum(@kinds),
              limit: Zoi.number(),
              observed: Zoi.number(),
              turn_index: Zoi.integer() |> Zoi.positive() |> Zoi.nullish(),
              effect_kind: Zoi.atom() |> Zoi.nullish()
            },
            coerce: true
          )

  @type kind ::
          :model_turns
          | :turn_timeout
          | :capability_timeout
          | :sequence_timeout
          | :provider_attempts
          | :tool_calls_per_group
          | :tool_calls_per_turn
          | :recovery_steps
          | :observation_bytes
          | :result_repairs
          | :total_tokens
          | :total_cost
          | :environment
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the supported limit kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Returns the limit-exceeded schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds limit-exceeded evidence."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds limit-exceeded evidence or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "runtime limit exceeded")
end
