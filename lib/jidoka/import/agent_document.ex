defmodule Jidoka.Import.AgentDocument do
  @moduledoc """
  Portable JSON/YAML authoring document for a Jidoka agent.

  The document intentionally stores only data. Runtime-only values such as Zoi
  schemas and Jido action modules are referenced by name and resolved through
  explicit registries in `Jidoka.Import`.
  """

  alias Jidoka.Schema

  @version 1

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.integer() |> Zoi.positive() |> Zoi.default(@version),
              agent: Zoi.map(),
              tools: Zoi.map() |> Zoi.default(%{}),
              controls: Zoi.map() |> Zoi.default(%{}),
              operations: Zoi.array(Zoi.map()) |> Zoi.default([]),
              runtime_defaults: Zoi.map() |> Zoi.default(%{}),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a portable agent document."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns the current portable document format version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Builds a portable agent document from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, %__MODULE__{} = document} <- Schema.parse(@schema, attrs),
         :ok <- validate_version(document) do
      {:ok, document}
    end
  end

  @doc "Builds a portable agent document and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, document} ->
        document

      {:error, reason} ->
        raise ArgumentError, "invalid imported agent document: #{inspect(reason)}"
    end
  end

  defp validate_version(%__MODULE__{version: @version}), do: :ok

  defp validate_version(%__MODULE__{version: version}) do
    {:error, {:unsupported_import_document_version, version, @version}}
  end
end
