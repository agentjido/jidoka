defmodule Jidoka.Extension.ProcessHost.Manifest do
  @moduledoc false

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.ExecutionEnvironment.Contract

  @enforce_keys [
    :tools,
    :tool_names,
    :commands,
    :command_names,
    :providers,
    :provider_names,
    :context?,
    :policy_advice?,
    :state,
    :result,
    :ui_data
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          tools: [Operation.t()],
          tool_names: MapSet.t(String.t()),
          commands: [String.t()],
          command_names: MapSet.t(String.t()),
          providers: [String.t()],
          provider_names: MapSet.t(String.t()),
          context?: boolean(),
          policy_advice?: boolean(),
          state: map(),
          result: map(),
          ui_data: map()
        }

  @doc false
  @spec new(map()) :: {:ok, t()} | {:error, {:invalid_process_extension_manifest, term()}}
  def new(raw) when is_map(raw) do
    with :ok <- Contract.validate_safe_map(raw),
         {:ok, tools} <- normalize_tools(get(raw, :tools, [])),
         {:ok, commands} <- normalize_names(get(raw, :commands, []), :commands),
         {:ok, providers} <- normalize_names(get(raw, :providers, []), :providers),
         {:ok, context?} <- normalize_boolean(get(raw, :context, false), :context),
         {:ok, policy_advice?} <- normalize_boolean(get(raw, :policy_advice, false), :policy_advice),
         {:ok, state} <- normalize_map(get(raw, :state, %{}), :state),
         {:ok, result} <- normalize_map(get(raw, :result, %{}), :result),
         {:ok, ui_data} <- normalize_map(get(raw, :ui_data, %{}), :ui_data) do
      {:ok,
       %__MODULE__{
         tools: tools,
         tool_names: MapSet.new(tools, & &1.name),
         commands: commands,
         command_names: MapSet.new(commands),
         providers: providers,
         provider_names: MapSet.new(providers),
         context?: context?,
         policy_advice?: policy_advice?,
         state: state,
         result: result,
         ui_data: ui_data
       }}
    else
      {:error, reason} -> {:error, {:invalid_process_extension_manifest, reason}}
    end
  rescue
    exception -> {:error, {:invalid_process_extension_manifest, exception}}
  end

  def new(value), do: {:error, {:invalid_process_extension_manifest, value}}

  defp normalize_tools(tools) when is_list(tools) do
    with {:ok, tools} <- map_ok(tools, &normalize_tool/1),
         true <- unique?(Enum.map(tools, & &1.name)) do
      {:ok, tools}
    else
      false -> {:error, :duplicate_tool_name}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_tools(value), do: {:error, {:invalid_tools, value}}

  defp normalize_tool(tool) when is_map(tool) do
    with {:ok, name} <- normalize_name(get(tool, :name), :tool),
         {:ok, description} <- normalize_description(get(tool, :description)),
         {:ok, idempotency} <- normalize_idempotency(get(tool, :idempotency, :idempotent)),
         {:ok, input_policy} <- normalize_map(get(tool, :input_policy, %{}), :input_policy),
         {:ok, operation} <-
           Operation.new(
             name: name,
             description: description,
             idempotency: idempotency,
             metadata: %{
               "source" => "process_extension",
               "input_policy" => input_policy
             }
           ) do
      {:ok, operation}
    end
  end

  defp normalize_tool(value), do: {:error, {:invalid_tool, value}}

  defp normalize_names(values, field) when is_list(values) do
    with {:ok, names} <- map_ok(values, &normalize_name(&1, field)),
         true <- unique?(names) do
      {:ok, names}
    else
      false -> {:error, {:duplicate_manifest_name, field}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_names(value, field), do: {:error, {:invalid_manifest_names, field, value}}

  defp normalize_name(value, field) when is_atom(value) and not is_nil(value),
    do: normalize_name(Atom.to_string(value), field)

  defp normalize_name(value, _field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :empty_manifest_name}
      name -> {:ok, name}
    end
  end

  defp normalize_name(value, field), do: {:error, {:invalid_manifest_name, field, value}}

  defp normalize_description(nil), do: {:ok, nil}
  defp normalize_description(value) when is_binary(value), do: {:ok, value}
  defp normalize_description(value), do: {:error, {:invalid_tool_description, value}}

  defp normalize_idempotency(value) when is_binary(value) do
    Enum.find(Operation.valid_idempotencies(), &(Atom.to_string(&1) == value))
    |> case do
      nil -> {:error, {:invalid_tool_idempotency, value}}
      idempotency -> {:ok, idempotency}
    end
  end

  defp normalize_idempotency(value) when value in [:pure, :idempotent, :dedupe, :reconcile, :unsafe_once],
    do: {:ok, value}

  defp normalize_idempotency(value), do: {:error, {:invalid_tool_idempotency, value}}

  defp normalize_boolean(value, _field) when is_boolean(value), do: {:ok, value}
  defp normalize_boolean(value, field), do: {:error, {:invalid_manifest_boolean, field, value}}

  defp normalize_map(value, _field) when is_map(value), do: {:ok, value}
  defp normalize_map(value, field), do: {:error, {:invalid_manifest_map, field, value}}

  defp map_ok(values, function) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, normalized} ->
      case function.(value) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp unique?(values), do: length(values) == length(Enum.uniq(values))

  defp get(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
