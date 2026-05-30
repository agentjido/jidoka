defmodule Jidoka.Effect.LLMDecision do
  @moduledoc """
  Typed model-side decision returned by an LLM effect.

  The runtime uses a constrained decision protocol: a model either returns a
  final response or asks Jidoka to run one operation. Keeping that decision as a
  struct gives hibernate/resume a stable shape instead of relying on loose maps.
  """

  alias Jidoka.Schema

  @types [:final, :operation]

  @schema Zoi.struct(
            __MODULE__,
            %{
              type: Schema.atom_enum(@types),
              content: Zoi.string() |> Zoi.nullish(),
              name: Schema.non_empty_string() |> Zoi.nullish(),
              arguments: Zoi.map() |> Zoi.default(%{}),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type decision_type :: :final | :operation
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    case normalized_type(Schema.get_key(attrs, :type)) do
      "final" ->
        case Schema.get_key(attrs, :content) do
          content when is_binary(content) ->
            attrs
            |> Map.delete("type")
            |> Map.put(:type, :final)
            |> then(&Schema.parse(@schema, &1))

          other ->
            {:error, {:invalid_final_content, other}}
        end

      "operation" ->
        name = Schema.get_key(attrs, :name)
        arguments = Schema.get_key(attrs, :arguments, %{})

        cond do
          not is_binary(name) ->
            {:error, {:invalid_operation_name, name}}

          not is_map(arguments) ->
            {:error, {:invalid_operation_arguments, arguments}}

          true ->
            attrs
            |> Map.delete("type")
            |> Map.put(:type, :operation)
            |> then(&Schema.parse(@schema, &1))
        end

      type ->
        {:error, {:invalid_llm_decision_type, type}}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, decision} -> decision
      {:error, reason} -> raise ArgumentError, "invalid LLM decision: #{inspect(reason)}"
    end
  end

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = decision), do: new(decision)
  def from_input(input), do: new(input)

  @spec final(String.t(), keyword()) :: t()
  def final(content, opts \\ []) when is_binary(content) do
    new!(
      type: :final,
      content: content,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec operation(String.t(), map(), keyword()) :: t()
  def operation(name, arguments \\ %{}, opts \\ []) when is_binary(name) and is_map(arguments) do
    new!(
      type: :operation,
      name: name,
      arguments: arguments,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{type: :final, content: content}) do
    %{type: :final, content: content}
  end

  def to_payload(%__MODULE__{type: :operation, name: name, arguments: arguments}) do
    %{type: :operation, name: name, arguments: arguments}
  end

  defp normalized_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalized_type(type), do: type
end
