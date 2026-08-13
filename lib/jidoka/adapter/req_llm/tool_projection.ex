defmodule Jidoka.Adapter.ReqLLM.ToolProjection do
  @moduledoc false

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Operation.Registry
  alias Jidoka.Schema

  @doc "Projects registry entries into inert ReqLLM tool declarations."
  @spec tools(Registry.t()) :: {:ok, [ReqLLM.Tool.t()]} | {:error, term()}
  def tools(%Registry{} = registry) do
    registry
    |> Registry.operations()
    |> Enum.reduce_while({:ok, []}, fn operation, {:ok, tools} ->
      case tool(operation) do
        {:ok, tool} -> {:cont, {:ok, [tool | tools]}}
        {:error, reason} -> {:halt, {:error, {:invalid_req_llm_tool, operation.name, reason}}}
      end
    end)
    |> case do
      {:ok, tools} -> {:ok, Enum.reverse(tools)}
      error -> error
    end
  end

  @doc "Builds a registry and ReqLLM tools from an assembled prompt."
  @spec from_prompt(map()) :: {:ok, [ReqLLM.Tool.t()]} | {:error, term()}
  def from_prompt(prompt) when is_map(prompt) do
    prompt
    |> Schema.get_key(:operations, [])
    |> prompt_operations()
    |> case do
      {:ok, operations} -> operations |> Registry.new() |> with_tools()
      error -> error
    end
  end

  @doc "Returns the canonical operation name for one projected provider name."
  @spec canonical_name(Registry.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def canonical_name(%Registry{} = registry, provider_name) when is_binary(provider_name) do
    registry
    |> Registry.operations()
    |> Enum.find(&(provider_name(&1.name) == provider_name))
    |> case do
      %Operation{name: name} -> {:ok, name}
      nil -> {:error, {:unknown_provider_tool_name, provider_name}}
    end
  end

  @doc "Returns a stable provider-safe name for a canonical operation name."
  @spec provider_name(String.t()) :: String.t()
  def provider_name(name) when is_binary(name) do
    if ReqLLM.Tool.valid_name?(name) do
      name
    else
      readable =
        name
        |> String.replace(~r/[^a-zA-Z0-9_-]+/u, "_")
        |> String.trim("_-")
        |> String.slice(0, 38)
        |> case do
          "" -> "operation"
          value -> value
        end

      hash = :crypto.hash(:sha256, name) |> Base.url_encode64(padding: false) |> binary_part(0, 12)
      "jidoka_#{readable}_#{hash}"
    end
  end

  defp with_tools({:ok, registry}), do: tools(registry)
  defp with_tools({:error, reason}), do: {:error, reason}

  defp tool(%Operation{} = operation) do
    metadata = operation.metadata || %{}

    ReqLLM.Tool.new(
      name: provider_name(operation.name),
      description: description(operation),
      parameter_schema: Registry.parameter_schema(operation) || [],
      callback: &deferred_callback/1,
      strict: strict?(metadata),
      provider_options: Schema.get_key(metadata, :provider_options, %{})
    )
  end

  defp prompt_operations(operations) when is_list(operations) do
    operations
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {contract, index}, {:ok, operations} ->
      case prompt_operation(contract) do
        {:ok, operation} -> {:cont, {:ok, [operation | operations]}}
        {:error, reason} -> {:halt, {:error, {:invalid_prompt_operation, index, reason}}}
      end
    end)
    |> case do
      {:ok, operations} -> {:ok, Enum.reverse(operations)}
      error -> error
    end
  end

  defp prompt_operations(operations), do: {:error, {:invalid_prompt_operations, operations}}

  defp prompt_operation(contract) when is_map(contract) do
    metadata =
      %{}
      |> maybe_put(:parameters_schema, Schema.get_key(contract, :parameters_schema))
      |> maybe_put(:strict, Schema.get_key(contract, :strict))
      |> maybe_put(:provider_options, Schema.get_key(contract, :provider_options))

    Operation.new(
      name: Schema.get_key(contract, :name),
      description: Schema.get_key(contract, :description),
      idempotency: Schema.get_key(contract, :idempotency, :idempotent),
      metadata: metadata
    )
  end

  defp prompt_operation(contract), do: {:error, {:invalid_operation_contract, contract}}

  defp strict?(metadata), do: Schema.get_key(metadata, :strict, false) == true

  defp description(%Operation{description: description, name: name}) do
    if is_binary(description) and String.trim(description) != "",
      do: description,
      else: "Run the #{name} operation."
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp deferred_callback(_arguments), do: {:error, :jidoka_runtime_dispatch_only}
end
