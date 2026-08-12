defmodule Jidoka.ExecutionEnvironment.Contract do
  @moduledoc false

  @sensitive_words ~w(api_key apikey authorization credential credentials password private_key privatekey secret token)

  @doc "Validates that a value contains no live runtime terms."
  @spec validate_portable(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_portable(value, _opts \\ []) do
    case invalid_path(value, []) do
      nil -> :ok
      {path, type} -> {:error, "non-portable #{inspect(type)} at #{format_path(path)}"}
    end
  end

  @doc "Validates portable map data and rejects credential-like keys."
  @spec validate_safe_map(map(), keyword()) :: :ok | {:error, String.t()}
  def validate_safe_map(map, _opts \\ []) when is_map(map) do
    with :ok <- validate_portable(map), do: validate_keys(map, [])
  end

  @doc "Validates a nonnegative portable limit map."
  @spec validate_limits(map(), keyword()) :: :ok | {:error, String.t()}
  def validate_limits(map, opts \\ []) when is_map(map) do
    with :ok <- validate_safe_map(map, opts), do: validate_limit_values(map, [])
  end

  @doc "Validates that an opaque resource reference is not a raw host path."
  @spec validate_opaque_ref(String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_opaque_ref(value, _opts \\ []) when is_binary(value) do
    if String.starts_with?(value, ["/", "~/", "file:"]) or String.contains?(value, ["/../", "\\..\\"]) do
      {:error, "opaque reference cannot be a raw host path"}
    else
      :ok
    end
  end

  @doc "Validates an immutable lowercase SHA-256 digest."
  @spec validate_digest(String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_digest("sha256:" <> digest, _opts) do
    if byte_size(digest) == 64 and String.match?(digest, ~r/\A[0-9a-f]{64}\z/) do
      :ok
    else
      {:error, "digest must be sha256 followed by 64 lowercase hexadecimal characters"}
    end
  end

  def validate_digest(_value, _opts),
    do: {:error, "digest must use an immutable sha256 value"}

  @doc "Projects portable data with string keys and without credential-like fields."
  @spec project(term()) :: term()
  def project(%_{} = struct), do: struct |> Map.from_struct() |> project()

  def project(map) when is_map(map) do
    map
    |> Enum.reject(fn {key, _value} -> sensitive_key?(key) end)
    |> Map.new(fn {key, value} -> {project_key(key), project(value)} end)
  end

  def project(list) when is_list(list), do: Enum.map(list, &project/1)
  def project(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> project()
  def project(value) when is_boolean(value), do: value
  def project(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  def project(value), do: value

  defp invalid_path(value, path) when is_function(value), do: {Enum.reverse(path), :function}
  defp invalid_path(value, path) when is_pid(value), do: {Enum.reverse(path), :pid}
  defp invalid_path(value, path) when is_port(value), do: {Enum.reverse(path), :port}
  defp invalid_path(value, path) when is_reference(value), do: {Enum.reverse(path), :reference}
  defp invalid_path(%module{}, path), do: {Enum.reverse(path), {:struct, module}}

  defp invalid_path(value, path) when is_map(value) do
    Enum.find_value(value, fn {key, nested} ->
      invalid_path(key, [:key | path]) || invalid_path(nested, [key | path])
    end)
  end

  defp invalid_path(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.find_value(fn {nested, index} -> invalid_path(nested, [index | path]) end)
  end

  defp invalid_path(value, path) when is_tuple(value),
    do: value |> Tuple.to_list() |> invalid_path(path)

  defp invalid_path(_value, _path), do: nil

  defp validate_keys(map, path) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      case validate_key_value(key, value, path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_nested_key_value(key, value, path) when is_map(value),
    do: validate_keys(value, [key | path])

  defp validate_nested_key_value(key, value, path) when is_list(value),
    do: validate_list_keys(value, [key | path])

  defp validate_nested_key_value(_key, _value, _path), do: :ok

  defp validate_key_value(key, value, path) do
    case validate_key_name(key, path) do
      :ok -> validate_nested_key_value(key, value, path)
      {:error, _reason} = error -> error
    end
  end

  defp validate_key_name(key, path) do
    if sensitive_key?(key) do
      {:error, "credential-like key at #{format_path(Enum.reverse([key | path]))}"}
    else
      :ok
    end
  end

  defp validate_list_keys(list, path) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {%{} = map, index}, :ok ->
        case validate_keys(map, [index | path]) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      {_value, _index}, :ok ->
        {:cont, :ok}
    end)
  end

  defp sensitive_key?(key) do
    normalized =
      key
      |> to_string()
      |> Macro.underscore()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "")

    normalized in @sensitive_words or
      Enum.any?(@sensitive_words, &String.contains?(normalized, &1))
  end

  defp validate_limit_values(map, path) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      case validate_limit_value(key, value, path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_limit_value(key, value, path) when is_number(value) and value < 0,
    do: {:error, "negative limit at #{format_path(Enum.reverse([key | path]))}"}

  defp validate_limit_value(key, value, path) when is_map(value),
    do: validate_limit_values(value, [key | path])

  defp validate_limit_value(_key, _value, _path), do: :ok

  defp project_key(key) when is_atom(key), do: Atom.to_string(key)
  defp project_key(key), do: key

  defp format_path([]), do: "root"
  defp format_path(path), do: Enum.map_join(path, ".", &to_string/1)
end
