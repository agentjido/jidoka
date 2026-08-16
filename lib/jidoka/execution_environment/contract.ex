defmodule Jidoka.ExecutionEnvironment.Contract do
  @moduledoc false

  @sensitive_words ~w(api_key apikey authorization credential credentials password private_key privatekey secret token)

  @doc "Validates that a value contains no live runtime terms."
  @spec validate_portable(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_portable(value, _opts \\ []) do
    validate(value, portable: true)
  end

  @doc "Validates portable map data and rejects credential-like keys."
  @spec validate_safe_map(map(), keyword()) :: :ok | {:error, String.t()}
  def validate_safe_map(map, _opts \\ []) when is_map(map) do
    validate(map, portable: true, safe_keys: true)
  end

  @doc "Validates a nonnegative portable limit map."
  @spec validate_limits(map(), keyword()) :: :ok | {:error, String.t()}
  def validate_limits(map, _opts \\ []) when is_map(map) do
    validate(map, portable: true, safe_keys: true, nonnegative: true)
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

  defp validate(value, rules) do
    case walk(value, [], Map.new(rules)) do
      :ok -> :ok
      {:error, failure} -> {:error, format_failure(failure)}
    end
  end

  defp walk(%module{}, path, _rules),
    do: {:error, {:non_portable, path, {:struct, module}}}

  defp walk(map, path, rules) when is_map(map) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      with :ok <- validate_map_key(key, path, rules),
           :ok <- walk(value, path ++ [key], rules) do
        {:cont, :ok}
      else
        {:error, _failure} = error -> {:halt, error}
      end
    end)
  end

  defp walk(list, path, rules) when is_list(list), do: walk_sequence(list, path, rules)

  defp walk(tuple, path, rules) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> walk_sequence(path, rules)

  defp walk(value, path, rules) do
    cond do
      Map.get(rules, :nonnegative, false) and is_number(value) and value < 0 ->
        {:error, {:negative_limit, path, value}}

      portable_leaf?(value) ->
        :ok

      true ->
        {:error, {:non_portable, path, runtime_type(value)}}
    end
  end

  defp walk_sequence(values, path, rules) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case walk(value, path ++ [index], rules) do
        :ok -> {:cont, :ok}
        {:error, _failure} = error -> {:halt, error}
      end
    end)
  end

  defp validate_map_key(key, path, rules) do
    cond do
      not portable_key?(key) ->
        {:error, {:invalid_key, path ++ [{:key, key}], key}}

      Map.get(rules, :safe_keys, false) and sensitive_key?(key) ->
        {:error, {:credential_key, path ++ [key], key}}

      true ->
        :ok
    end
  end

  defp portable_key?(key), do: is_binary(key) or is_atom(key) or is_integer(key)

  defp portable_leaf?(value) do
    is_nil(value) or is_boolean(value) or is_binary(value) or is_number(value) or is_atom(value)
  end

  defp runtime_type(value) when is_function(value), do: :function
  defp runtime_type(value) when is_pid(value), do: :pid
  defp runtime_type(value) when is_port(value), do: :port
  defp runtime_type(value) when is_reference(value), do: :reference
  defp runtime_type(value) when is_bitstring(value), do: :bitstring
  defp runtime_type(_value), do: :unsupported

  defp format_failure({:non_portable, path, type}),
    do: "non-portable #{inspect(type)} at #{format_path(path)}"

  defp format_failure({:invalid_key, path, key}),
    do: "invalid portable map key #{inspect(key)} at #{format_path(path)}"

  defp format_failure({:credential_key, path, _key}),
    do: "credential-like key at #{format_path(path)}"

  defp format_failure({:negative_limit, path, _value}),
    do: "negative limit at #{format_path(path)}"

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

  defp project_key(key) when is_atom(key), do: Atom.to_string(key)
  defp project_key(key), do: key

  defp format_path([]), do: "root"

  defp format_path(path) do
    Enum.reduce(path, "root", fn
      index, path when is_integer(index) -> path <> "[#{index}]"
      {:key, key}, path -> path <> ".key(#{inspect(key)})"
      key, path -> path <> "." <> to_string(key)
    end)
  end
end
