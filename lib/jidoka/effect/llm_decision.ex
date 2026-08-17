defmodule Jidoka.Effect.LLMDecision do
  @moduledoc """
  Typed model-side decision returned by an LLM effect.

  The runtime uses a constrained decision protocol: a model either returns a
  final response or asks Jidoka to run one or more operations. Keeping that
  decision as a struct gives hibernate/resume a stable shape instead of relying
  on loose maps.
  """

  alias Jidoka.ContentPart
  alias Jidoka.Effect.ModelInteraction
  alias Jidoka.Effect.OperationRequest
  alias Jidoka.Schema

  @types [:final, :operation, :operations]

  @schema Zoi.struct(
            __MODULE__,
            %{
              type: Schema.atom_enum(@types),
              content: Zoi.string() |> Zoi.nullish(),
              parts:
                Zoi.array(Zoi.lazy({ContentPart, :schema, []}))
                |> Zoi.default([]),
              result: Zoi.any() |> Zoi.nullish(),
              operations: Zoi.array(Zoi.lazy({OperationRequest, :schema, []})) |> Zoi.default([]),
              interaction: Zoi.lazy({ModelInteraction, :schema, []}) |> Zoi.nullish(),
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
  @spec final(String.t() | [ContentPart.input()], keyword()) :: t()
  def final(content, opts \\ []) when is_binary(content) or is_list(content) do
    new!(
      type: :final,
      content: content,
      parts: Keyword.get(opts, :parts, []),
      result: Keyword.get(opts, :result),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @doc "Builds a decision that requests one operation."
  @spec operation(String.t(), map(), keyword()) :: t()
  def operation(name, arguments \\ %{}, opts \\ []) when is_binary(name) and is_map(arguments) do
    new!(
      type: :operation,
      operations: [
        %{
          name: name,
          arguments: arguments,
          provider_call_id: Keyword.get(opts, :provider_call_id),
          provider_metadata: Keyword.get(opts, :provider_metadata, %{})
        }
      ],
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @doc "Attaches a durable interaction record to a model decision."
  @spec with_interaction(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def with_interaction(%__MODULE__{} = decision, opts \\ []) do
    with {:ok, interaction} <- ModelInteraction.from_decision(decision, opts) do
      new(%__MODULE__{decision | interaction: interaction})
    end
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

  @doc "Returns the first requested operation for legacy singular consumers."
  @spec first_operation(t()) :: OperationRequest.t() | nil
  def first_operation(%__MODULE__{operations: [operation | _rest]}), do: operation
  def first_operation(%__MODULE__{}), do: nil

  @doc "Returns the first requested operation name."
  @spec name(t()) :: String.t() | nil
  def name(%__MODULE__{} = decision) do
    case first_operation(decision) do
      %OperationRequest{name: name} -> name
      nil -> nil
    end
  end

  @doc "Returns the first requested operation arguments."
  @spec arguments(t()) :: map() | nil
  def arguments(%__MODULE__{} = decision) do
    case first_operation(decision) do
      %OperationRequest{arguments: arguments} -> arguments
      nil -> nil
    end
  end

  @doc "Projects a model decision into its effect payload."
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{type: :final, content: content, parts: parts, result: result}) do
    %{type: :final, content: content, parts: parts, result: result}
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
    |> Map.new()
  end

  def to_payload(%__MODULE__{type: type, operations: operations})
      when type in [:operation, :operations] do
    %{type: type, operations: Enum.map(operations, &OperationRequest.to_payload/1)}
  end

  defp normalized_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalized_type(type), do: type

  defp new_final(attrs) do
    with {:ok, attrs} <- normalize_final_parts(attrs) do
      case Schema.get_key(attrs, :content) do
        content when is_binary(content) ->
          parse_typed(attrs, :final)

        other ->
          {:error, {:invalid_final_content, other}}
      end
    end
  end

  defp normalize_final_parts(attrs) do
    content = Schema.get_key(attrs, :content)
    parts = Schema.get_key(attrs, :parts, [])

    cond do
      is_list(content) and content != [] -> put_normalized_parts(attrs, content)
      is_list(parts) and parts != [] -> put_normalized_parts(attrs, parts)
      parts == [] -> {:ok, Map.put(attrs, :parts, [])}
      true -> {:error, {:invalid_final_parts, parts}}
    end
  end

  defp put_normalized_parts(attrs, inputs) do
    case ContentPart.from_inputs(inputs) do
      {:ok, parts} ->
        content =
          case Schema.get_key(attrs, :content) do
            content when is_binary(content) -> content
            _other -> ContentPart.text_content(parts)
          end

        {:ok,
         attrs
         |> Map.delete("content")
         |> Map.delete("parts")
         |> Map.put(:content, content)
         |> Map.put(:parts, parts)}

      {:error, reason} ->
        {:error, {:invalid_final_parts, reason}}
    end
  end

  defp new_operation(attrs) do
    with {:ok, legacy} <- legacy_operation(attrs),
         {:ok, operations} <- operation_requests(attrs, legacy),
         :ok <- validate_singular_operations(legacy, operations) do
      attrs
      |> put_operations(operations)
      |> parse_typed(:operation)
    end
  end

  defp operation_requests(attrs, legacy) do
    case Schema.get_key(attrs, :operations, []) do
      [] -> operation_requests_from_legacy(legacy)
      operations -> normalize_operation_requests(operations)
    end
  end

  defp operation_requests_from_legacy(:none), do: {:error, {:invalid_operation_name, nil}}
  defp operation_requests_from_legacy({:legacy, operation}), do: {:ok, [operation]}

  defp new_operations(attrs) do
    with {:ok, legacy} <- legacy_operation(attrs),
         {:ok, operations} <- nonempty_operation_requests(attrs),
         :ok <- validate_plural_legacy(legacy, operations) do
      attrs
      |> put_operations(operations)
      |> parse_typed(:operations)
    end
  end

  defp nonempty_operation_requests(attrs) do
    case Schema.get_key(attrs, :operations, []) do
      operations when not is_list(operations) -> {:error, {:invalid_operations, operations}}
      [] -> {:error, {:empty_operations, []}}
      operations -> normalize_operation_requests(operations)
    end
  end

  defp normalize_operation_requests(operations) when is_list(operations) do
    operations
    |> Enum.reduce_while({:ok, []}, fn operation, {:ok, normalized} ->
      case OperationRequest.from_input(operation) do
        {:ok, operation} -> {:cont, {:ok, [operation | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end)
  end

  defp normalize_operation_requests(operations), do: {:error, {:invalid_operations, operations}}

  defp legacy_operation(attrs) do
    name? = has_key?(attrs, :name)
    arguments? = has_key?(attrs, :arguments)

    if name? or arguments? do
      name = Schema.get_key(attrs, :name)
      arguments = Schema.get_key(attrs, :arguments, %{})

      cond do
        not is_binary(name) -> {:error, {:invalid_operation_name, name}}
        name == "" -> {:error, {:invalid_operation_name, name}}
        not is_map(arguments) -> {:error, {:invalid_operation_arguments, arguments}}
        true -> {:ok, {:legacy, OperationRequest.new!(name: name, arguments: arguments)}}
      end
    else
      {:ok, :none}
    end
  end

  defp has_key?(attrs, key) do
    Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))
  end

  defp validate_singular_operations(:none, [_operation]), do: :ok

  defp validate_singular_operations(:none, operations),
    do: {:error, {:invalid_operation_decision_count, :operation, length(operations)}}

  defp validate_singular_operations({:legacy, legacy}, [operation]) do
    validate_legacy_match(legacy, [operation])
  end

  defp validate_singular_operations({:legacy, legacy}, operations),
    do: conflicting_operation(legacy, operations)

  defp validate_plural_legacy(:none, _operations), do: :ok

  defp validate_plural_legacy({:legacy, legacy}, [operation]),
    do: validate_legacy_match(legacy, [operation])

  defp validate_plural_legacy({:legacy, legacy}, operations),
    do: conflicting_operation(legacy, operations)

  defp validate_legacy_match(legacy, [operation]) do
    if same_operation?(legacy, operation),
      do: :ok,
      else: conflicting_operation(legacy, [operation])
  end

  defp same_operation?(left, right) do
    left.name == right.name and left.arguments == right.arguments
  end

  defp conflicting_operation(legacy, operations) do
    {:error,
     {:conflicting_operation_decision, OperationRequest.to_payload(legacy),
      Enum.map(operations, &OperationRequest.to_payload/1)}}
  end

  defp put_operations(attrs, operations) do
    attrs
    |> Map.drop([:name, "name", :arguments, "arguments", "operations"])
    |> Map.put(:operations, operations)
  end

  defp parse_typed(attrs, type) do
    attrs
    |> Map.delete("type")
    |> Map.put(:type, type)
    |> then(&Schema.parse(@schema, &1))
  end
end
