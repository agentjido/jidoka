defmodule Jidoka.Runtime.Limits.Applied do
  @moduledoc "Portable limits that the Jidoka runtime applies to one turn or sequence."

  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.integer() |> Zoi.positive() |> Zoi.default(1),
              max_model_turns: Zoi.integer() |> Zoi.positive(),
              turn_timeout_ms: Zoi.integer() |> Zoi.positive(),
              capability_timeout_ms: Zoi.integer() |> Zoi.positive() |> Zoi.nullish(),
              sequence_timeout_ms: Zoi.integer() |> Zoi.positive() |> Zoi.nullish(),
              max_provider_attempts: Zoi.integer() |> Zoi.positive() |> Zoi.nullish(),
              max_tool_calls_per_group: Zoi.integer() |> Zoi.positive() |> Zoi.nullish(),
              max_tool_calls_per_turn: Zoi.integer() |> Zoi.positive() |> Zoi.nullish(),
              max_recovery_steps: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish(),
              max_observation_bytes: Zoi.integer() |> Zoi.positive() |> Zoi.nullish(),
              max_result_repairs: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish(),
              max_total_tokens: Zoi.integer() |> Zoi.positive() |> Zoi.nullish(),
              max_total_cost: Zoi.number() |> Zoi.gt(0) |> Zoi.nullish(),
              environment:
                Zoi.map()
                |> Zoi.default(%{})
                |> Zoi.refine({Contract, :validate_safe_map, []})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the applied-limit schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds applied limits."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds applied limits or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "applied runtime limits")
end
