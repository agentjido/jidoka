defmodule Jidoka.Snapshot.Codec do
  @moduledoc false

  @serialized_prefix "jidoka:snapshot:v1:"
  @signature_algorithm :sha256
  @minimum_signing_secret_bytes 32

  @doc false
  @spec serialized_prefix() :: String.t()
  def serialized_prefix, do: @serialized_prefix

  @spec serialize(term()) :: {:ok, String.t()} | {:error, term()}
  def serialize(snapshot) do
    with :ok <- validate_portable(snapshot),
         {:ok, secret} <- signing_secret() do
      encoded = snapshot |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
      {:ok, @serialized_prefix <> encoded <> "." <> signature(encoded, secret)}
    end
  end

  @spec deserialize(String.t()) :: {:ok, term()} | {:error, term()}
  def deserialize(@serialized_prefix <> signed_payload) do
    with {:ok, encoded, given_signature} <- split_signed_payload(signed_payload),
         {:ok, secret} <- signing_secret(),
         :ok <- verify_signature(encoded, given_signature, secret),
         {:ok, binary} <- Base.url_decode64(encoded, padding: false) do
      safe_binary_to_term(binary)
    end
  end

  def deserialize(_input), do: {:error, :invalid_snapshot_serialization}

  defp safe_binary_to_term(binary) when is_binary(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    error -> {:error, {:invalid_snapshot_serialization, error}}
  end

  defp split_signed_payload(payload) do
    case String.split(payload, ".", parts: 2) do
      [encoded, signature] when encoded != "" and signature != "" ->
        {:ok, encoded, signature}

      _other ->
        {:error, :invalid_snapshot_signature}
    end
  end

  defp signing_secret do
    secret =
      Application.get_env(:jidoka, :snapshot_signing_secret) ||
        System.get_env("JIDOKA_SNAPSHOT_SIGNING_SECRET")

    cond do
      is_binary(secret) and byte_size(secret) >= @minimum_signing_secret_bytes ->
        {:ok, secret}

      is_binary(secret) ->
        {:error, {:invalid_snapshot_signing_secret, @minimum_signing_secret_bytes}}

      true ->
        {:error, :missing_snapshot_signing_secret}
    end
  end

  defp signature(encoded, secret) when is_binary(encoded) and is_binary(secret) do
    :crypto.mac(:hmac, @signature_algorithm, secret, encoded)
    |> Base.url_encode64(padding: false)
  end

  defp verify_signature(encoded, given_signature, secret) do
    expected_signature = signature(encoded, secret)

    if secure_compare(given_signature, expected_signature) do
      :ok
    else
      {:error, :invalid_snapshot_signature}
    end
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {a, b}, acc -> Bitwise.bor(acc, Bitwise.bxor(a, b)) end)
    |> Kernel.==(0)
  end

  defp secure_compare(_left, _right), do: false

  defp validate_portable(value), do: validate_portable(value, [])

  defp validate_portable(value, path)
       when is_function(value) or is_pid(value) or is_port(value) or is_reference(value) do
    {:error, {:non_serializable_snapshot_value, Enum.reverse(path), portable_type(value)}}
  end

  defp validate_portable(tuple, path) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> validate_portable(path)
  end

  defp validate_portable(%_{} = struct, path) do
    struct |> Map.from_struct() |> validate_portable(path)
  end

  defp validate_portable(%{} = map, path) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      with :ok <- validate_portable(key, [:key | path]),
           :ok <- validate_portable(value, [key | path]) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_portable(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case validate_portable(value, [index | path]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_portable(_value, _path), do: :ok

  defp portable_type(value) when is_function(value), do: :function
  defp portable_type(value) when is_pid(value), do: :pid
  defp portable_type(value) when is_port(value), do: :port
  defp portable_type(value) when is_reference(value), do: :reference
end
