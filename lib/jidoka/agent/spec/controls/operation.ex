defmodule Jidoka.Agent.Spec.Controls.Operation do
  @moduledoc """
  Policy control attached to model-callable operations.
  """

  alias Jidoka.Schema

  @valid_kinds [:action, :operation, :tool, :workflow, :subagent, :handoff]

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

  @doc "Returns true when this operation control applies to an operation name/kind."
  @spec matches?(t(), String.t(), atom()) :: boolean()
  def matches?(%__MODULE__{match: match}, operation_name, operation_kind) do
    Enum.all?(match, fn
      {:kind, kind} -> kind == operation_kind
      {:name, name} -> name == operation_name
    end)
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
    allowed_keys = [:kind, "kind", :name, "name"]

    case Enum.reject(Map.keys(match), &(&1 in allowed_keys)) do
      [] ->
        with {:ok, kind_match} <- normalize_kind(Map.get(match, :kind, Map.get(match, "kind"))),
             {:ok, name_match} <- normalize_name(Map.get(match, :name, Map.get(match, "name"))) do
          {:ok,
           %{}
           |> maybe_put(:kind, kind_match)
           |> maybe_put(:name, name_match)}
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
