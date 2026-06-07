defmodule Jidoka.Import.Decoder do
  @moduledoc false

  @type format :: :json | :yaml
  @default_max_bytes 1_000_000
  @default_max_depth 64
  @default_max_nodes 20_000

  @spec decode(String.t(), keyword()) :: {:ok, map() | list(), format()} | {:error, term()}
  def decode(contents, opts) when is_binary(contents) and is_list(opts) do
    with :ok <- validate_byte_size(contents, opts),
         {:ok, format} <- string_format(contents, opts),
         {:ok, decoded} <- decode_string(contents, format, opts),
         :ok <- validate_decoded_shape(decoded, opts) do
      {:ok, decoded, format}
    end
  end

  defp string_format(contents, opts) do
    case Keyword.get(opts, :format) || detect_string_format(contents) do
      format when format in [:json, :yaml] -> {:ok, format}
      other -> {:error, {:unsupported_import_format, other}}
    end
  end

  defp detect_string_format(contents) do
    case String.trim_leading(contents) do
      <<"{" <> _rest>> -> :json
      <<"[" <> _rest>> -> :json
      _other -> :yaml
    end
  end

  defp decode_string(contents, :json, _opts), do: Jason.decode(contents)

  defp decode_string(contents, :yaml, opts) do
    YamlElixir.read_from_string(contents,
      merge_anchors: Keyword.get(opts, :yaml_merge_anchors, false)
    )
  end

  defp validate_byte_size(contents, opts) do
    max_bytes = positive_integer_opt(opts, :max_import_bytes, :import_max_bytes, @default_max_bytes)

    if byte_size(contents) <= max_bytes do
      :ok
    else
      {:error, {:import_too_large, :bytes, byte_size(contents), max_bytes}}
    end
  end

  defp validate_decoded_shape(decoded, opts) do
    max_depth = positive_integer_opt(opts, :max_import_depth, :import_max_depth, @default_max_depth)
    max_nodes = positive_integer_opt(opts, :max_import_nodes, :import_max_nodes, @default_max_nodes)

    case count_nodes(decoded, 0, max_depth, 0, max_nodes) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp count_nodes(_value, depth, max_depth, _count, _max_nodes) when depth > max_depth do
    {:error, {:import_too_deep, depth, max_depth}}
  end

  defp count_nodes(_value, _depth, _max_depth, count, max_nodes) when count >= max_nodes do
    {:error, {:import_too_large, :nodes, count, max_nodes}}
  end

  defp count_nodes(%{} = map, depth, max_depth, count, max_nodes) do
    Enum.reduce_while(map, {:ok, count + 1}, fn {key, value}, {:ok, count} ->
      with {:ok, count} <- count_nodes(key, depth + 1, max_depth, count, max_nodes),
           {:ok, count} <- count_nodes(value, depth + 1, max_depth, count, max_nodes) do
        {:cont, {:ok, count}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp count_nodes(list, depth, max_depth, count, max_nodes) when is_list(list) do
    Enum.reduce_while(list, {:ok, count + 1}, fn value, {:ok, count} ->
      case count_nodes(value, depth + 1, max_depth, count, max_nodes) do
        {:ok, count} -> {:cont, {:ok, count}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp count_nodes(_value, _depth, _max_depth, count, _max_nodes), do: {:ok, count + 1}

  defp positive_integer_opt(opts, opt_key, env_key, default) do
    opts
    |> Keyword.get(opt_key, Application.get_env(:jidoka, env_key, default))
    |> normalize_positive_integer(default)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _other -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default
end
