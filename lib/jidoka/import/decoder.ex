defmodule Jidoka.Import.Decoder do
  @moduledoc false

  @type format :: :json | :yaml

  @spec decode(String.t(), keyword()) :: {:ok, map() | list(), format()} | {:error, term()}
  def decode(contents, opts) when is_binary(contents) and is_list(opts) do
    with {:ok, format} <- string_format(contents, opts),
         {:ok, decoded} <- decode_string(contents, format) do
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

  defp decode_string(contents, :json), do: Jason.decode(contents)
  defp decode_string(contents, :yaml), do: YamlElixir.read_from_string(contents, merge_anchors: true)
end
