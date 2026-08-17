defmodule Jidoka.Memory.Route do
  @moduledoc "A closed memory partition route."

  alias Jidoka.Schema

  @kinds [:agent, :session, :namespace]

  @base_schema Zoi.struct(
                 __MODULE__,
                 %{
                   kind: Schema.atom_enum(@kinds),
                   agent_id: Schema.non_empty_string(),
                   session_id: Schema.non_empty_string() |> Zoi.nullish(),
                   namespace: Schema.non_empty_string() |> Zoi.nullish()
                 },
                 coerce: true
               )

  @schema Zoi.refine(@base_schema, {__MODULE__, :validate_fields, []})

  @type kind :: :agent | :session | :namespace
  @type t :: unquote(Zoi.type_spec(@base_schema))
  @enforce_keys Zoi.Struct.enforce_keys(@base_schema)
  defstruct Zoi.Struct.struct_fields(@base_schema)

  @doc "Returns the Zoi schema for a memory route."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds and validates a memory route."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, %__MODULE__{} = route} <- Schema.parse(@base_schema, attrs),
         :ok <- validate(route) do
      {:ok, route}
    end
  end

  @doc "Builds a memory route and raises if it is invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, route} -> route
      {:error, reason} -> raise ArgumentError, "invalid memory route: #{inspect(reason)}"
    end
  end

  @doc "Returns the canonical private partition key."
  @spec key(t()) :: tuple()
  def key(%__MODULE__{kind: :agent, agent_id: agent_id}), do: {:agent, agent_id}

  def key(%__MODULE__{kind: :session, agent_id: agent_id, session_id: session_id}),
    do: {:session, agent_id, session_id}

  def key(%__MODULE__{kind: :namespace, namespace: namespace}),
    do: {:namespace, namespace}

  @doc false
  @spec validate_fields(t(), keyword()) :: :ok | {:error, String.t()}
  def validate_fields(%__MODULE__{} = route, _opts) do
    case validate(route) do
      :ok -> :ok
      {:error, reason} -> {:error, "invalid memory route fields: #{inspect(reason)}"}
    end
  end

  defp validate(%__MODULE__{kind: :agent, session_id: nil, namespace: nil}), do: :ok

  defp validate(%__MODULE__{kind: :session, session_id: session_id, namespace: nil})
       when is_binary(session_id),
       do: :ok

  defp validate(%__MODULE__{kind: :namespace, session_id: nil, namespace: namespace})
       when is_binary(namespace),
       do: :ok

  defp validate(%__MODULE__{kind: :session, session_id: nil}),
    do: {:error, :missing_memory_route_session_id}

  defp validate(%__MODULE__{kind: :namespace, namespace: nil}),
    do: {:error, :missing_memory_route_namespace}

  defp validate(%__MODULE__{} = route), do: {:error, {:conflicting_memory_route_fields, route}}
end
