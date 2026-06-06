defmodule Jidoka.Agent.Spec.Operation do
  @moduledoc """
  Model-callable operation definition.
  """

  alias Jidoka.Review.Policy
  alias Jidoka.Schema

  @type idempotency :: :pure | :idempotent | :dedupe | :reconcile | :unsafe_once

  @valid_idempotency [:pure, :idempotent, :dedupe, :reconcile, :unsafe_once]
  @known_kinds [
    :action,
    :operation,
    :tool,
    :ash_resource,
    :browser,
    :skill,
    :mcp,
    :catalog,
    :workflow,
    :subagent,
    :handoff
  ]
  @idempotency_schema Schema.atom_enum(@valid_idempotency)

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Schema.non_empty_string(),
              description: Zoi.string() |> Zoi.nullish(),
              idempotency: @idempotency_schema |> Zoi.default(:idempotent),
              approval: Zoi.any() |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec valid_idempotencies() :: [idempotency()]
  def valid_idempotencies, do: @valid_idempotency

  @doc """
  Returns the operation kind used for control matching and policy checks.

  Direct operations default to `:operation`. Adapters can set `:kind`,
  `:operation_kind`, `:source_kind`, `:runtime`, or `:source` metadata to
  expose a more precise kind while preserving one operation contract.
  """
  @spec kind(t()) :: atom()
  def kind(%__MODULE__{metadata: metadata}) when is_map(metadata) do
    metadata_kind(metadata) || runtime_kind(metadata) || :operation
  end

  @doc "Returns true when this operation requires an explicit operation control."
  @spec requires_control?(t() | idempotency()) :: boolean()
  def requires_control?(%__MODULE__{idempotency: idempotency}), do: requires_control?(idempotency)
  def requires_control?(:unsafe_once), do: true
  def requires_control?(_idempotency), do: false

  @doc "Returns true when this operation has a built-in approval policy."
  @spec approval_required?(t()) :: boolean()
  def approval_required?(%__MODULE__{approval: approval}), do: Policy.required?(approval)

  @doc "Returns true when a recorded intent may be retried without reconciliation."
  @spec replay_safe?(t() | idempotency()) :: boolean()
  def replay_safe?(%__MODULE__{idempotency: idempotency}), do: replay_safe?(idempotency)
  def replay_safe?(:unsafe_once), do: false
  def replay_safe?(_idempotency), do: true

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs =
      attrs
      |> Schema.normalize_attrs()
      |> normalize_attrs()

    with {:ok, approval} <- Policy.from_input(Schema.get_key(attrs, :approval)) do
      attrs = maybe_put_approval(attrs, approval)
      Schema.parse(@schema, attrs)
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, operation} -> operation
      {:error, reason} -> raise ArgumentError, "invalid operation: #{inspect(reason)}"
    end
  end

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = operation), do: new(operation)
  def from_input(input), do: new(input)

  defp metadata_kind(metadata) do
    metadata
    |> get_any([:kind, "kind", :operation_kind, "operation_kind", :source_kind, "source_kind"])
    |> normalize_kind()
  end

  defp runtime_kind(metadata) do
    case get_any(metadata, [:runtime, "runtime", :source, "source"]) do
      value when value in [:jido_action, "jido_action"] -> :action
      _value -> nil
    end
  end

  defp normalize_kind(kind) when kind in @known_kinds, do: kind
  defp normalize_kind(kind) when is_atom(kind), do: nil

  defp normalize_kind(kind) when is_binary(kind) do
    normalized = kind |> String.trim() |> String.downcase()

    Enum.find(@known_kinds, &(Atom.to_string(&1) == normalized))
  end

  defp normalize_kind(_kind), do: nil

  defp get_any(map, keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp normalize_attrs(%{} = attrs) do
    %{}
    |> put_known(attrs, :name)
    |> put_known(attrs, :description)
    |> put_known(attrs, :idempotency)
    |> put_known(attrs, :approval)
    |> put_known(attrs, :metadata)
  end

  defp normalize_attrs(attrs), do: attrs

  defp put_known(acc, attrs, key) do
    case Schema.fetch_key(attrs, key) do
      {:ok, value} -> Map.put(acc, key, value)
      :error -> acc
    end
  end

  defp maybe_put_approval(attrs, nil), do: Map.delete(attrs, :approval)
  defp maybe_put_approval(attrs, approval), do: Map.put(attrs, :approval, approval)
end
