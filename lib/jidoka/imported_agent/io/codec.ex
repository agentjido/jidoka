defmodule Jidoka.ImportedAgent.Codec do
  @moduledoc false

  alias Jidoka.ImportedAgent.Spec

  @spec decode(binary(), :auto | :json | :yaml | term()) :: {:ok, map()} | {:error, String.t()}
  def decode(source, :auto) when is_binary(source) do
    source
    |> detect_source_format()
    |> then(&decode(source, &1))
  end

  def decode(source, :json) when is_binary(source) do
    case Jason.decode(source) do
      {:ok, %{} = attrs} ->
        {:ok, attrs}

      {:ok, other} ->
        {:error, "imported Jidoka agent specs must decode to an object, got: #{inspect(other)}"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  def decode(source, :yaml) when is_binary(source) do
    case YamlElixir.read_from_string(source) do
      {:ok, %{} = attrs} ->
        {:ok, attrs}

      {:ok, other} ->
        {:error, "imported Jidoka agent specs must decode to a map, got: #{inspect(other)}"}

      {:error, error} ->
        {:error, format_error(error)}
    end
  end

  def decode(_source, format),
    do: {:error, "unsupported format #{inspect(format)}; expected :json, :yaml, or :auto"}

  @spec detect_file_format(Path.t(), :json | :yaml | nil | term()) ::
          {:ok, :json | :yaml} | {:error, String.t()}
  def detect_file_format(_path, format) when format in [:json, :yaml], do: {:ok, format}

  def detect_file_format(path, nil) when is_binary(path) do
    case Path.extname(path) do
      ".json" ->
        {:ok, :json}

      ".yaml" ->
        {:ok, :yaml}

      ".yml" ->
        {:ok, :yaml}

      ext ->
        {:error, "unsupported agent spec extension #{inspect(ext)}; expected .json, .yaml, or .yml"}
    end
  end

  def detect_file_format(_path, other),
    do: {:error, "unsupported format #{inspect(other)}; expected :json or :yaml"}

  @spec expand_skill_paths(map(), Path.t()) :: map()
  def expand_skill_paths(%{} = attrs, base_dir) when is_binary(base_dir) do
    capabilities = Map.get(attrs, "capabilities", Map.get(attrs, :capabilities, %{}))
    skill_paths = Map.get(capabilities, "skill_paths", Map.get(capabilities, :skill_paths, []))

    expanded_paths =
      Enum.map(skill_paths, fn
        path when is_binary(path) -> Path.expand(path, base_dir)
        other -> other
      end)

    expanded_capabilities =
      capabilities
      |> maybe_put("skill_paths", expanded_paths)
      |> maybe_put(:skill_paths, expanded_paths)

    attrs
    |> maybe_put("capabilities", expanded_capabilities)
    |> maybe_put(:capabilities, expanded_capabilities)
  end

  @spec encode(Spec.t(), keyword()) :: {:ok, binary()} | {:error, String.t()}
  def encode(%Spec{} = spec, opts \\ []) do
    external = Spec.to_external_map(spec)

    case Keyword.get(opts, :format, :json) do
      :json ->
        {:ok, Jason.encode!(external, pretty: true)}

      :yaml ->
        {:ok, encode_yaml(external)}

      other ->
        {:error, "unsupported format #{inspect(other)}; expected :json or :yaml"}
    end
  end

  @spec format_error(term()) :: String.t()
  def format_error(reason) when is_binary(reason), do: reason
  def format_error(%{message: message}) when is_binary(message), do: message
  def format_error(reason), do: inspect(reason)

  defp detect_source_format(source) do
    case String.trim_leading(source) do
      <<"{"::utf8, _::binary>> -> :json
      _ -> :yaml
    end
  end

  defp maybe_put(map, key, value) do
    if Map.has_key?(map, key), do: Map.put(map, key, value), else: map
  end

  defp encode_yaml(%{} = external) do
    external
    |> Ymlr.document!(sort_maps: true)
    |> yaml_document_body()
    |> Kernel.<>("\n")
  end

  defp yaml_document_body(document) do
    document
    |> String.split("\n", trim: true)
    |> Enum.reject(&(&1 == "---"))
    |> Enum.join("\n")
  end
end
