defmodule Jidoka.Runtime.Controls.OperationContext do
  @moduledoc """
  Runtime context passed to controls at the operation boundary.

  This is deliberately data-only. Operation controls can inspect the pending
  operation request and turn state, but they do not execute the operation.
  """

  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              type: Schema.atom_enum([:control]) |> Zoi.default(:control),
              boundary: Schema.atom_enum([:operation]) |> Zoi.default(:operation),
              control: Zoi.atom(),
              control_name: Schema.non_empty_string(),
              metadata: Zoi.map() |> Zoi.default(%{}),
              request_metadata: Zoi.map() |> Zoi.default(%{}),
              operation: Schema.non_empty_string(),
              kind:
                Schema.atom_enum(Jidoka.Agent.Spec.Controls.Operation.valid_kinds())
                |> Zoi.default(:operation),
              operation_kind:
                Schema.atom_enum(Jidoka.Agent.Spec.Controls.Operation.valid_kinds())
                |> Zoi.default(:operation),
              source: Zoi.string() |> Zoi.nullish(),
              arguments: Zoi.map() |> Zoi.default(%{}),
              operation_match: Zoi.map() |> Zoi.default(%{}),
              operation_metadata: Zoi.map() |> Zoi.default(%{}),
              idempotency:
                Schema.atom_enum(Jidoka.Agent.Spec.Operation.valid_idempotencies())
                |> Zoi.nullish(),
              idempotency_key: Zoi.string() |> Zoi.nullish(),
              spec: Zoi.any(),
              plan: Zoi.any(),
              request: Zoi.any(),
              input: Zoi.string(),
              context: Zoi.map() |> Zoi.default(%{}),
              ctx: Zoi.lazy({Jidoka.Context, :schema, []}) |> Zoi.nullish(),
              agent_state: Zoi.any(),
              intent: Zoi.any(),
              operation_request: Zoi.any(),
              operation_spec: Zoi.any() |> Zoi.nullish()
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
  def new!(attrs), do: Schema.parse!(@schema, attrs, "operation control context")
end
