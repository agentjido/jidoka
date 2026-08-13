defmodule Jidoka.Effect.ToolCallGroup do
  @moduledoc """
  Durable ordered group of tool calls from one model interaction.

  A group always contains at least one call. Calls use zero-based indexes and
  must carry the same interaction and group identifiers as the group.
  """

  alias Jidoka.Effect
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              interaction_id: Schema.non_empty_string(),
              group_id: Schema.non_empty_string(),
              calls: Zoi.array(Zoi.lazy({Effect.ToolCall, :schema, []})),
              provider_metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a tool-call group."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds and validates a tool-call group."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, %__MODULE__{} = group} <- Schema.parse(@schema, attrs),
         :ok <- validate_calls(group) do
      {:ok, group}
    end
  end

  @doc "Builds a tool-call group and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, group} -> group
      {:error, reason} -> raise ArgumentError, "invalid tool-call group: #{inspect(reason)}"
    end
  end

  @doc "Normalizes an existing tool-call group, keyword list, or map."
  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = group), do: new(group)
  def from_input(input), do: new(input)

  @doc "Builds one ordered group from one or more operation requests."
  @spec from_operations([Effect.OperationRequest.t() | keyword() | map()], keyword()) ::
          {:ok, t()} | {:error, term()}
  def from_operations(operations, opts) when is_list(operations) and is_list(opts) do
    interaction_id = Keyword.get(opts, :interaction_id)
    group_id = Keyword.get(opts, :group_id)

    with :ok <- require_id(:interaction_id, interaction_id),
         :ok <- require_id(:group_id, group_id),
         {:ok, operation_requests} <- normalize_operations(operations) do
      calls =
        operation_requests
        |> Enum.with_index()
        |> Enum.map(fn {request, index} ->
          Effect.ToolCall.new!(
            interaction_id: interaction_id,
            group_id: group_id,
            provider_call_id: request.provider_call_id,
            call_index: index,
            name: request.name,
            arguments: request.arguments,
            provider_metadata: request.provider_metadata
          )
        end)

      new(
        interaction_id: interaction_id,
        group_id: group_id,
        calls: calls,
        provider_metadata: Keyword.get(opts, :provider_metadata, %{})
      )
    end
  end

  def from_operations(operations, _opts), do: {:error, {:invalid_tool_call_operations, operations}}

  @doc "Projects a tool-call group to durable data."
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = group) do
    %{
      interaction_id: group.interaction_id,
      group_id: group.group_id,
      calls: Enum.map(group.calls, &Effect.ToolCall.to_payload/1)
    }
    |> maybe_put_provider_metadata(group.provider_metadata)
  end

  defp validate_calls(%__MODULE__{calls: []}), do: {:error, :empty_tool_call_group}

  defp validate_calls(%__MODULE__{} = group) do
    expected_indexes = Enum.to_list(0..(length(group.calls) - 1))

    cond do
      Enum.any?(group.calls, &(&1.interaction_id != group.interaction_id)) ->
        {:error, :tool_call_interaction_mismatch}

      Enum.any?(group.calls, &(&1.group_id != group.group_id)) ->
        {:error, :tool_call_group_mismatch}

      Enum.map(group.calls, & &1.call_index) != expected_indexes ->
        {:error, :non_contiguous_tool_call_indexes}

      true ->
        :ok
    end
  end

  defp normalize_operations(operations) do
    operations
    |> Enum.reduce_while({:ok, []}, fn operation, {:ok, normalized} ->
      case Effect.OperationRequest.from_input(operation) do
        {:ok, request} -> {:cont, {:ok, [request | normalized]}}
        {:error, reason} -> {:halt, {:error, {:invalid_operation_request, reason}}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :empty_tool_call_group}
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp require_id(_field, id) when is_binary(id) and id != "", do: :ok
  defp require_id(field, value), do: {:error, {:invalid_tool_call_group_id, field, value}}

  defp maybe_put_provider_metadata(payload, metadata) when metadata == %{}, do: payload
  defp maybe_put_provider_metadata(payload, metadata), do: Map.put(payload, :provider_metadata, metadata)
end
