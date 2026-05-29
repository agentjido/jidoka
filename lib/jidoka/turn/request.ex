defmodule Jidoka.Turn.Request do
  @moduledoc "Input for one agent turn."

  alias Jidoka.Agent
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              input: Schema.non_empty_string(),
              request_id: Schema.non_empty_string(),
              agent_state: Zoi.lazy({Agent.State, :schema, []}),
              context: Zoi.map() |> Zoi.default(%{}),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    Schema.parse(@schema, prepare_attrs(attrs))
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, prepare_attrs(attrs), "turn request")

  @spec from_input(t() | String.t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = request), do: new(request)
  def from_input(input) when is_binary(input), do: new(input: input)
  def from_input(input), do: new(input)

  defp prepare_attrs(attrs) do
    attrs
    |> Schema.normalize_attrs()
    |> Schema.put_default(:request_id, default_id())
    |> Schema.put_default(:agent_state, Agent.State.new!())
  end

  defp default_id, do: "turn_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
end
