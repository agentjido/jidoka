defmodule Jidoka.Review.Interrupt do
  @moduledoc """
  Durable pause point produced by a runtime control.

  Interrupts are data. They describe why a turn paused and what pending effect
  may continue after an application supplies a review response.
  """

  alias Jidoka.Agent.Spec.Controls.Operation, as: OperationControl
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Schema

  @boundaries [:operation]
  @effect_kinds [:operation]

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Schema.non_empty_string(),
              boundary: Schema.atom_enum(@boundaries),
              control: Zoi.atom(),
              control_name: Schema.non_empty_string(),
              reason: Zoi.any(),
              agent_id: Schema.non_empty_string(),
              request_id: Schema.non_empty_string(),
              loop_index: Zoi.integer() |> Zoi.gte(0),
              effect_id: Schema.non_empty_string(),
              effect_kind: Schema.atom_enum(@effect_kinds),
              operation: Schema.non_empty_string(),
              operation_kind: Schema.atom_enum(OperationControl.valid_kinds()) |> Zoi.default(:operation),
              arguments: Zoi.map() |> Zoi.default(%{}),
              idempotency: Schema.atom_enum(Operation.valid_idempotencies()) |> Zoi.nullish(),
              idempotency_key: Zoi.string() |> Zoi.nullish(),
              created_at_ms: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish(),
              expires_at_ms: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish(),
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
  def new(attrs), do: Schema.parse(@schema, attrs)

  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "interrupt")

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = interrupt), do: new(interrupt)
  def from_input(input), do: new(input)

  @spec with_review_window(t(), non_neg_integer(), pos_integer() | nil) :: t()
  def with_review_window(%__MODULE__{} = interrupt, now_ms, ttl_ms)
      when is_integer(now_ms) and now_ms >= 0 and (is_nil(ttl_ms) or ttl_ms > 0) do
    created_at_ms = interrupt.created_at_ms || now_ms
    expires_at_ms = interrupt.expires_at_ms || expires_at(created_at_ms, ttl_ms)

    %__MODULE__{
      interrupt
      | created_at_ms: created_at_ms,
        expires_at_ms: expires_at_ms
    }
  end

  @spec expired?(t(), non_neg_integer()) :: boolean()
  def expired?(%__MODULE__{expires_at_ms: nil}, _now_ms), do: false
  def expired?(%__MODULE__{expires_at_ms: expires_at_ms}, now_ms), do: now_ms > expires_at_ms

  @spec stable_id([term()]) :: String.t()
  def stable_id(parts) when is_list(parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.url_encode64(padding: false)

    "intr:" <> digest
  end

  defp expires_at(_created_at_ms, nil), do: nil
  defp expires_at(created_at_ms, ttl_ms), do: created_at_ms + ttl_ms
end
