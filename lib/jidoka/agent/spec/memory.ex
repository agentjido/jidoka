defmodule Jidoka.Agent.Spec.Memory do
  @moduledoc """
  Conversation memory policy for an agent.

  The policy is definition data. Runtime stores are supplied per run through
  harness options.
  """

  alias Jidoka.Schema

  @scopes [:agent, :session]
  @captures [:manual, :conversation, :off]
  @injects [:instructions, :context]

  @schema Zoi.struct(
            __MODULE__,
            %{
              enabled: Zoi.boolean() |> Zoi.default(true),
              scope: Schema.atom_enum(@scopes) |> Zoi.default(:agent),
              namespace: Zoi.any() |> Zoi.nullish(),
              capture: Schema.atom_enum(@captures) |> Zoi.default(:manual),
              inject: Schema.atom_enum(@injects) |> Zoi.default(:instructions),
              max_entries: Zoi.integer() |> Zoi.positive() |> Zoi.default(5),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type scope :: :agent | :session
  @type capture :: :manual | :conversation | :off
  @type inject :: :instructions | :context
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec scopes() :: [scope()]
  def scopes, do: @scopes

  @spec captures() :: [capture()]
  def captures, do: @captures

  @spec injects() :: [inject()]
  def injects, do: @injects

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ []) do
    attrs =
      attrs
      |> Schema.normalize_attrs()
      |> normalize_v1_memory()
      |> normalize_max_entries()

    Schema.parse(@schema, attrs)
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs \\ []), do: Schema.parse!(@schema, attrs, "memory policy")

  @spec from_input(t() | keyword() | map() | true | false | nil) ::
          {:ok, t() | nil} | {:error, term()}
  def from_input(nil), do: {:ok, nil}
  def from_input(false), do: {:ok, nil}
  def from_input(true), do: new()
  def from_input(%__MODULE__{} = memory), do: new(memory)
  def from_input(input), do: new(input)

  @spec capture_conversation?(t() | nil) :: boolean()
  def capture_conversation?(%__MODULE__{enabled: true, capture: :conversation}), do: true
  def capture_conversation?(_memory), do: false

  defp normalize_max_entries(%{} = attrs) do
    value = Map.get(attrs, :max_entries, Map.get(attrs, "max_entries"))

    case value do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {integer, ""} when integer > 0 ->
            attrs
            |> Map.delete("max_entries")
            |> Map.put(:max_entries, integer)

          _other ->
            attrs
        end

      _value ->
        attrs
    end
  end

  defp normalize_v1_memory(%{} = attrs) do
    attrs
    |> normalize_v1_retrieve()
    |> normalize_v1_namespace()
  end

  defp normalize_v1_memory(attrs), do: attrs

  defp normalize_v1_retrieve(%{} = attrs) do
    retrieve = Map.get(attrs, :retrieve, Map.get(attrs, "retrieve"))
    max_entries = Map.get(attrs, :max_entries, Map.get(attrs, "max_entries"))

    cond do
      not is_nil(max_entries) ->
        attrs

      is_map(retrieve) ->
        limit = Map.get(retrieve, :limit, Map.get(retrieve, "limit"))

        if is_nil(limit) do
          attrs
        else
          Map.put(attrs, :max_entries, limit)
        end

      true ->
        attrs
    end
  end

  defp normalize_v1_namespace(%{} = attrs) do
    namespace = Map.get(attrs, :namespace, Map.get(attrs, "namespace"))

    case namespace do
      value when value in [:per_agent, "per_agent", nil] ->
        attrs

      value when value in [:session, "session"] ->
        put_scope(attrs, :session)

      value when value in [:shared, "shared"] ->
        shared = Map.get(attrs, :shared_namespace, Map.get(attrs, "shared_namespace"))

        attrs
        |> Map.delete("namespace")
        |> Map.put(:namespace, shared_namespace(shared))

      value when value in [:context, "context"] ->
        key = Map.get(attrs, :context_namespace_key, Map.get(attrs, "context_namespace_key"))

        attrs
        |> Map.delete("namespace")
        |> Map.put(:namespace, {:context, key})

      {:context, _key} ->
        attrs

      value when is_binary(value) ->
        attrs

      _other ->
        attrs
    end
  end

  defp put_scope(attrs, scope) do
    attrs
    |> Map.delete("scope")
    |> Map.put(:scope, scope)
  end

  defp shared_namespace(nil), do: nil
  defp shared_namespace(value), do: "shared:" <> String.trim(to_string(value))
end
