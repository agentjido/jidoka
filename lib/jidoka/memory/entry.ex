defmodule Jidoka.Memory.Entry do
  @moduledoc "Durable memory entry available to prompt assembly."

  alias Jidoka.Id
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Schema.non_empty_string(),
              agent_id: Schema.non_empty_string(),
              session_id: Schema.non_empty_string() |> Zoi.nullish(),
              content: Schema.non_empty_string(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a memory entry."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a memory entry and applies optional identifier defaults."
  @spec new(keyword() | map(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs, opts \\ []) do
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, attrs} <- put_id(attrs, opts) do
      Schema.parse(@schema, attrs)
    end
  end

  @doc "Builds a memory entry and raises if the attributes are invalid."
  @spec new!(keyword() | map(), keyword()) :: t()
  def new!(attrs, opts \\ []) do
    case new(attrs, opts) do
      {:ok, entry} -> entry
      {:error, reason} -> raise ArgumentError, "invalid memory entry: #{inspect(reason)}"
    end
  end

  @doc "Normalizes an existing memory entry, keyword list, or map."
  @spec from_input(t() | keyword() | map(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_input(input, opts \\ [])
  def from_input(%__MODULE__{} = entry, opts), do: new(entry, opts)
  def from_input(input, opts), do: new(input, opts)

  defp put_id(attrs, opts) do
    if Map.has_key?(attrs, :id) or Map.has_key?(attrs, "id") do
      {:ok, attrs}
    else
      with {:ok, id} <- Id.generate("mem", Keyword.get(opts, :id_generator)) do
        {:ok, Map.put(attrs, :id, id)}
      end
    end
  end
end
