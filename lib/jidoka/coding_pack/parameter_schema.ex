defmodule Jidoka.CodingPack.ParameterSchema do
  @moduledoc false

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.CodingPack.Error
  alias Jidoka.Effect.{Intent, Journal, OperationRequest}

  @schema_keys ["parameters_schema", :parameters_schema]

  @doc false
  @spec wrap(Operation.t(), function()) :: {:ok, function()} | {:error, Error.t()}
  def wrap(%Operation{} = operation, handler) do
    with {:ok, schema} <- fetch(operation),
         :ok <- closed_object(schema, operation.name),
         {:ok, root} <- build(schema, operation.name) do
      wrap_handler(operation.name, root, handler)
    end
  end

  defp fetch(%Operation{metadata: metadata, name: name}) do
    case Enum.find_value(@schema_keys, &Map.get(metadata, &1)) do
      schema when is_map(schema) -> {:ok, schema}
      _missing -> {:error, schema_error(name, :missing)}
    end
  end

  defp closed_object(schema, name) do
    properties = Map.get(schema, "properties")
    required = Map.get(schema, "required", [])

    if Map.get(schema, "type") == "object" and is_map(properties) and
         Map.get(schema, "additionalProperties") == false and is_list(required) and
         Enum.all?(required, &(is_binary(&1) and Map.has_key?(properties, &1))) do
      :ok
    else
      {:error, schema_error(name, :not_closed_object)}
    end
  end

  defp build(schema, name) do
    case JSV.build(schema, warnings: :silent) do
      {:ok, root} -> {:ok, root}
      {:error, _reason} -> {:error, schema_error(name, :invalid)}
    end
  end

  defp wrap_handler(name, root, handler) when is_function(handler, 2) do
    {:ok,
     fn arguments, context ->
       with :ok <- validate(arguments, name, root) do
         handler.(arguments, context)
       end
     end}
  end

  defp wrap_handler(name, root, handler) when is_function(handler, 3) do
    {:ok,
     fn %Intent{} = intent, %Journal{} = journal, context ->
       with {:ok, request} <- OperationRequest.from_input(intent.payload),
            :ok <- validate(request.arguments, name, root) do
         handler.(intent, journal, context)
       else
         {:error, %Error{} = error} -> {:error, error}
         {:error, _reason} -> {:error, arguments_error(name)}
       end
     end}
  end

  defp wrap_handler(name, _root, _handler),
    do: {:error, Error.new(:coding_tool_entry_invalid, %{id: name})}

  defp validate(arguments, name, root) when is_map(arguments) do
    with {:ok, arguments} <- string_keys(arguments),
         {:ok, _arguments} <- JSV.validate(arguments, root, cast: false) do
      :ok
    else
      _error -> {:error, arguments_error(name)}
    end
  end

  defp validate(_arguments, name, _root), do: {:error, arguments_error(name)}

  defp string_keys(arguments) do
    Enum.reduce_while(arguments, {:ok, %{}}, fn
      {key, value}, {:ok, normalized} when is_binary(key) or is_atom(key) ->
        key = to_string(key)

        if Map.has_key?(normalized, key),
          do: {:halt, :error},
          else: {:cont, {:ok, Map.put(normalized, key, value)}}

      _entry, _result ->
        {:halt, :error}
    end)
  end

  defp arguments_error(name),
    do: Error.new(:coding_tool_arguments_invalid, %{operation: name})

  defp schema_error(name, reason),
    do: Error.new(:coding_tool_schema_invalid, %{operation: name, reason: reason})
end
