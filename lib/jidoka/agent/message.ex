defmodule Jidoka.Agent.Message do
  @moduledoc """
  Durable chat message stored on agent state.

  Provider-facing runtimes may still project messages into provider-specific map
  shapes, but the agent session keeps a typed, serializable message contract.
  """

  alias Jidoka.Schema

  @roles [:system, :user, :assistant, :tool]

  @schema Zoi.struct(
            __MODULE__,
            %{
              role: Schema.atom_enum(@roles),
              content: Zoi.string() |> Zoi.nullish(),
              operation: Schema.non_empty_string() |> Zoi.nullish(),
              output: Zoi.any() |> Zoi.nullish(),
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
    with {:ok, %__MODULE__{} = message} <- Schema.parse(@schema, attrs),
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
  @spec system(String.t(), keyword()) :: t()
  def system(content, opts \\ []), do: message!(:system, content, opts)

  @doc "Builds a user message."
  @spec user(String.t(), keyword()) :: t()
  def user(content, opts \\ []), do: message!(:user, content, opts)

  @doc "Builds an assistant message."
  @spec assistant(String.t(), keyword()) :: t()
  def assistant(content, opts \\ []), do: message!(:assistant, content, opts)

  @doc "Builds a tool result message for an operation output."
  @spec tool(String.t(), term(), keyword()) :: t()
  def tool(operation, output, opts \\ []) when is_binary(operation) do
    new!(
      role: :tool,
      content: Keyword.get(opts, :content, inspect(output)),
      operation: operation,
      output: output,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @doc "Converts a message struct into a compact serializable map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = message) do
    message
    |> Map.from_struct()
    |> Enum.reject(fn
      {_key, nil} -> true
      {:metadata, metadata} when metadata == %{} -> true
      {_key, _value} -> false
    end)
    |> Map.new()
  end

  defp message!(role, content, opts) when role in @roles and is_binary(content) do
    new!(
      role: role,
      content: content,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp validate(%__MODULE__{role: role, content: content})
       when role in [:system, :user, :assistant] do
    if is_binary(content) do
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
end
