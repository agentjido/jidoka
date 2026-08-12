defmodule Jidoka.Replay.Codec do
  @moduledoc false

  alias Jidoka.ExecutionEnvironment.Contract

  @sensitive_words ~w(api_key apikey authorization credential credentials password private_key privatekey secret token)
  @atom_tag "$jidoka.atom"
  @tuple_tag "$jidoka.tuple"

  @doc false
  @spec encode(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def encode(value, opts \\ []) do
    with {:ok, encoded} <- encode_value(value, string_redactions(opts)),
         :ok <- Contract.validate_portable(encoded) do
      {:ok, encoded}
    end
  end

  @doc false
  @spec decode(term()) :: {:ok, term()} | {:error, term()}
  def decode(value), do: decode_value(value)

  @doc false
  @spec digest(term()) :: String.t()
  def digest(value) do
    bytes = value |> canonical() |> :erlang.term_to_binary([:deterministic])
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end

  defp encode_value(value, _redactions) when is_nil(value) or is_boolean(value) or is_number(value), do: {:ok, value}

  defp encode_value(value, redactions) when is_binary(value) do
    if String.valid?(value) do
      {:ok, Enum.reduce(redactions, value, &String.replace(&2, &1, "[REDACTED]"))}
    else
      {:error, :invalid_utf8}
    end
  end

  defp encode_value(value, _redactions) when is_atom(value), do: {:ok, %{@atom_tag => Atom.to_string(value)}}

  defp encode_value(value, redactions) when is_tuple(value) do
    with {:ok, items} <- encode_list(Tuple.to_list(value), redactions) do
      {:ok, %{@tuple_tag => items}}
    end
  end

  defp encode_value(%_{} = value, redactions), do: value |> Map.from_struct() |> encode_value(redactions)

  defp encode_value(value, redactions) when is_map(value) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn {key, nested}, {:ok, encoded} ->
      with {:ok, key} <- encode_key(key),
           {:ok, nested} <- encode_map_value(key, nested, redactions) do
        {:cont, {:ok, Map.put(encoded, key, nested)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp encode_value(value, redactions) when is_list(value), do: encode_list(value, redactions)
  defp encode_value(value, _redactions), do: {:error, {:nonportable_fixture_value, runtime_type(value)}}

  defp encode_list(values, redactions) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, encoded} ->
      case encode_value(value, redactions) do
        {:ok, value} -> {:cont, {:ok, [value | encoded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end)
  end

  defp encode_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp encode_key("$jidoka." <> _suffix = key), do: {:error, {:reserved_fixture_key, key}}
  defp encode_key(key) when is_binary(key) and key != "", do: {:ok, key}
  defp encode_key(key), do: {:error, {:invalid_fixture_key, key}}

  defp encode_map_value(key, value, redactions) do
    if sensitive_key?(key), do: {:ok, "[REDACTED]"}, else: encode_value(value, redactions)
  end

  defp decode_value(%{@atom_tag => atom} = encoded) when map_size(encoded) == 1 and is_binary(atom) do
    try do
      {:ok, String.to_existing_atom(atom)}
    rescue
      ArgumentError -> {:error, {:unknown_fixture_atom, atom}}
    end
  end

  defp decode_value(%{@tuple_tag => items} = encoded) when map_size(encoded) == 1 and is_list(items) do
    with {:ok, items} <- decode_list(items), do: {:ok, List.to_tuple(items)}
  end

  defp decode_value(value) when is_map(value) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn {key, nested}, {:ok, decoded} ->
      case decode_value(nested) do
        {:ok, nested} -> {:cont, {:ok, Map.put(decoded, key, nested)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp decode_value(value) when is_list(value), do: decode_list(value)

  defp decode_value(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: {:ok, value}

  defp decode_value(value), do: {:error, {:invalid_encoded_fixture_value, value}}

  defp decode_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, decoded} ->
      case decode_value(value) do
        {:ok, value} -> {:cont, {:ok, [value | decoded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end)
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {key, canonical(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp sensitive_key?(key) do
    normalized = key |> Macro.underscore() |> String.downcase() |> String.replace(~r/[^a-z0-9_]/, "")
    normalized in @sensitive_words or Enum.any?(@sensitive_words, &String.contains?(normalized, &1))
  end

  defp string_redactions(opts) do
    opts
    |> Keyword.get(:redact_strings, [])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp runtime_type(value) when is_function(value), do: :function
  defp runtime_type(value) when is_pid(value), do: :pid
  defp runtime_type(value) when is_port(value), do: :port
  defp runtime_type(value) when is_reference(value), do: :reference
  defp runtime_type(_value), do: :unsupported
end
