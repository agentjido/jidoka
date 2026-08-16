defmodule Jidoka.Memory.WriteRequest do
  @moduledoc """
  Request to write one memory entry.

  Stores must treat repeated writes with the same non-null `idempotency_key` as
  one logical write and return the first visible entry.
  """

  alias Jidoka.Memory.Entry
  alias Jidoka.Memory.Route
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              entry: Zoi.lazy({Entry, :schema, []}),
              route: Zoi.lazy({Route, :schema, []}),
              idempotency_key: Schema.non_empty_string() |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a memory write request."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a memory write request from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, attrs} <- put_legacy_route(attrs) do
      Schema.parse(@schema, attrs)
    end
  end

  @doc "Builds a memory write request and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, request} -> request
      {:error, reason} -> raise ArgumentError, "invalid memory write request: #{inspect(reason)}"
    end
  end

  defp put_legacy_route(attrs) do
    if Map.has_key?(attrs, :route) or Map.has_key?(attrs, "route") do
      {:ok, attrs}
    else
      entry = Map.get(attrs, :entry, Map.get(attrs, "entry"))

      with {:ok, %Entry{} = entry} <- Entry.from_input(entry),
           {:ok, route} <- legacy_entry_route(entry) do
        {:ok, Map.put(attrs, :route, route)}
      end
    end
  end

  defp legacy_entry_route(%Entry{agent_id: agent_id, session_id: session_id})
       when is_binary(session_id),
       do: Route.new(kind: :session, agent_id: agent_id, session_id: session_id)

  defp legacy_entry_route(%Entry{agent_id: agent_id}),
    do: Route.new(kind: :agent, agent_id: agent_id)
end
