defmodule Jidoka.Agent.Message do
  @moduledoc """
  Durable chat message stored on agent state.

  Provider-facing runtimes may still project messages into provider-specific map
  shapes, but the agent session keeps a typed, serializable message contract.
  """

  alias Jidoka.ContentPart
  alias Jidoka.Effect
  alias Jidoka.Schema

  @roles [:system, :user, :assistant, :tool]

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Schema.non_empty_string() |> Zoi.nullish(),
              request_id: Schema.non_empty_string() |> Zoi.nullish(),
              role: Schema.atom_enum(@roles),
              content: Zoi.string() |> Zoi.nullish(),
              parts:
                Zoi.array(Zoi.lazy({ContentPart, :schema, []}))
                |> Zoi.default([]),
              operation: Schema.non_empty_string() |> Zoi.nullish(),
              output: Zoi.any() |> Zoi.nullish(),
              interaction: Zoi.lazy({Effect.ModelInteraction, :schema, []}) |> Zoi.nullish(),
              tool_call: Zoi.lazy({Effect.ToolCall, :schema, []}) |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type role :: :system | :user | :assistant | :tool
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for durable chat messages."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns the allowed chat message roles."
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc "Builds a validated durable chat message."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- normalize_parts(attrs),
         {:ok, %__MODULE__{} = message} <- Schema.parse(@schema, attrs),
         :ok <- validate(message) do
      {:ok, message}
    end
  end

  @doc "Builds a durable chat message or raises when validation fails."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, message} -> message
      {:error, reason} -> raise ArgumentError, "invalid agent message: #{inspect(reason)}"
    end
  end

  @doc "Normalizes an existing message, keyword list, or map into a durable chat message."
  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = message), do: new(message)
  def from_input(input), do: new(input)

  @doc "Builds a system message."
  @spec system(String.t() | [ContentPart.input()], keyword()) :: t()
  def system(content, opts \\ []), do: message!(:system, content, opts)

  @doc "Builds a user message."
  @spec user(String.t() | [ContentPart.input()], keyword()) :: t()
  def user(content, opts \\ []), do: message!(:user, content, opts)

  @doc "Builds an assistant message."
  @spec assistant(String.t() | [ContentPart.input()], keyword()) :: t()
  def assistant(content, opts \\ []), do: message!(:assistant, content, opts)

  @doc "Builds an assistant message that records one complete tool-call group."
  @spec assistant_tool_calls(Effect.ModelInteraction.t(), keyword()) :: t()
  def assistant_tool_calls(%Effect.ModelInteraction{} = interaction, opts \\ []) do
    new!(
      id: Keyword.get(opts, :id),
      request_id: Keyword.get(opts, :request_id),
      role: :assistant,
      content: tool_call_content(interaction),
      interaction: interaction,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @doc "Builds a tool result message for an operation output."
  @spec tool(String.t(), term(), keyword()) :: t()
  def tool(operation, output, opts \\ []) when is_binary(operation) do
    new!(
      role: :tool,
      id: Keyword.get(opts, :id),
      request_id: Keyword.get(opts, :request_id),
      content: Keyword.get(opts, :content, inspect(output)),
      operation: operation,
      output: output,
      tool_call: Keyword.get(opts, :tool_call),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @doc "Converts a message struct into a compact serializable map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = message) do
    message
    |> Map.from_struct()
    |> message_content(message)
    |> Map.drop([:parts, :id, :request_id, :interaction, :tool_call])
    |> Enum.reject(fn
      {_key, nil} -> true
      {:metadata, metadata} when metadata == %{} -> true
      {_key, _value} -> false
    end)
    |> Map.new()
  end

  defp message!(role, content, opts) when role in @roles and is_list(opts) do
    new!(
      role: role,
      id: Keyword.get(opts, :id),
      request_id: Keyword.get(opts, :request_id),
      content: content,
      parts: Keyword.get(opts, :parts, []),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp validate(%__MODULE__{role: role, content: content, parts: parts})
       when role in [:system, :user, :assistant] do
    if is_binary(content) or parts != [] do
      :ok
    else
      {:error, {:missing_message_content, role}}
    end
  end

  defp validate(%__MODULE__{role: :tool, operation: operation}) do
    if is_binary(operation) do
      :ok
    else
      {:error, :missing_tool_message_operation}
    end
  end

  defp normalize_parts(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    if is_map(attrs) do
      normalize_parts_map(attrs)
    else
      {:error, {:invalid_message_attributes, attrs}}
    end
  end

  defp normalize_parts_map(attrs) do
    content = Schema.get_key(attrs, :content)
    parts = Schema.get_key(attrs, :parts, [])

    cond do
      is_list(content) and content != [] ->
        put_normalized_parts(attrs, content, nil)

      is_list(parts) and parts != [] ->
        put_normalized_parts(attrs, parts, content)

      parts == [] ->
        {:ok, put_parts(attrs, [])}

      true ->
        {:error, {:invalid_message_parts, parts}}
    end
  end

  defp put_normalized_parts(attrs, inputs, content) do
    case ContentPart.from_inputs(inputs) do
      {:ok, parts} ->
        content = content || empty_to_nil(ContentPart.text_content(parts))

        {:ok,
         attrs
         |> Map.delete("content")
         |> Map.put(:content, content)
         |> put_parts(parts)}

      {:error, reason} ->
        {:error, {:invalid_message_parts, reason}}
    end
  end

  defp put_parts(attrs, parts) do
    attrs
    |> Map.delete("parts")
    |> Map.put(:parts, parts)
  end

  defp message_content(map, %__MODULE__{parts: []}), do: map
  defp message_content(map, %__MODULE__{parts: parts}), do: Map.put(map, :content, parts)

  defp tool_call_content(%Effect.ModelInteraction{} = interaction) do
    operations =
      for group <- interaction.tool_call_groups,
          call <- group.calls do
        %{"name" => call.name, "arguments" => call.arguments}
      end

    Jason.encode!(%{"type" => "operations", "operations" => operations})
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
