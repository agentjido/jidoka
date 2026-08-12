defmodule Jidoka.Import.AgentDocument do
  @moduledoc """
  Portable JSON/YAML authoring document for a Jidoka agent.

  The document intentionally stores only data. Runtime-only values such as Zoi
  schemas and Jido action modules are referenced by name and resolved through
  explicit registries in `Jidoka.Import`.
  """

  alias Jidoka.Schema
  alias Jidoka.Extension.Request

  @version 1
  @forbidden_document_keys ~w(execution_environment adapter backend command image mount mounts network)
  @forbidden_agent_keys ~w(execution_environment adapter backend command image mount mounts network)

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.integer() |> Zoi.positive() |> Zoi.default(@version),
              agent: Zoi.map(),
              tools: Zoi.map() |> Zoi.default(%{}),
              controls: Zoi.map() |> Zoi.default(%{}),
              operations: Zoi.array(Zoi.map()) |> Zoi.default([]),
              extensions: Zoi.array(Zoi.map()) |> Zoi.default([]),
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
    attrs = Schema.normalize_attrs(attrs)

    with :ok <- reject_keys(attrs, @forbidden_document_keys),
         {:ok, %__MODULE__{} = document} <- Schema.parse(@schema, attrs),
         :ok <- validate_version(document),
         :ok <- validate_execution_profile(document.agent),
         {:ok, extensions} <- Request.normalize_list(document.extensions),
         :ok <- reject_keys(document.agent, @forbidden_agent_keys) do
      {:ok, %__MODULE__{document | extensions: Enum.map(extensions, &Request.to_map/1)}}
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

  defp validate_execution_profile(agent) do
    case Schema.get_key(agent, :execution_profile) do
      nil -> :ok
      profile when is_binary(profile) and profile != "" -> :ok
      profile -> {:error, {:invalid_execution_profile, profile}}
    end
  end

  defp reject_keys(attrs, forbidden_keys) do
    keys = attrs |> Map.keys() |> Enum.map(&to_string/1)

    case keys -- (keys -- forbidden_keys) do
      [] -> :ok
      forbidden -> {:error, {:forbidden_execution_profile_keys, Enum.sort(forbidden)}}
    end
  end
end
