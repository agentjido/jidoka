defmodule Jidoka.Memory.Compaction do
  @moduledoc """
  Serializable compaction snapshot with source-message provenance.

  This is a data contract only in the first memory slice. Runtime compaction
  policy can build on this without changing snapshot shape.
  """

  alias Jidoka.Id
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Schema.non_empty_string(),
              agent_id: Schema.non_empty_string(),
              summary: Schema.non_empty_string(),
              source_message_ids: Zoi.array(Schema.non_empty_string()) |> Zoi.default([]),
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
      {:ok, compaction} -> compaction
      {:error, reason} -> raise ArgumentError, "invalid memory compaction: #{inspect(reason)}"
    end
  end

  defp put_id(attrs, opts) do
    if Map.has_key?(attrs, :id) or Map.has_key?(attrs, "id") do
      {:ok, attrs}
    else
      with {:ok, id} <- Id.generate("cmp", Keyword.get(opts, :id_generator)) do
        {:ok, Map.put(attrs, :id, id)}
      end
    end
  end
end
