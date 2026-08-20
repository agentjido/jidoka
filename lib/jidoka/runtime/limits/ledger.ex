defmodule Jidoka.Runtime.Limits.Ledger do
  @moduledoc "Portable usage ledger for one Jidoka turn."

  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              provider_attempts: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              tool_call_groups: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              tool_calls: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              recovery_steps: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              observation_bytes: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              result_repairs: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              total_tokens: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              total_cost: Zoi.number() |> Zoi.gte(0) |> Zoi.default(0),
              operation_group_ids: Zoi.array(Zoi.string()) |> Zoi.default([]),
              tool_call_ids: Zoi.array(Zoi.string()) |> Zoi.default([]),
              recovery_intent_ids: Zoi.array(Zoi.string()) |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the limit-ledger schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a limit ledger."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ []), do: Schema.parse(@schema, attrs)

  @doc "Builds a limit ledger or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs \\ []), do: Schema.parse!(@schema, attrs, "runtime limit ledger")
end
