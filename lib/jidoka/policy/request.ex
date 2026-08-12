defmodule Jidoka.Policy.Request do
  @moduledoc """
  Portable request for an authoritative host policy decision.

  The request describes a protected effect without including credentials,
  executable capabilities, or live runtime handles.
  """

  alias Jidoka.Schema

  @version 1
  @effect_classes [:llm, :operation, :execution_environment, :extension_process]

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.literal(@version) |> Zoi.default(@version),
              effect_class: Schema.atom_enum(@effect_classes),
              action: Schema.non_empty_string(),
              resource: Zoi.map() |> Zoi.default(%{}),
              session_id: Schema.non_empty_string() |> Zoi.nullish(),
              request_id: Schema.non_empty_string(),
              intent_id: Schema.non_empty_string() |> Zoi.nullish(),
              advice: Zoi.map() |> Zoi.default(%{}),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )
          |> Zoi.refine({__MODULE__, :validate_portable, []})

  @type effect_class :: :llm | :operation | :execution_environment | :extension_process
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the current policy-request version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Returns the protected effect classes."
  @spec effect_classes() :: [effect_class()]
  def effect_classes, do: @effect_classes

  @doc "Returns the Zoi schema for a policy request."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a policy request from portable attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds a policy request and raises for invalid attributes."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "policy request")

  @doc false
  @spec validate_portable(t(), keyword()) :: :ok | {:error, String.t()}
  def validate_portable(%__MODULE__{} = request, _opts) do
    case portable_path(Map.take(request, [:resource, :advice, :metadata]), []) do
      nil -> :ok
      path -> {:error, "policy request contains a non-portable value at #{inspect(path)}"}
    end
  end

  defp portable_path(value, path)
       when is_function(value) or is_pid(value) or is_port(value) or is_reference(value),
       do: Enum.reverse(path)

  defp portable_path(%_{} = value, path), do: portable_path(Map.from_struct(value), path)

  defp portable_path(value, path) when is_map(value) do
    Enum.find_value(value, fn {key, nested} ->
      portable_path(key, [:key | path]) || portable_path(nested, [key | path])
    end)
  end

  defp portable_path(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.find_value(fn {nested, index} -> portable_path(nested, [index | path]) end)
  end

  defp portable_path(value, path) when is_tuple(value),
    do: value |> Tuple.to_list() |> portable_path(path)

  defp portable_path(_value, _path), do: nil
end
