defmodule Jidoka.Handoff do
  @moduledoc """
  Data contract for conversation ownership transfer.

  A handoff is different from a subagent call. Subagents delegate one bounded
  task inside the current turn. Handoffs record that future turns for a
  conversation should be owned by another agent until the owner is reset.
  """

  alias Jidoka.Id
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Schema.non_empty_string(),
              conversation_id: Schema.non_empty_string() |> Zoi.nullish(),
              from_agent: Zoi.any() |> Zoi.nullish(),
              to_agent: Zoi.atom(),
              to_agent_id: Schema.non_empty_string(),
              name: Schema.non_empty_string(),
              message: Schema.non_empty_string(),
              summary: Zoi.string() |> Zoi.nullish(),
              reason: Zoi.string() |> Zoi.nullish(),
              context: Zoi.map() |> Zoi.default(%{}),
              request_id: Schema.non_empty_string() |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs, opts \\ []) do
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, attrs} <- put_id(attrs, opts) do
      Schema.parse(@schema, attrs)
    end
  end

  @spec new!(keyword() | map(), keyword()) :: t()
  def new!(attrs, opts \\ []) do
    case new(attrs, opts) do
      {:ok, handoff} -> handoff
      {:error, reason} -> raise ArgumentError, "invalid handoff: #{inspect(reason)}"
    end
  end

  @spec from_input(t() | keyword() | map(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_input(input, opts \\ [])
  def from_input(%__MODULE__{} = handoff, opts), do: new(handoff, opts)
  def from_input(input, opts), do: new(input, opts)

  defp put_id(attrs, opts) do
    if Map.has_key?(attrs, :id) or Map.has_key?(attrs, "id") do
      {:ok, attrs}
    else
      with {:ok, id} <- Id.generate("handoff", Keyword.get(opts, :id_generator)) do
        {:ok, Map.put(attrs, :id, id)}
      end
    end
  end
end
