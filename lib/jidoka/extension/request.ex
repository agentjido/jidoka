defmodule Jidoka.Extension.Request do
  @moduledoc """
  Inert data request for one trusted host extension.

  Import preserves this value. It does not resolve code, load a module, or
  start a process.
  """

  alias Jidoka.Schema

  @version 1
  @max_config_bytes 65_536
  @max_depth 16
  @id_regex ~r/^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)+$/
  @keys [
    :version,
    :id,
    :instance_id,
    :config,
    :mode,
    :enabled,
    "version",
    "id",
    "instance_id",
    "config",
    "mode",
    "enabled"
  ]

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.literal(@version) |> Zoi.default(@version),
              id: Schema.non_empty_string() |> Zoi.regex(@id_regex),
              instance_id: Schema.non_empty_string() |> Zoi.regex(@id_regex) |> Zoi.nullish(),
              config: Zoi.map() |> Zoi.default(%{}),
              mode: Schema.atom_enum([:both, :interactive, :automation]) |> Zoi.default(:both),
              enabled: Zoi.boolean() |> Zoi.default(true)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the versioned request schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds an inert request from JSON-like data."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    with :ok <- validate_keys(attrs),
         {:ok, %__MODULE__{} = request} <- Schema.parse(@schema, attrs),
         :ok <- validate_ids(request),
         :ok <- validate_config(request.config) do
      {:ok, request}
    end
  end

  @doc "Builds an inert request and raises for invalid data."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, request} -> request
      {:error, reason} -> raise ArgumentError, "invalid extension request: #{inspect(reason)}"
    end
  end

  @doc "Returns the stable instance key used for duplicate checks."
  @spec instance_key(t()) :: String.t()
  def instance_key(%__MODULE__{id: id, instance_id: nil}), do: id
  def instance_key(%__MODULE__{instance_id: instance_id}), do: instance_id

  @doc "Projects the request as JSON-safe string-key data."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = request) do
    %{
      "version" => request.version,
      "id" => request.id,
      "instance_id" => request.instance_id,
      "config" => request.config,
      "mode" => Atom.to_string(request.mode),
      "enabled" => request.enabled
    }
  end

  @doc "Validates an ordered request list and rejects duplicate instance keys."
  @spec normalize_list(term()) :: {:ok, [t()]} | {:error, term()}
  def normalize_list(requests) when is_list(requests) do
    requests
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, &normalize_request/2)
    |> case do
      {:ok, requests, _seen} -> {:ok, Enum.reverse(requests)}
      {:error, _reason} = error -> error
    end
  end

  def normalize_list(value), do: {:error, {:invalid_extension_requests, value}}

  defp normalize_request({input, index}, {:ok, acc, seen}) do
    case new(input) do
      {:ok, request} -> add_request(request, acc, seen)
      {:error, reason} -> {:halt, {:error, {:invalid_extension_request, index, reason}}}
    end
  end

  defp add_request(request, acc, seen) do
    key = instance_key(request)

    if MapSet.member?(seen, key) do
      {:halt, {:error, {:duplicate_extension_request, key}}}
    else
      {:cont, {:ok, [request | acc], MapSet.put(seen, key)}}
    end
  end

  defp validate_keys(attrs) when is_map(attrs) do
    case Map.keys(attrs) -- @keys do
      [] -> :ok
      keys -> {:error, {:unknown_extension_request_keys, Enum.map(keys, &to_string/1) |> Enum.sort()}}
    end
  end

  defp validate_ids(%__MODULE__{id: id, instance_id: instance_id}) do
    if Regex.match?(@id_regex, id) and
         (is_nil(instance_id) or Regex.match?(@id_regex, instance_id)) do
      :ok
    else
      {:error, {:invalid_extension_request_id, id, instance_id}}
    end
  end

  defp validate_config(config) do
    with :ok <- validate_json_value(config),
         {:ok, encoded} <- Jason.encode(config),
         true <- byte_size(encoded) <= @max_config_bytes,
         true <- json_depth(config) <= @max_depth do
      :ok
    else
      {:error, reason} -> {:error, {:nonportable_extension_config, reason}}
      false -> {:error, :extension_config_limit_exceeded}
    end
  end

  defp validate_json_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: :ok

  defp validate_json_value(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn item, :ok ->
      case validate_json_value(item) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_json_value(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, :ok, fn
      {key, item}, :ok when is_binary(key) ->
        case validate_json_value(item) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      {key, _item}, :ok ->
        {:halt, {:error, {:nonportable_extension_config_key, key}}}
    end)
  end

  defp validate_json_value(value),
    do: {:error, {:nonportable_extension_config_value, value}}

  defp json_depth(value) when is_map(value) do
    1 + Enum.reduce(value, 0, fn {_key, item}, depth -> max(depth, json_depth(item)) end)
  end

  defp json_depth(value) when is_list(value),
    do: 1 + Enum.reduce(value, 0, fn item, depth -> max(depth, json_depth(item)) end)

  defp json_depth(_value), do: 0
end
