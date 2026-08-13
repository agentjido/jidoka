defmodule Jidoka.Operation.Registry do
  @moduledoc """
  Canonical model-visible operation registry for one turn.

  The registry merges operations from the agent specification and trusted
  extension sources. It owns name uniqueness, prompt projection, lookup, and
  JSON Schema argument validation. Runtime handlers stay outside this pure data
  boundary.
  """

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Schema

  @enforce_keys [:operations, :by_name, :extension_names]
  defstruct operations: [], by_name: %{}, extension_names: MapSet.new()

  @type t :: %__MODULE__{
          operations: [Operation.t()],
          by_name: %{required(String.t()) => Operation.t()},
          extension_names: MapSet.t(String.t())
        }

  @doc "Builds one registry from static and extension operation lists."
  @spec new([Operation.t() | keyword() | map()], [Operation.t() | keyword() | map()]) ::
          {:ok, t()} | {:error, term()}
  def new(static_operations, extension_operations \\ [])

  def new(static_operations, extension_operations)
      when is_list(static_operations) and is_list(extension_operations) do
    with {:ok, static_operations} <- normalize_operations(static_operations),
         {:ok, extension_operations} <- normalize_operations(extension_operations),
         operations = static_operations ++ extension_operations,
         :ok <- validate_unique_names(operations),
         :ok <- validate_parameter_schemas(operations) do
      {:ok,
       %__MODULE__{
         operations: operations,
         by_name: Map.new(operations, &{&1.name, &1}),
         extension_names: MapSet.new(extension_operations, & &1.name)
       }}
    end
  end

  def new(static_operations, extension_operations),
    do: {:error, {:invalid_operation_registry, static_operations, extension_operations}}

  @doc "Builds one registry and raises when an operation contract is invalid."
  @spec new!([Operation.t() | keyword() | map()], [Operation.t() | keyword() | map()]) :: t()
  def new!(static_operations, extension_operations \\ []) do
    case new(static_operations, extension_operations) do
      {:ok, registry} -> registry
      {:error, reason} -> raise ArgumentError, "invalid operation registry: #{inspect(reason)}"
    end
  end

  @doc "Returns the registry operations in stable declaration order."
  @spec operations(t()) :: [Operation.t()]
  def operations(%__MODULE__{operations: operations}), do: operations

  @doc "Fetches one operation by its canonical name."
  @spec fetch(t(), String.t()) :: {:ok, Operation.t()} | {:error, term()}
  def fetch(%__MODULE__{by_name: by_name}, name) when is_binary(name) do
    case Map.fetch(by_name, name) do
      {:ok, operation} -> {:ok, operation}
      :error -> {:error, {:unknown_operation, name}}
    end
  end

  @doc "Returns true when an operation came from an extension source."
  @spec extension?(t(), String.t()) :: boolean()
  def extension?(%__MODULE__{extension_names: names}, name) when is_binary(name),
    do: MapSet.member?(names, name)

  @doc "Marks existing registry operations as extension-owned for runtime routing."
  @spec mark_extensions(t(), [Operation.t()]) :: {:ok, t()} | {:error, term()}
  def mark_extensions(%__MODULE__{} = registry, extension_operations) when is_list(extension_operations) do
    extension_operations
    |> Enum.reduce_while({:ok, MapSet.new()}, fn %Operation{} = extension, {:ok, names} ->
      case fetch(registry, extension.name) do
        {:ok, ^extension} -> {:cont, {:ok, MapSet.put(names, extension.name)}}
        {:ok, _stored} -> {:halt, {:error, {:operation_source_contract_mismatch, extension.name}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, names} -> {:ok, %__MODULE__{registry | extension_names: names}}
      error -> error
    end
  end

  @doc "Projects the registry into the provider-neutral prompt contract."
  @spec prompt_operations(t()) :: [map()]
  def prompt_operations(%__MODULE__{operations: operations}) do
    Enum.map(operations, fn %Operation{} = operation ->
      metadata = operation.metadata || %{}

      %{
        name: operation.name,
        description: operation.description,
        idempotency: operation.idempotency,
        parameters_schema: parameter_schema(operation),
        strict: Schema.get_key(metadata, :strict, false),
        provider_options: Schema.get_key(metadata, :provider_options, %{})
      }
    end)
  end

  @doc "Returns an operation JSON Schema, or nil when no schema is declared."
  @spec parameter_schema(Operation.t()) :: map() | nil
  def parameter_schema(%Operation{metadata: metadata}) when is_map(metadata) do
    case Schema.get_key(metadata, :parameters_schema) do
      schema when is_map(schema) -> normalize_json_value!(schema)
      _other -> nil
    end
  end

  @doc "Validates and normalizes one model-produced operation argument map."
  @spec validate_arguments(t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def validate_arguments(%__MODULE__{} = registry, name, arguments) when is_binary(name) do
    with {:ok, operation} <- fetch(registry, name),
         {:ok, arguments} <- normalize_argument_map(arguments) do
      validate_arguments_against_schema(operation, arguments)
    end
  end

  defp normalize_operations(operations) do
    operations
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {operation, index}, {:ok, normalized} ->
      case Operation.from_input(operation) do
        {:ok, operation} -> {:cont, {:ok, [operation | normalized]}}
        {:error, reason} -> {:halt, {:error, {:invalid_registry_operation, index, reason}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp validate_unique_names(operations) do
    operations
    |> Enum.reduce_while(MapSet.new(), fn %Operation{name: name}, seen ->
      if MapSet.member?(seen, name) do
        {:halt, {:error, {:duplicate_operation_name, name}}}
      else
        {:cont, MapSet.put(seen, name)}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_parameter_schemas(operations) do
    Enum.reduce_while(operations, :ok, fn operation, :ok ->
      case build_parameter_schema(operation) do
        {:ok, _root} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_parameter_schema(%Operation{} = operation) do
    case raw_parameter_schema(operation) do
      nil ->
        {:ok, nil}

      schema when is_map(schema) ->
        case JSV.build(normalize_json_value!(schema), warnings: :silent) do
          {:ok, root} -> {:ok, root}
          {:error, reason} -> {:error, {:invalid_operation_parameter_schema, operation.name, reason}}
        end

      schema ->
        {:error, {:invalid_operation_parameter_schema, operation.name, schema}}
    end
  rescue
    exception -> {:error, {:invalid_operation_parameter_schema, operation.name, exception}}
  end

  defp validate_arguments_against_schema(%Operation{} = operation, arguments) do
    schema = parameter_schema(operation)
    arguments = apply_schema_defaults(arguments, schema)

    with {:ok, root} <- build_parameter_schema(operation),
         :ok <- validate_built_schema(operation.name, arguments, root) do
      {:ok, arguments}
    end
  end

  defp validate_built_schema(_name, _arguments, nil), do: :ok

  defp validate_built_schema(name, arguments, root) do
    case JSV.validate(arguments, root, cast: false) do
      {:ok, _validated} -> :ok
      {:error, reason} -> {:error, {:invalid_operation_arguments, name, reason}}
    end
  rescue
    exception -> {:error, {:invalid_operation_arguments, name, exception}}
  end

  defp raw_parameter_schema(%Operation{metadata: metadata}) when is_map(metadata),
    do: Schema.get_key(metadata, :parameters_schema)

  defp apply_schema_defaults(value, %{"type" => "object", "properties" => properties})
       when is_map(value) and is_map(properties) do
    Enum.reduce(properties, value, fn {name, property_schema}, value ->
      case Map.fetch(value, name) do
        {:ok, current} -> Map.put(value, name, apply_schema_defaults(current, property_schema))
        :error -> maybe_put_schema_default(value, name, property_schema)
      end
    end)
  end

  defp apply_schema_defaults(value, %{"type" => "array", "items" => item_schema})
       when is_list(value),
       do: Enum.map(value, &apply_schema_defaults(&1, item_schema))

  defp apply_schema_defaults(value, _schema), do: value

  defp maybe_put_schema_default(value, name, %{"default" => default}),
    do: Map.put(value, name, default)

  defp maybe_put_schema_default(value, _name, _property_schema), do: value

  defp normalize_argument_map(arguments) when is_map(arguments) and not is_struct(arguments) do
    case normalize_json_value(arguments) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:invalid_operation_arguments, reason}}
    end
  end

  defp normalize_argument_map(arguments), do: {:error, {:invalid_operation_arguments, arguments}}

  defp normalize_json_value!(value) do
    case normalize_json_value(value) do
      {:ok, normalized} -> normalized
      {:error, reason} -> raise ArgumentError, "invalid JSON value: #{inspect(reason)}"
    end
  end

  defp normalize_json_value(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, normalized} ->
      with {:ok, key} <- normalize_json_key(key),
           false <- Map.has_key?(normalized, key),
           {:ok, item} <- normalize_json_value(item) do
        {:cont, {:ok, Map.put(normalized, key, item)}}
      else
        true -> {:halt, {:error, {:duplicate_json_key, key}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_json_value(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, normalized} ->
      case normalize_json_value(item) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_json_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp normalize_json_value(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp normalize_json_value(value), do: {:error, {:invalid_json_value, value}}

  defp normalize_json_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_json_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_json_key(key), do: {:error, {:invalid_json_key, key}}
end
