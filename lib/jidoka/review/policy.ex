defmodule Jidoka.Review.Policy do
  @moduledoc """
  Policy describing when a model-requested operation must pause for review.

  A policy is definition data. Runtime approval still flows through
  `Jidoka.Review.Interrupt`, `Jidoka.Review.Request`, and
  `Jidoka.Review.Response`.
  """

  alias Jidoka.Schema

  @modes [:pre_execution]

  @schema Zoi.struct(
            __MODULE__,
            %{
              required: Zoi.boolean() |> Zoi.default(true),
              mode: Schema.atom_enum(@modes) |> Zoi.default(:pre_execution),
              reason: Zoi.any() |> Zoi.default(:approval_required),
              message: Zoi.string() |> Zoi.nullish(),
              ttl_ms: Zoi.integer() |> Zoi.gt(0) |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type mode :: :pre_execution
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "review policy")

  @spec from_input(t() | keyword() | map() | true | false | nil) :: {:ok, t() | nil} | {:error, term()}
  def from_input(nil), do: {:ok, nil}
  def from_input(false), do: {:ok, nil}
  def from_input(true), do: new(%{})
  def from_input(%__MODULE__{} = policy), do: new(policy)

  def from_input(input) when is_list(input) do
    input
    |> Map.new()
    |> from_input()
  rescue
    exception -> {:error, {:invalid_review_policy, exception}}
  end

  def from_input(%{} = input), do: new(input)
  def from_input(other), do: {:error, {:invalid_review_policy, other}}

  @spec required?(t() | nil) :: boolean()
  def required?(%__MODULE__{required: true}), do: true
  def required?(_policy), do: false

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = policy) do
    %{
      "required" => policy.required,
      "mode" => Atom.to_string(policy.mode),
      "reason" => policy.reason,
      "message" => policy.message,
      "ttl_ms" => policy.ttl_ms,
      "metadata" => policy.metadata
    }
    |> reject_nil_values()
  end

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
