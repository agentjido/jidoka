defmodule Jidoka.Agent.Spec.Controls.Operation do
  @moduledoc """
  Policy control attached to model-callable operations.
  """

  alias Jidoka.Agent.Spec.Operation, as: OperationSpec
  alias Jidoka.Schema

  @valid_kinds [
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
  @valid_idempotencies OperationSpec.valid_idempotencies()

  @schema Zoi.struct(
            __MODULE__,
            %{
              control: Zoi.atom(),
              match: Zoi.map() |> Zoi.default(%{}),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec valid_kinds() :: [atom()]
  def valid_kinds, do: @valid_kinds

  @doc "Returns true when this operation control applies to an operation spec or match data."
  @spec matches?(t(), OperationSpec.t() | map()) :: boolean()
  def matches?(%__MODULE__{} = control, %OperationSpec{} = operation) do
    matches?(control, %{
      name: operation.name,
      kind: OperationSpec.kind(operation),
      source: source_from_metadata(operation.metadata),
      idempotency: operation.idempotency,
      metadata: operation.metadata
    })
  end

  def matches?(%__MODULE__{match: match}, operation) when is_map(operation) do
    Enum.all?(match, fn
      {:kind, kind} ->
        get_any(operation, [:kind, "kind", :operation_kind, "operation_kind"]) == kind

      {:name, name} ->
        same_value?(get_any(operation, [:name, "name", :operation, "operation"]), name)

      {:source, source} ->
        same_value?(operation_source(operation), source)

      {:idempotency, idempotency} ->
        get_any(operation, [:idempotency, "idempotency"]) == idempotency

      {:metadata, metadata} ->
        metadata_matches?(get_any(operation, [:metadata, "metadata"]) || %{}, metadata)
    end)
  end

  @doc "Returns true when this operation control applies to an operation name/kind."
  @spec matches?(t(), String.t(), atom()) :: boolean()
  def matches?(%__MODULE__{match: match}, operation_name, operation_kind) do
    matches?(%__MODULE__{match: match, control: nil}, %{
      name: operation_name,
      kind: operation_kind
    })
  end

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, match} <- normalize_match(Schema.get_key(attrs, :match, %{})),
         {:ok, %__MODULE__{} = operation} <-
           Schema.parse(@schema, Map.put(attrs, :match, match)),
         :ok <- Jidoka.Control.validate_module(operation.control) do
      {:ok, operation}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, operation} -> operation
      {:error, reason} -> raise ArgumentError, "invalid operation control: #{inspect(reason)}"
    end
  end

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = operation), do: new(operation)
  def from_input(input), do: new(input)

  defp normalize_match(nil), do: {:ok, %{}}

  defp normalize_match(match) when is_list(match) do
    match
    |> Map.new()
    |> normalize_match()
  rescue
    exception -> {:error, {:invalid_operation_control_match, exception}}
  end

  defp normalize_match(%{} = match) do
    allowed_keys = [
      :kind,
      "kind",
      :name,
      "name",
      :source,
      "source",
      :idempotency,
      "idempotency",
      :metadata,
      "metadata"
    ]

    case Enum.reject(Map.keys(match), &(&1 in allowed_keys)) do
      [] ->
        with {:ok, kind_match} <- normalize_kind(Map.get(match, :kind, Map.get(match, "kind"))),
             {:ok, name_match} <- normalize_name(Map.get(match, :name, Map.get(match, "name"))),
             {:ok, source_match} <-
               normalize_source(Map.get(match, :source, Map.get(match, "source"))),
             {:ok, idempotency_match} <-
               normalize_idempotency(Map.get(match, :idempotency, Map.get(match, "idempotency"))),
             {:ok, metadata_match} <-
               normalize_metadata_match(Map.get(match, :metadata, Map.get(match, "metadata"))) do
          {:ok,
           %{}
           |> maybe_put(:kind, kind_match)
           |> maybe_put(:name, name_match)
           |> maybe_put(:source, source_match)
           |> maybe_put(:idempotency, idempotency_match)
           |> maybe_put(:metadata, metadata_match)}
        end

      unknown ->
        {:error, {:unknown_operation_control_match_keys, unknown}}
    end
  end

  defp normalize_match(other), do: {:error, {:invalid_operation_control_match, other}}

  defp normalize_kind(nil), do: {:ok, nil}
  defp normalize_kind(kind) when kind in @valid_kinds, do: {:ok, kind}

  defp normalize_kind(kind) when is_binary(kind) do
    kind = kind |> String.trim() |> String.downcase()

    case Enum.find(@valid_kinds, &(Atom.to_string(&1) == kind)) do
      nil -> {:error, {:invalid_operation_control_kind, kind}}
      kind -> {:ok, kind}
    end
  end

  defp normalize_kind(kind), do: {:error, {:invalid_operation_control_kind, kind}}

  defp normalize_name(nil), do: {:ok, nil}

  defp normalize_name(name) when is_atom(name) and not is_nil(name) do
    normalize_name(Atom.to_string(name))
  end

  defp normalize_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, {:invalid_operation_control_name, name}}
      name -> {:ok, name}
    end
  end

  defp normalize_name(name), do: {:error, {:invalid_operation_control_name, name}}

  defp normalize_source(nil), do: {:ok, nil}

  defp normalize_source(source) when is_atom(source) and not is_nil(source) do
    source
    |> Atom.to_string()
    |> normalize_source()
  end

  defp normalize_source(source) when is_binary(source) do
    case String.trim(source) do
      "" -> {:error, {:invalid_operation_control_source, source}}
      source -> {:ok, source}
    end
  end

  defp normalize_source(source), do: {:error, {:invalid_operation_control_source, source}}

  defp normalize_idempotency(nil), do: {:ok, nil}

  defp normalize_idempotency(idempotency) when idempotency in @valid_idempotencies,
    do: {:ok, idempotency}

  defp normalize_idempotency(idempotency) when is_binary(idempotency) do
    normalized = idempotency |> String.trim() |> String.downcase()

    OperationSpec.valid_idempotencies()
    |> Enum.find(&(Atom.to_string(&1) == normalized))
    |> case do
      nil -> {:error, {:invalid_operation_control_idempotency, idempotency}}
      idempotency -> {:ok, idempotency}
    end
  end

  defp normalize_idempotency(idempotency),
    do: {:error, {:invalid_operation_control_idempotency, idempotency}}

  defp normalize_metadata_match(nil), do: {:ok, nil}
  defp normalize_metadata_match(metadata) when is_map(metadata), do: {:ok, metadata}

  defp normalize_metadata_match(metadata),
    do: {:error, {:invalid_operation_control_metadata, metadata}}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp operation_source(operation) do
    get_any(operation, [:source, "source"]) ||
      operation
      |> get_any([:metadata, "metadata"])
      |> source_from_metadata()
  end

  defp source_from_metadata(metadata) when is_map(metadata) do
    metadata
    |> get_any([:source, "source", :runtime, "runtime"])
    |> normalize_source_value()
  end

  defp source_from_metadata(_metadata), do: nil

  defp normalize_source_value(source) when is_atom(source) and not is_nil(source),
    do: Atom.to_string(source)

  defp normalize_source_value(source) when is_binary(source), do: source
  defp normalize_source_value(_source), do: nil

  defp metadata_matches?(metadata, match) when is_map(metadata) and is_map(match) do
    Enum.all?(match, fn {key, expected} ->
      metadata
      |> fetch_any(key)
      |> case do
        {:ok, actual} -> same_value?(actual, expected)
        :error -> false
      end
    end)
  end

  defp metadata_matches?(_metadata, _match), do: false

  defp fetch_any(map, key) when is_map(map) do
    Enum.find_value(map, :error, fn {candidate_key, value} ->
      if same_key?(candidate_key, key), do: {:ok, value}
    end)
  end

  defp same_key?(left, right) when is_atom(left) and is_binary(right),
    do: Atom.to_string(left) == right

  defp same_key?(left, right) when is_binary(left) and is_atom(right),
    do: left == Atom.to_string(right)

  defp same_key?(left, right), do: left == right

  defp same_value?(left, right) when is_atom(left) and is_binary(right),
    do: Atom.to_string(left) == right

  defp same_value?(left, right) when is_binary(left) and is_atom(right),
    do: left == Atom.to_string(right)

  defp same_value?(left, right), do: left == right

  defp get_any(map, keys) when is_map(map), do: Enum.find_value(keys, &Map.get(map, &1))
end
