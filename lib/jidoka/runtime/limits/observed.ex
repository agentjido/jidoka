defmodule Jidoka.Runtime.Limits.Observed do
  @moduledoc """
  Portable usage facts observed while Jidoka applies runtime limits.

  `model_steps` is the canonical logical model-decision count. `model_turns`
  remains an equal compatibility field for existing projections.
  """

  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              user_turns: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              model_steps: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              model_turns: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              tool_call_groups: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              tool_calls: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              provider_attempts: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              recovery_steps: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              observation_bytes: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              result_repairs: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              sequence_duration_ms: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              usage: Zoi.map() |> Zoi.default(%{}),
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

  @doc "Returns the observed-limit schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds observed limit facts."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds observed limit facts or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "observed runtime limits")
end
