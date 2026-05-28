defmodule Jidoka.Context do
  @moduledoc false

  @reserved_keys [
    "__jidoka_character__",
    "__jidoka_compaction__",
    "__jidoka_hooks__",
    "__jidoka_guardrails__",
    "__jidoka_memory__",
    "__jidoka_skills__",
    "__jidoka_output__",
    "__tool_guardrail_callback__",
    "__jidoka_request_id__",
    "__jidoka_server__",
    "__jidoka_agent_id__",
    "__jidoka_subagent_depth__",
    "__jidoka_conversation__",
    "__jidoka_from_agent__"
  ]

  @type t :: map()
  @type schema :: Zoi.schema() | nil

  @spec normalize(term()) :: {:ok, t()} | {:error, term()}
  @spec normalize(term(), schema()) :: {:ok, t()} | {:error, term()}
  def normalize(context, schema \\ nil)

  def normalize(context, nil) do
    case coerce_map(context) do
      {:ok, normalized} ->
        with :ok <- validate_default(normalized) do
          {:ok, normalized}
        end

      :error ->
        {:error, Jidoka.Error.invalid_context(:expected_map, value: context)}
    end
  end

  def normalize(context, schema) do
    with :ok <- validate_schema(schema),
         {:ok, normalized} <- normalize(context, nil),
         {:ok, parsed} <- parse_schema(schema, normalized),
         :ok <- validate_default(parsed) do
      {:ok, parsed}
    end
  end

  @spec defaults(schema()) :: {:ok, t()} | {:error, term()}
  def defaults(nil), do: {:ok, %{}}

  def defaults(schema) do
    with :ok <- validate_schema(schema),
         {:ok, defaults} <- parse_defaults(schema),
         :ok <- validate_default(defaults) do
      {:ok, defaults}
    end
  end

  @spec validate_schema(term()) :: :ok | {:error, term()}
  def validate_schema(nil), do: :ok

  def validate_schema(schema) do
    cond do
      not zoi_schema?(schema) ->
        {:error, Jidoka.Error.invalid_context_schema(:expected_zoi_schema, value: schema)}

      Zoi.Type.impl_for(schema) != Zoi.Type.Zoi.Types.Map ->
        {:error, Jidoka.Error.invalid_context_schema(:expected_zoi_map_schema, value: schema)}

      true ->
        :ok
    end
  end

  @spec reserved_keys() :: [String.t()]
  def reserved_keys, do: @reserved_keys

  @spec reserved_key?(atom() | String.t()) :: boolean()
  def reserved_key?(key), do: internal_key?(key)

  @spec schema_has_key?(schema(), atom() | String.t()) :: boolean()
  def schema_has_key?(nil, _key), do: false

  def schema_has_key?(%Zoi.Types.Map{fields: fields}, key) when is_list(fields) do
    Enum.any?(fields, fn {field, _schema} ->
      field == key or equivalent_keys?(field, key)
    end)
  end

  def schema_has_key?(_schema, _key), do: false

  @spec coerce_map(term()) :: {:ok, t()} | :error
  def coerce_map(context) when is_map(context), do: {:ok, context}

  def coerce_map(context) when is_list(context) do
    if Keyword.keyword?(context) do
      {:ok, Map.new(context)}
    else
      :error
    end
  end

  def coerce_map(_context), do: :error

  @spec merge(t(), t()) :: t()
  def merge(defaults, runtime) when is_map(defaults) and is_map(runtime) do
    Enum.reduce(runtime, defaults, fn {key, value}, acc ->
      acc
      |> drop_equivalent_keys(key)
      |> Map.put(key, value)
    end)
  end

  @spec validate_default(term()) :: :ok | {:error, Exception.t()}
  def validate_default(context) when is_map(context) do
    Enum.reduce_while(context, :ok, fn {key, _value}, :ok ->
      case validate_key(key) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def validate_default(other),
    do:
      {:error,
       Jidoka.Error.invalid_context_schema({:expected_map_result, other},
         value: other
       )}

  @spec strip_internal(t()) :: t()
  def strip_internal(context) when is_map(context) do
    Enum.reduce(Map.keys(context), context, fn key, acc ->
      if internal_key?(key) do
        Map.delete(acc, key)
      else
        acc
      end
    end)
  end

  @spec sanitize_for_subagent(t()) :: t()
  def sanitize_for_subagent(context) when is_map(context) do
    context
    |> strip_internal()
    |> Map.delete(:memory)
    |> Map.delete("memory")
  end

  defp validate_key(key) when is_atom(key) do
    validate_reserved_key(Atom.to_string(key))
  end

  defp validate_key(key) when is_binary(key) do
    trimmed = String.trim(key)

    cond do
      trimmed == "" ->
        {:error,
         Jidoka.Error.validation_error("context keys must not be empty strings",
           field: :context,
           value: key,
           details: %{reason: :empty_context_key}
         )}

      true ->
        validate_reserved_key(trimmed)
    end
  end

  defp validate_key(other),
    do:
      {:error,
       Jidoka.Error.validation_error("context keys must be atoms or strings, got: #{inspect(other)}",
         field: :context,
         value: other,
         details: %{reason: :invalid_context_key}
       )}

  defp validate_reserved_key(key) when key in @reserved_keys,
    do:
      {:error,
       Jidoka.Error.validation_error("context key #{key} is reserved for Jidoka internals",
         field: :context,
         value: key,
         details: %{reason: :reserved_context_key, key: key}
       )}

  defp validate_reserved_key(_key), do: :ok

  defp parse_defaults(schema) do
    context =
      schema
      |> Zoi.Context.new(%{})
      |> Zoi.Context.parse()

    case context.parsed do
      defaults when is_map(defaults) ->
        {:ok, defaults}

      other ->
        {:error, Jidoka.Error.invalid_context_schema({:expected_map_result, other}, value: schema)}
    end
  end

  defp parse_schema(schema, context) do
    case Zoi.parse(schema, coerce_schema_keys(schema, context)) do
      {:ok, parsed} when is_map(parsed) ->
        {:ok, parsed}

      {:ok, other} ->
        {:error, Jidoka.Error.invalid_context({:schema_result, :expected_map, other}, value: context)}

      {:error, errors} ->
        {:error, Jidoka.Error.invalid_context({:schema, Zoi.treefy_errors(errors)}, value: context)}
    end
  end

  defp zoi_schema?(schema) do
    is_struct(schema) and not is_nil(Zoi.Type.impl_for(schema))
  end

  defp coerce_schema_keys(%Zoi.Types.Map{fields: fields}, context)
       when is_list(fields) and is_map(context) do
    Map.new(context, fn {key, value} -> {schema_field_key(fields, key), value} end)
  end

  defp coerce_schema_keys(_schema, context), do: context

  defp schema_field_key(fields, key) do
    Enum.find_value(fields, key, fn {field, _schema} ->
      if equivalent_keys?(field, key), do: field
    end)
  end

  defp internal_key?(key) when is_atom(key) do
    internal_key?(Atom.to_string(key))
  end

  defp internal_key?(key) when is_binary(key), do: String.trim(key) in @reserved_keys
  defp internal_key?(_key), do: false

  defp drop_equivalent_keys(acc, key) do
    Enum.reduce(Map.keys(acc), acc, fn existing_key, memo ->
      if existing_key != key and equivalent_keys?(existing_key, key) do
        Map.delete(memo, existing_key)
      else
        memo
      end
    end)
  end

  defp equivalent_keys?(left, right) when is_atom(left) and is_binary(right),
    do: Atom.to_string(left) == right

  defp equivalent_keys?(left, right) when is_binary(left) and is_atom(right),
    do: left == Atom.to_string(right)

  defp equivalent_keys?(_left, _right), do: false
end
