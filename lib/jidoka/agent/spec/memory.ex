defmodule Jidoka.Agent.Spec.Memory do
  @moduledoc """
  Conversation memory policy for an agent.

  The policy is definition data. Runtime stores are supplied per run through
  harness options.
  """

  alias Jidoka.Schema

  @scopes [:agent, :session]

  @schema Zoi.struct(
            __MODULE__,
            %{
              enabled: Zoi.boolean() |> Zoi.default(true),
              scope: Schema.atom_enum(@scopes) |> Zoi.default(:agent),
              max_entries: Zoi.integer() |> Zoi.positive() |> Zoi.default(5),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type scope :: :agent | :session
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec scopes() :: [scope()]
  def scopes, do: @scopes

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ []) do
    attrs =
      attrs
      |> Schema.normalize_attrs()
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
end
