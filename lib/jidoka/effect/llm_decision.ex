defmodule Jidoka.Effect.LLMDecision do
  @moduledoc """
  Typed model-side decision returned by an LLM effect.

  The runtime uses a constrained decision protocol: a model either returns a
  final response or asks Jidoka to run one or more operations. Keeping that
  decision as a struct gives hibernate/resume a stable shape instead of relying
  on loose maps.
  """

  alias Jidoka.Schema
  alias Jidoka.Effect.OperationRequest

  @types [:final, :operation, :operations]

  @schema Zoi.struct(
            __MODULE__,
            %{
              type: Schema.atom_enum(@types),
              content: Zoi.string() |> Zoi.nullish(),
              result: Zoi.any() |> Zoi.nullish(),
              name: Schema.non_empty_string() |> Zoi.nullish(),
              arguments: Zoi.map() |> Zoi.default(%{}),
              operations: Zoi.array(Zoi.lazy({OperationRequest, :schema, []})) |> Zoi.default([]),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type decision_type :: :final | :operation | :operations
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a normalized model decision."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a model decision from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    case normalized_type(Schema.get_key(attrs, :type)) do
      "final" -> new_final(attrs)
      "operation" -> new_operation(attrs)
      "operations" -> new_operations(attrs)
      type -> {:error, {:invalid_llm_decision_type, type}}
    end
  end

  @doc "Builds a model decision and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, decision} -> decision
      {:error, reason} -> raise ArgumentError, "invalid LLM decision: #{inspect(reason)}"
    end
  end

  @doc "Normalizes an existing decision, keyword list, or map."
  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = decision), do: new(decision)
  def from_input(input), do: new(input)

  @doc "Builds a final-answer model decision."
  @spec final(String.t(), keyword()) :: t()
  def final(content, opts \\ []) when is_binary(content) do
    new!(
      type: :final,
      content: content,
      result: Keyword.get(opts, :result),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @doc "Builds a decision that requests one operation."
  @spec operation(String.t(), map(), keyword()) :: t()
  def operation(name, arguments \\ %{}, opts \\ []) when is_binary(name) and is_map(arguments) do
    new!(
      type: :operation,
      name: name,
      arguments: arguments,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @doc "Builds a decision that requests one or more operations."
  @spec operations([OperationRequest.t() | keyword() | map()], keyword()) :: t()
  def operations(operations, opts \\ []) when is_list(operations) do
    new!(
      type: :operations,
      operations: operations,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @doc "Projects a model decision into its effect payload."
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{type: :final, content: content, result: result}) do
    %{type: :final, content: content, result: result}
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def to_payload(%__MODULE__{type: :operation, name: name, arguments: arguments}) do
    %{type: :operation, name: name, arguments: arguments}
  end

  def to_payload(%__MODULE__{type: :operations, operations: operations}) do
    %{type: :operations, operations: Enum.map(operations, &OperationRequest.to_payload/1)}
  end

  defp normalized_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalized_type(type), do: type

  defp new_final(attrs) do
    case Schema.get_key(attrs, :content) do
      content when is_binary(content) ->
        parse_typed(attrs, :final)

      other ->
        {:error, {:invalid_final_content, other}}
    end
  end

  defp new_operation(attrs) do
    name = Schema.get_key(attrs, :name)
    arguments = Schema.get_key(attrs, :arguments, %{})

    cond do
      not is_binary(name) -> {:error, {:invalid_operation_name, name}}
      not is_map(arguments) -> {:error, {:invalid_operation_arguments, arguments}}
      true -> parse_typed(attrs, :operation)
    end
  end

  defp new_operations(attrs) do
    operations = Schema.get_key(attrs, :operations, [])

    cond do
      not is_list(operations) -> {:error, {:invalid_operations, operations}}
      operations == [] -> {:error, {:empty_operations, operations}}
      true -> parse_typed(attrs, :operations)
    end
  end

  defp parse_typed(attrs, type) do
    attrs
    |> Map.delete("type")
    |> Map.put(:type, type)
    |> then(&Schema.parse(@schema, &1))
  end
end
