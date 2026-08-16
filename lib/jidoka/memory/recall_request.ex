defmodule Jidoka.Memory.RecallRequest do
  @moduledoc "Request sent to a memory store before prompt assembly."

  alias Jidoka.Schema
  alias Jidoka.Memory.Route

  @schema Zoi.struct(
            __MODULE__,
            %{
              route: Zoi.lazy({Route, :schema, []}),
              query: Schema.non_empty_string(),
              limit: Zoi.integer() |> Zoi.positive() |> Zoi.default(5),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a memory recall request."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a memory recall request from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- normalize_legacy_route(attrs) do
      Schema.parse(@schema, attrs)
    end
  end

  @doc "Builds a memory recall request and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, request} -> request
      {:error, reason} -> raise ArgumentError, "invalid memory recall request: #{inspect(reason)}"
    end
  end

  defp normalize_legacy_route(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    if Map.has_key?(attrs, :route) or Map.has_key?(attrs, "route") do
      {:ok, attrs}
    else
      agent_id = Map.get(attrs, :agent_id, Map.get(attrs, "agent_id"))
      session_id = Map.get(attrs, :session_id, Map.get(attrs, "session_id"))
      scope = Map.get(attrs, :scope, Map.get(attrs, "scope"))

      route_attrs =
        cond do
          is_binary(session_id) and scope in [nil, :session, "session"] ->
            %{kind: :session, agent_id: agent_id, session_id: session_id}

          scope in [:session, "session"] ->
            %{kind: :session, agent_id: agent_id}

          is_binary(session_id) ->
            {:error, {:ambiguous_legacy_memory_route, scope, session_id}}

          true ->
            %{kind: :agent, agent_id: agent_id}
        end

      with %{} = route_attrs <- route_attrs,
           {:ok, route} <- Route.new(route_attrs) do
        {:ok,
         attrs
         |> Map.drop([:agent_id, "agent_id", :session_id, "session_id", :scope, "scope"])
         |> Map.put(:route, route)}
      end
    end
  end
end
